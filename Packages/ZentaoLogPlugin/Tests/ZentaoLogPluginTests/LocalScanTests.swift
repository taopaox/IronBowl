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

@Test func parsesGitPorcelainBranchStatus() throws {
    let clean = GitScanner.parsePorcelainBranchStatus(repoPath: "/work/clean", output: "## main...origin/main\n")
    let cleanStatus = try #require(clean)
    #expect(cleanStatus.branch == "main")
    #expect(cleanStatus.hasUpstream)
    #expect(cleanStatus.uncommittedCount == 0)
    #expect(cleanStatus.unpushedCount == 0)
    #expect(!cleanStatus.needsAttention)

    let dirtyAndAhead = GitScanner.parsePorcelainBranchStatus(
        repoPath: "/work/app",
        output: """
        ## feat/login...origin/feat/login [ahead 2, behind 1]
         M Sources/App.swift
        ?? Sources/NewFile.swift
        """
    )
    let dirtyStatus = try #require(dirtyAndAhead)
    #expect(dirtyStatus.branch == "feat/login")
    #expect(dirtyStatus.hasUpstream)
    #expect(dirtyStatus.uncommittedCount == 2)
    #expect(dirtyStatus.unpushedCount == 2)
    #expect(dirtyStatus.needsAttention)

    let noUpstream = GitScanner.parsePorcelainBranchStatus(
        repoPath: "/work/local-only",
        output: "## dev\n M README.md\n"
    )
    let localStatus = try #require(noUpstream)
    #expect(localStatus.branch == "dev")
    #expect(!localStatus.hasUpstream)
    #expect(localStatus.uncommittedCount == 1)
    #expect(localStatus.unpushedCount == 0)
    #expect(localStatus.needsAttention)
}

@Test func aggregatesGitPeriodStatsWithDeduplicationAndBusiestMonth() {
    let cal = Calendar(identifier: .gregorian)
    let d1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 10))!
    let d2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 11))!
    let d3 = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 15))!

    let c1 = GitCommit(hash: "aaa", date: d1, subject: "feat: init", files: [GitFileChange(path: "A.swift", added: 100, deleted: 10)])
    let c2 = GitCommit(hash: "bbb", date: d2, subject: "feat: core", files: [GitFileChange(path: "B.swift", added: 50, deleted: 5)])
    let c3 = GitCommit(hash: "ccc", date: d3, subject: "fix: bug", files: [GitFileChange(path: "C.swift", added: 20, deleted: 2)])
    // c2 在第二个目录中以相同哈希重复出现，应去重
    let acts = [
        RepoActivity(repoPath: "/work/repoA", commits: [c1, c2]),
        RepoActivity(repoPath: "/work/repoB", commits: [c2, c3]),
    ]

    let stats = GitScanner.aggregatePeriodStats(acts)
    #expect(stats.commitCount == 3)
    #expect(stats.activeRepoCount == 2)
    #expect(stats.addedLines == 170)
    #expect(stats.deletedLines == 17)
    #expect(stats.busiestMonth == "2026-11")
    #expect(stats.topRepos.first == GitRepoCommitCount(name: "repoA", commits: 2))
}
