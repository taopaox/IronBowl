import Foundation
import IronBowlKit
import Testing
@testable import ZentaoLogPlugin

@MainActor @Test func logStoreFiltersSubmissionsAndPendingDraftsByDateRange() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentaolog-range-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let store = LogStore(db: db)

    store.add(Submission(id: nil, date: "2026-11-22", taskID: 10, hours: 8, left: 0, work: "周日加班", isOvertime: true, submittedAt: Date()))
    store.add(Submission(id: nil, date: "2026-11-23", taskID: 11, hours: 8, left: 4, work: "周一需求开发", isOvertime: false, submittedAt: Date()))
    store.add(Submission(id: nil, date: "2026-11-25", taskID: 12, hours: 6, left: 2, work: "周三接口联调", isOvertime: false, submittedAt: Date()))
    store.add(Submission(id: nil, date: "2026-11-30", taskID: 13, hours: 8, left: 0, work: "下周一任务", isOvertime: false, submittedAt: Date()))

    let inWeek = store.submissions(from: "2026-11-23", to: "2026-11-29")
    #expect(inWeek.count == 2)
    #expect(inWeek.map(\.date) == ["2026-11-23", "2026-11-25"])

    store.savePendingDrafts([DraftEntry(taskID: 14, hours: 2, left: 0, work: "周日草稿")], for: "2026-11-22")
    store.savePendingDrafts([DraftEntry(taskID: 15, hours: 4, left: 4, work: "周四草稿")], for: "2026-11-26")
    store.savePendingDrafts([DraftEntry(taskID: 16, hours: 3, left: 1, work: "下周草稿")], for: "2026-12-01")

    let drafts = store.pendingDrafts(from: "2026-11-23", to: "2026-11-29")
    #expect(drafts.keys.sorted() == ["2026-11-26"])
    #expect(drafts["2026-11-26"]?.first?.work == "周四草稿")
}

@Test func mergeDailyItemsDeduplicatesAndResolvesProjectMetadata() {
    let tasksByID: [Int: ZentaoTask] = [
        101: ZentaoTask(id: 101, name: "周报模块开发", projectID: 50, projectName: "饭碗工作台", status: "doing", left: 6, consumed: 8),
        102: ZentaoTask(id: 102, name: "历史联调任务", projectID: 51, projectName: "数据平台", status: "done", left: 0, consumed: 4),
    ]
    let mappings: [String: RepoMapping] = [
        "/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 50, projectName: "饭碗工作台", excluded: false, sendDiff: false),
        "/repos/extra": RepoMapping(repoPath: "/repos/extra", projectID: 52, projectName: "运维工具", excluded: false, sendDiff: false),
    ]
    let projectNames = ZentaoDailyLogService.projectNamesByID(tasksByID: tasksByID, mappings: mappings)

    let remote = [
        ZentaoEstimate(taskID: 101, date: "2026-11-25", consumed: 8, left: 6, work: "1. 实现周报查询\n2. 联调预览页面", account: "u", projectID: 50),
    ]
    let local = [
        Submission(id: 1, date: "2026-11-25", taskID: 101, hours: 8, left: 6, work: "1. 实现周报查询  2. 联调预览页面", isOvertime: true, submittedAt: Date()),
        Submission(id: 2, date: "2026-11-25", taskID: 102, hours: 2, left: 0, work: "补充联调测试", isOvertime: false, submittedAt: Date()),
    ]
    let drafts = [
        DraftEntry(taskID: nil, hours: 1.5, left: 0, work: "编写工具脚本", repoPaths: ["/repos/extra"], isOvertime: false, isManual: true),
    ]

    let mergedWithDrafts = ZentaoDailyLogService.mergeDailyItems(
        date: "2026-11-25",
        remote: remote,
        local: local,
        pendingDrafts: drafts,
        tasksByID: tasksByID,
        projectNamesByID: projectNames,
        mappings: mappings
    )

    #expect(mergedWithDrafts.count == 3)
    let matchedRemote = mergedWithDrafts.first { $0.taskID == 101 }
    #expect(matchedRemote?.isOvertime == true)
    #expect(matchedRemote?.projectName == "饭碗工作台")
    #expect(matchedRemote?.taskTitle == "周报模块开发")
    #expect(matchedRemote?.isDraft == false)

    let extraLocal = mergedWithDrafts.first { $0.taskID == 102 }
    #expect(extraLocal?.projectName == "数据平台")
    #expect(extraLocal?.taskTitle == "历史联调任务")

    let draftItem = mergedWithDrafts.first { $0.isDraft }
    #expect(draftItem?.projectID == 52)
    #expect(draftItem?.projectName == "运维工具")
    #expect(draftItem?.hours == 1.5)
}

@MainActor @Test func dailyLogServiceFetchReturnsLocalLogsWhenUnconfigured() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentaolog-service-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let settings = SettingsStore(database: db)
    let store = LogStore(db: db)

    store.add(Submission(id: nil, date: "2026-11-24", taskID: 201, hours: 8, left: 0, work: "完成周二接口开发", isOvertime: false, submittedAt: Date()))
    store.savePendingDrafts([DraftEntry(taskID: 202, hours: 3, left: 2, work: "周三草稿内容")], for: "2026-11-25")

    let service = ZentaoDailyLogService(database: db, settings: settings)
    #expect(!service.isZentaoConfigured)

    let withDrafts = await service.fetch(from: "2026-11-23", to: "2026-11-29", includeDrafts: true)
    #expect(!withDrafts.zentaoConfigured)
    #expect(!withDrafts.syncedFromZentao)
    #expect(withDrafts.remoteError == nil)
    #expect(withDrafts.itemsByDate["2026-11-24"]?.count == 1)
    #expect(withDrafts.itemsByDate["2026-11-25"]?.first?.isDraft == true)

    let withoutDrafts = await service.fetch(from: "2026-11-23", to: "2026-11-29", includeDrafts: false)
    #expect(withoutDrafts.itemsByDate["2026-11-24"]?.count == 1)
    #expect(withoutDrafts.itemsByDate["2026-11-25"] == nil)
}
