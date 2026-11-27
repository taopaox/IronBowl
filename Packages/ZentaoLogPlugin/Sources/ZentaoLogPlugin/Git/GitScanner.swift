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

/// 本地仓库的未提交改动与未推送提交状态。
public nonisolated struct RepoWorkspaceStatus: Sendable, Identifiable, Hashable, Codable {
    public let repoPath: String
    public let branch: String
    public let uncommittedCount: Int
    public let unpushedCount: Int
    public let hasUpstream: Bool
    public var id: String { repoPath }
    public var repoName: String { (repoPath as NSString).lastPathComponent }
    public var needsAttention: Bool { uncommittedCount > 0 || unpushedCount > 0 }
}

/// 单个仓库在指定周期内的提交统计。
public nonisolated struct GitRepoCommitCount: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let commits: Int
    public var id: String { name }

    public init(name: String, commits: Int) {
        self.name = name
        self.commits = commits
    }
}

/// 指定时间区间内的 Git 代码提交统计（用于季度/年度述职与牛马年度报告）。
public nonisolated struct GitPeriodStats: Sendable, Equatable, Codable {
    public let commitCount: Int
    public let activeRepoCount: Int
    public let addedLines: Int
    public let deletedLines: Int
    public let topRepos: [GitRepoCommitCount]
    public let busiestMonth: String?

    public static let empty = GitPeriodStats(
        commitCount: 0,
        activeRepoCount: 0,
        addedLines: 0,
        deletedLines: 0,
        topRepos: [],
        busiestMonth: nil
    )

    public init(
        commitCount: Int,
        activeRepoCount: Int,
        addedLines: Int,
        deletedLines: Int,
        topRepos: [GitRepoCommitCount],
        busiestMonth: String?
    ) {
        self.commitCount = commitCount
        self.activeRepoCount = activeRepoCount
        self.addedLines = addedLines
        self.deletedLines = deletedLines
        self.topRepos = topRepos
        self.busiestMonth = busiestMonth
    }
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

    /// 并发扫描本地仓库的未提交改动与未推送提交状态。
    @concurrent
    public static func workspaceStatus(repos: [String]) async -> [RepoWorkspaceStatus] {
        await withTaskGroup(of: RepoWorkspaceStatus?.self) { group in
            for repo in repos {
                group.addTask {
                    let args = ["-C", repo, "status", "--porcelain=v1", "-b"]
                    guard let r = try? await Shell.run(git, args, timeout: 15), r.status == 0 else { return nil }
                    return parsePorcelainBranchStatus(repoPath: repo, output: r.stdout)
                }
            }
            var statuses: [RepoWorkspaceStatus] = []
            for await status in group {
                if let status { statuses.append(status) }
            }
            return statuses.sorted { $0.repoName.localizedStandardCompare($1.repoName) == .orderedAscending }
        }
    }

    public static func parsePorcelainBranchStatus(repoPath: String, output: String) -> RepoWorkspaceStatus? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let header = lines.first, header.hasPrefix("## ") else { return nil }
        let body = String(header.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var branch = body
        var hasUpstream = false
        var unpushedCount = 0

        if body.hasPrefix("No commits yet on ") {
            branch = String(body.dropFirst("No commits yet on ".count))
        } else if let dotsRange = body.range(of: "...") {
            hasUpstream = true
            branch = String(body[..<dotsRange.lowerBound])
            let rest = String(body[dotsRange.upperBound...])
            if let match = rest.firstMatch(of: /\bahead\s+(\d+)/), let count = Int(match.1) {
                unpushedCount = count
            }
        } else if let bracketRange = body.range(of: " [") {
            branch = String(body[..<bracketRange.lowerBound])
        }

        let uncommittedCount = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return RepoWorkspaceStatus(
            repoPath: repoPath,
            branch: branch,
            uncommittedCount: uncommittedCount,
            unpushedCount: unpushedCount,
            hasUpstream: hasUpstream
        )
    }

    /// 统计 `[startDate, endDate]`（`yyyy-MM-dd` 闭区间）内的跨仓库去重 Git 提交、增删行数及最活跃月份。
    @concurrent
    public static func periodStats(
        repos: [String],
        authorEmail: String,
        startDate: String,
        endDate: String
    ) async -> GitPeriodStats {
        let dayFmt = DateFormatter()
        dayFmt.calendar = Calendar(identifier: .gregorian)
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.timeZone = .current
        dayFmt.dateFormat = "yyyy-MM-dd"

        guard !repos.isEmpty,
              let start = dayFmt.date(from: startDate),
              let endDay = dayFmt.date(from: endDate),
              start <= endDay else {
            return .empty
        }
        let cal = Calendar(identifier: .gregorian)
        let startBound = cal.startOfDay(for: start)
        let endBound = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDay)) ?? endDay
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let since = iso.string(from: startBound)
        let until = iso.string(from: endBound)

        let rawActivities = await withTaskGroup(of: (Int, RepoActivity?).self) { group in
            for (i, repo) in repos.enumerated() {
                group.addTask {
                    var args = ["-C", repo, "log", "--all", "--no-merges"]
                    if !authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        args.append("--author=\(authorEmail)")
                    }
                    args += [
                        "--since=\(since)", "--until=\(until)",
                        "--date=iso-strict", "--format=%x1e%H%x1f%aI%x1f%s", "--numstat",
                    ]
                    guard let r = try? await Shell.run(git, args, timeout: 45), r.status == 0 else {
                        return (i, nil)
                    }
                    let commits = parseLog(r.stdout).filter { $0.date >= startBound && $0.date < endBound }
                    return (i, commits.isEmpty ? nil : RepoActivity(repoPath: repo, commits: commits))
                }
            }
            var collected: [(Int, RepoActivity?)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }

        return aggregatePeriodStats(rawActivities)
    }

    /// 对多个仓库的提交活动按哈希去重后聚合周期统计（纯函数，便于单测）。
    public static func aggregatePeriodStats(_ activities: [RepoActivity]) -> GitPeriodStats {
        var seen = Set<String>()
        var totalCommits = 0
        var added = 0
        var deleted = 0
        var repoCounts: [String: Int] = [:]
        var monthCounts: [String: Int] = [:]

        let monthFmt = DateFormatter()
        monthFmt.calendar = Calendar(identifier: .gregorian)
        monthFmt.locale = Locale(identifier: "en_US_POSIX")
        monthFmt.timeZone = .current
        monthFmt.dateFormat = "yyyy-MM"

        for act in activities {
            let unique = act.commits.filter { seen.insert($0.hash).inserted }
            guard !unique.isEmpty else { continue }
            repoCounts[act.repoName, default: 0] += unique.count
            for commit in unique {
                totalCommits += 1
                for f in commit.files {
                    added += f.added
                    deleted += f.deleted
                }
                let mk = monthFmt.string(from: commit.date)
                monthCounts[mk, default: 0] += 1
            }
        }

        let topRepos = repoCounts.keys
            .sorted {
                let lc = repoCounts[$0] ?? 0
                let rc = repoCounts[$1] ?? 0
                if lc != rc { return lc > rc }
                return $0.localizedStandardCompare($1) == .orderedAscending
            }
            .map { GitRepoCommitCount(name: $0, commits: repoCounts[$0] ?? 0) }

        let busiestMonth = monthCounts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key

        return GitPeriodStats(
            commitCount: totalCommits,
            activeRepoCount: repoCounts.count,
            addedLines: added,
            deletedLines: deleted,
            topRepos: topRepos,
            busiestMonth: busiestMonth
        )
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
