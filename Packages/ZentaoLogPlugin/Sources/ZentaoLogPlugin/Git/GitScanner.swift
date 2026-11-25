import Foundation
import IronBowlKit

public nonisolated struct GitFileChange: Sendable, Hashable, Codable {
    public let path: String
    public let added: Int
    public let deleted: Int
}

public nonisolated struct GitCommit: Sendable, Hashable, Identifiable, Codable {
    public let hash: String
    public let date: Date
    public let subject: String
    public let files: [GitFileChange]
    public var id: String { hash }
    public var lines: Int { files.reduce(0) { $0 + $1.added + $1.deleted } }
}

/// 某个仓库某天的提交。
public nonisolated struct RepoActivity: Sendable, Identifiable, Hashable {
    public let repoPath: String
    public let commits: [GitCommit]
    public var id: String { repoPath }
    public var repoName: String { (repoPath as NSString).lastPathComponent }
    public var lines: Int { commits.reduce(0) { $0 + $1.lines } }
    /// 用来分配工时的权重：提交数 + 改动行数的对数，避免生成文件的巨量改动独占工时。
    public var weight: Double { Double(commits.count) + log2(1 + Double(lines)) }
}

public nonisolated enum GitScanner {
    static let git = "/usr/bin/git"

    /// 在根目录下找 depth 层以内的 git 仓库（不进入已找到仓库的内部）。
    public static func discoverRepos(root: String, depth: Int) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        func walk(_ path: String, level: Int) {
            if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                result.append(path)
                return
            }
            guard level < depth, let children = try? fm.contentsOfDirectory(atPath: path) else { return }
            for child in children.sorted() where !child.hasPrefix(".") && child != "node_modules" {
                let full = (path as NSString).appendingPathComponent(child)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    walk(full, level: level + 1)
                }
            }
        }
        let expanded = (root as NSString).expandingTildeInPath
        walk(expanded, level: 0)
        return result
    }

    /// 某天（本地时区 00:00–24:00）作者在这些仓库的提交。同一提交在多个文件夹出现时只算第一个。
    @concurrent
    public static func activity(repos: [String], authorEmail: String, day: Date) async -> [RepoActivity] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let since = iso.string(from: start), until = iso.string(from: end)

        let results = await withTaskGroup(of: (Int, RepoActivity?).self) { group in
            for (i, repo) in repos.enumerated() {
                group.addTask {
                    let args = ["-C", repo, "log", "--all", "--no-merges",
                                "--author=\(authorEmail)",
                                "--since=\(since)", "--until=\(until)",
                                "--date=iso-strict", "--format=%x1e%H%x1f%aI%x1f%s", "--numstat"]
                    guard let r = try? await Shell.run(git, args, timeout: 30), r.status == 0 else { return (i, nil) }
                    let commits = parseLog(r.stdout).filter { $0.date >= start && $0.date < end }
                    return (i, commits.isEmpty ? nil : RepoActivity(repoPath: repo, commits: commits))
                }
            }
            var all: [(Int, RepoActivity?)] = []
            for await item in group { all.append(item) }
            return all.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }

        var seen = Set<String>()
        return results.compactMap { act in
            let unique = act.commits.filter { seen.insert($0.hash).inserted }
            return unique.isEmpty ? nil : RepoActivity(repoPath: act.repoPath, commits: unique)
        }
    }

    /// 最近 N 天有作者提交的仓库（用于映射页只显示用得到的仓库）。
    @concurrent
    public static func recentlyActive(repos: [String], authorEmail: String, days: Int) async -> [String: [String]] {
        await withTaskGroup(of: (String, [String]).self) { group in
            for repo in repos {
                group.addTask {
                    let args = ["-C", repo, "log", "--all", "--no-merges", "--author=\(authorEmail)",
                                "--since=\(days).days", "--format=%s", "-n", "15"]
                    guard let r = try? await Shell.run(git, args, timeout: 30), r.status == 0 else { return (repo, []) }
                    return (repo, r.stdout.split(separator: "\n").map(String.init))
                }
            }
            var dict: [String: [String]] = [:]
            for await (repo, subjects) in group where !subjects.isEmpty { dict[repo] = subjects }
            return dict
        }
    }

    /// 提交的代码改动（截断），只在用户为该仓库打开"发送代码改动"时使用。
    @concurrent
    public static func diff(repo: String, hash: String, limit: Int = 4000) async -> String {
        guard let r = try? await Shell.run(git, ["-C", repo, "show", "--format=", "--no-color", "-U2", hash], timeout: 30),
              r.status == 0 else { return "" }
        return r.stdout.count > limit ? String(r.stdout.prefix(limit)) + "\n…（已截断）" : r.stdout
    }

    /// 读取全局 git 邮箱，作为默认作者。
    @concurrent
    public static func globalEmail() async -> String? {
        guard let r = try? await Shell.run(git, ["config", "--global", "user.email"], timeout: 10), r.status == 0 else { return nil }
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func parseLog(_ text: String) -> [GitCommit] {
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { return nil }
            let parts = header.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let date = iso.date(from: String(parts[1])) else { return nil }
            let files: [GitFileChange] = lines.dropFirst().compactMap { line in
                let cols = line.split(separator: "\t", maxSplits: 2)
                guard cols.count == 3 else { return nil }
                // 二进制文件显示为 "-"。
                return GitFileChange(path: String(cols[2]), added: Int(cols[0]) ?? 0, deleted: Int(cols[1]) ?? 0)
            }
            return GitCommit(hash: String(parts[0]), date: date, subject: String(parts[2]), files: files)
        }
    }
}
