import AppKit
import Foundation
import IronBowlKit
import Observation
import ZentaoLogPlugin

@Observable
final class WorkspaceModel {
    let context: PluginContext
    var repos: [WorkspaceRepoItem] = []
    var filter: WorkspaceFilter = .all
    var query: String = ""
    var isRefreshing = false
    var fetchingRepoPath: String?
    var statusMessage: String?
    var errorMessage: String?

    init(context: PluginContext) {
        self.context = context
    }

    var settings: SettingsStore { context.settings }

    var defaultEditor: ExternalEditorOption {
        get { ExternalEditorOption(rawValue: settings[WorkspaceKeys.defaultEditor]) ?? .auto }
        set { settings[WorkspaceKeys.defaultEditor] = newValue.rawValue }
    }

    var defaultTerminal: ExternalTerminalOption {
        get { ExternalTerminalOption(rawValue: settings[WorkspaceKeys.defaultTerminal]) ?? .auto }
        set { settings[WorkspaceKeys.defaultTerminal] = newValue.rawValue }
    }

    var pinnedSet: Set<String> {
        Set(settings[WorkspaceKeys.pinnedRepos])
    }

    var extraRepos: [String] {
        get { settings[WorkspaceKeys.extraRepos] }
        set { settings[WorkspaceKeys.extraRepos] = newValue }
    }

    var filteredRepos: [WorkspaceRepoItem] {
        WorkspaceRepoSorter.sortAndFilter(repos, filter: filter, query: query)
    }

    var attentionCount: Int {
        repos.filter(\.needsAttention).count
    }

    var todayActiveCount: Int {
        repos.filter(\.isTodayActive).count
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let baseRepos = GitScanner.configuredRepos(database: context.database, settings: settings)
        let extra = settings[WorkspaceKeys.extraRepos].filter {
            FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git"))
        }
        var seen = Set<String>()
        let allPaths = (baseRepos + extra).filter { seen.insert($0).inserted }
        let extraSet = Set(extra)
        let pinned = pinnedSet
        let projectMap = GitScanner.mappedProjectNames(database: context.database)
        let email = await GitScanner.configuredAuthorEmail(settings: settings)

        async let statusesTask = GitScanner.workspaceStatus(repos: allPaths)
        async let todayTask = GitScanner.activity(repos: allPaths, authorEmail: email, day: Date())
        async let lastCommitsTask = Self.fetchLastCommits(repos: allPaths)

        let statuses = Dictionary(uniqueKeysWithValues: (await statusesTask).map { ($0.repoPath, $0) })
        let todayActivePaths = Set((await todayTask).map(\.repoPath))
        let lastCommits = await lastCommitsTask

        repos = allPaths.map { path in
            let st = statuses[path]
            let last = lastCommits[path]
            return WorkspaceRepoItem(
                path: path,
                branch: st?.branch ?? "HEAD",
                uncommittedCount: st?.uncommittedCount ?? 0,
                unpushedCount: st?.unpushedCount ?? 0,
                hasUpstream: st?.hasUpstream ?? false,
                lastCommitSubject: last?.subject ?? "",
                lastCommitAuthor: last?.author ?? "",
                lastCommitDate: last?.date,
                mappedProjectName: projectMap[path],
                isPinned: pinned.contains(path),
                isExtra: extraSet.contains(path),
                isTodayActive: todayActivePaths.contains(path)
            )
        }
    }

    func togglePin(_ repoPath: String) {
        var list = settings[WorkspaceKeys.pinnedRepos]
        if let idx = list.firstIndex(of: repoPath) {
            list.remove(at: idx)
        } else {
            list.append(repoPath)
        }
        settings[WorkspaceKeys.pinnedRepos] = list
        repos = repos.map { item in
            guard item.path == repoPath else { return item }
            return WorkspaceRepoItem(
                path: item.path,
                name: item.name,
                branch: item.branch,
                uncommittedCount: item.uncommittedCount,
                unpushedCount: item.unpushedCount,
                hasUpstream: item.hasUpstream,
                lastCommitSubject: item.lastCommitSubject,
                lastCommitAuthor: item.lastCommitAuthor,
                lastCommitDate: item.lastCommitDate,
                mappedProjectName: item.mappedProjectName,
                isPinned: list.contains(repoPath),
                isExtra: item.isExtra,
                isTodayActive: item.isTodayActive
            )
        }
    }

    func addExtraRepo(_ path: String) {
        let trimmed = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: (trimmed as NSString).appendingPathComponent(".git")) else {
            errorMessage = "所选目录不是有效的 Git 仓库（缺少 .git）"
            return
        }
        var current = extraRepos
        if !current.contains(trimmed) {
            current.append(trimmed)
            extraRepos = current
            Task { await refresh() }
        }
    }

    func removeExtraRepo(_ path: String) {
        extraRepos = extraRepos.filter { $0 != path }
        Task { await refresh() }
    }

    func openInEditor(_ repoPath: String, editor: ExternalEditorOption? = nil) {
        let chosen = editor ?? defaultEditor
        guard let appURL = chosen.resolvedAppURL() else {
            errorMessage = "未检测到可用的代码编辑器（\(chosen.displayName)），请在设置中指定或安装后重试。"
            return
        }
        let repoURL = URL(fileURLWithPath: repoPath, isDirectory: true)
        NSWorkspace.shared.open(
            [repoURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, err in
            Task { @MainActor in
                if let err {
                    self?.errorMessage = "打开编辑器失败：\(err.localizedDescription)"
                } else {
                    self?.statusMessage = "已用 \(chosen == .auto ? appURL.deletingPathExtension().lastPathComponent : chosen.displayName) 打开 \((repoPath as NSString).lastPathComponent)"
                }
            }
        }
    }

    func openInTerminal(_ repoPath: String) {
        let chosen = defaultTerminal
        guard let appURL = chosen.resolvedAppURL() else {
            errorMessage = "未检测到可用的终端应用"
            return
        }
        let repoURL = URL(fileURLWithPath: repoPath, isDirectory: true)
        NSWorkspace.shared.open(
            [repoURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func revealInFinder(_ repoPath: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repoPath, isDirectory: true)])
    }

    func openChat(in repoPath: String) {
        context.openChatInWorkspace(repoPath)
    }

    func fetchRepo(_ repoPath: String) async {
        guard fetchingRepoPath == nil else { return }
        fetchingRepoPath = repoPath
        errorMessage = nil
        statusMessage = nil
        defer { fetchingRepoPath = nil }

        do {
            let result = try await Shell.run("/usr/bin/git", ["-C", repoPath, "fetch", "--prune"], timeout: 30)
            if result.status == 0 {
                statusMessage = "已完成 \((repoPath as NSString).lastPathComponent) 的 git fetch"
                await refresh()
            } else {
                errorMessage = "git fetch 失败：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        } catch {
            errorMessage = "git fetch 失败：\(error.localizedDescription)"
        }
    }

    private struct LastCommitInfo: Sendable {
        let subject: String
        let author: String
        let date: Date?
    }

    @concurrent
    private nonisolated static func fetchLastCommits(repos: [String]) async -> [String: LastCommitInfo] {
        await withTaskGroup(of: (String, LastCommitInfo?).self) { group in
            for repo in repos {
                group.addTask {
                    guard let r = try? await Shell.run(
                        "/usr/bin/git",
                        ["-C", repo, "log", "-1", "--format=%s%x1f%an%x1f%aI"],
                        timeout: 15
                    ), r.status == 0 else {
                        return (repo, nil)
                    }
                    let line = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let parts = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
                    guard !parts.isEmpty else { return (repo, nil) }
                    let iso = ISO8601DateFormatter()
                    let date = parts.count >= 3 ? iso.date(from: String(parts[2])) : nil
                    let info = LastCommitInfo(
                        subject: String(parts[0]),
                        author: parts.count >= 2 ? String(parts[1]) : "",
                        date: date
                    )
                    return (repo, info)
                }
            }
            var dict: [String: LastCommitInfo] = [:]
            for await (repo, info) in group {
                if let info { dict[repo] = info }
            }
            return dict
        }
    }
}
