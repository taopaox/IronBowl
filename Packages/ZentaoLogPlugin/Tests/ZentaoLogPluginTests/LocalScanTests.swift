import Foundation
import IronBowlKit
import Testing
@testable import ZentaoLogPlugin

/// 本机集成测试：IRONBOWL_IT=1 swift test --filter LocalScan
@Test(.enabled(if: ProcessInfo.processInfo.environment["IRONBOWL_IT"] == "1"))
func localScanToday() async throws {
    let root = ProcessInfo.processInfo.environment["IRONBOWL_GIT_ROOT"] ?? "~/huanwei"
    let repos = GitScanner.discoverRepos(root: root, depth: 2)
    let email = await GitScanner.globalEmail() ?? ""
    let start = Date()
    let acts = await GitScanner.activity(repos: repos, authorEmail: email, day: Date())
    print("repos=\(repos.count) email=\(email) took=\(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    for a in acts { print("  \(a.repoName): \(a.commits.count) commits, \(a.lines) lines, weight \(String(format: "%.1f", a.weight))") }
    let hours = DraftGenerator.allocate(total: 8, weights: acts.map(\.weight))
    print("  hours: \(hours)")
    for a in acts { print("  fallback[\(a.repoName)]:\n\(DraftGenerator.fallbackWork(a))") }
    #expect(!repos.isEmpty)
}

/// 本机只读集成测试：IRONBOWL_IT=1 swift test --filter localZentaoEfforts
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["IRONBOWL_IT"] == "1"))
func localZentaoEfforts() async throws {
    let db = try AppDatabase(migrations: LogMigrations.all)
    let settings = SettingsStore(database: db)
    let baseURL = settings[LogKeys.baseURL]
    let account = settings[LogKeys.account]
    let password = settings[LogKeys.password]
    #expect(!baseURL.isEmpty && !account.isEmpty && !password.isEmpty)

    let client = try ZentaoClient(baseURL: baseURL, account: account, password: password)
    let minDay = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
    let minDate = WorkCalendar.dayString(minDay)
    let byDate = try await client.myEstimates(since: minDate, taskIDs: [])
    for day in byDate.keys.sorted(by: >) {
        let items = byDate[day] ?? []
        let total = items.reduce(0) { $0 + $1.consumed }
        print("  \(day): \(items.count) 条，合计 \(total)h")
    }
    let all = byDate.values.flatMap { $0 }
    #expect(!all.isEmpty)

    if let sampleTaskID = all.first(where: { $0.taskID > 0 })?.taskID {
        let taskEstimates = try await client.estimates(taskID: sampleTaskID)
        print("  task #\(sampleTaskID) estimates=\(taskEstimates.count)")
        #expect(!taskEstimates.isEmpty)
    }
}
