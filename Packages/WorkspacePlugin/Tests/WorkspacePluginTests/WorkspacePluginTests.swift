import Foundation
import IronBowlKit
import Testing
@testable import WorkspacePlugin

@Test func workspaceRepoSorterPrioritizesPinnedAttentionTodayActiveAndName() {
    let repos = [
        WorkspaceRepoItem(path: "/work/zeta", branch: "main", uncommittedCount: 0, unpushedCount: 0, isPinned: false, isTodayActive: false),
        WorkspaceRepoItem(path: "/work/alpha", branch: "dev", uncommittedCount: 2, unpushedCount: 0, isPinned: false, isTodayActive: false),
        WorkspaceRepoItem(path: "/work/beta", branch: "main", uncommittedCount: 0, unpushedCount: 0, isPinned: true, isTodayActive: false),
        WorkspaceRepoItem(path: "/work/gamma", branch: "feat", uncommittedCount: 0, unpushedCount: 0, isPinned: false, isTodayActive: true),
    ]

    let sortedAll = WorkspaceRepoSorter.sortAndFilter(repos, filter: .all, query: "")
    #expect(sortedAll.map(\.name) == ["beta", "alpha", "gamma", "zeta"])

    let attentionOnly = WorkspaceRepoSorter.sortAndFilter(repos, filter: .attention, query: "")
    #expect(attentionOnly.map(\.name) == ["alpha"])

    let pinnedOnly = WorkspaceRepoSorter.sortAndFilter(repos, filter: .pinned, query: "")
    #expect(pinnedOnly.map(\.name) == ["beta"])

    let queryBranch = WorkspaceRepoSorter.sortAndFilter(repos, filter: .all, query: "feat")
    #expect(queryBranch.map(\.name) == ["gamma"])
}

@MainActor @Test func workspacePluginRegistersMetadataAndOpensChatCallback() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "workspace-plugin-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    var openedPath: String?
    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: ReminderCenter(database: db),
        workCalendar: WorkCalendar(database: db, settings: settings),
        providers: AIProviderStore(settings: settings),
        openPlugin: { _ in },
        openSettings: { _ in },
        openChatInWorkspace: { path in openedPath = path }
    )

    let plugin = WorkspacePlugin()
    plugin.start(context: context)
    defer { plugin.stop() }

    #expect(plugin.id == "workspace")
    #expect(plugin.sidebarSection == "研发")
    plugin.model?.openChat(in: "/tmp/demo-repo")
    #expect(openedPath == "/tmp/demo-repo")
}
