import Foundation
import IronBowlKit
import Testing
@testable import ZentaoLogPlugin

@Test func allocateKeepsTotalInHalfHours() {
    let r = DraftGenerator.allocate(total: 8, weights: [10, 1, 3])
    #expect(r.reduce(0, +) == 8)
    #expect(r.allSatisfy { ($0 * 2).rounded() == $0 * 2 && $0 >= 0.5 })
    #expect(r[0] > r[2] && r[2] >= r[1])
}

@Test func allocateZeroBudget() {
    #expect(DraftGenerator.allocate(total: 0, weights: [1, 2]) == [0, 0])
}

@Test func cleanSubjectStripsConventionalPrefix() {
    #expect(DraftGenerator.cleanSubject("fix(driver): 取消预约弹窗不再被遮挡") == "取消预约弹窗不再被遮挡")
    #expect(DraftGenerator.cleanSubject("♻️(refactor): 拆分 Windows 部署") == "拆分 Windows 部署")
    #expect(DraftGenerator.cleanSubject("add") == "")
    #expect(DraftGenerator.cleanSubject("承包商: 修复照片回显") == "修复照片回显")
}

@Test func parsesGitLog() {
    let text = "\u{1e}abc\u{1f}2026-11-25T10:00:00+08:00\u{1f}feat: 新功能\n\n10\t2\tsrc/a.vue\n-\t-\timg.png\n\u{1e}def\u{1f}2026-11-25T11:00:00+08:00\u{1f}add\n"
    let commits = GitScanner.parseLog(text)
    #expect(commits.count == 2)
    #expect(commits[0].files.count == 2 && commits[0].lines == 12)
    #expect(commits[1].subject == "add" && commits[1].files.isEmpty)
}

@Test func mergeWorkRenumbers() {
    #expect(DraftGenerator.mergeWork("1. A\n2. B", "1. B\n2. C") == "1. A\n2. B\n3. C")
}

@Test func recomputeLeftsAccumulatesSameTaskAcrossEntries() {
    let tasks = [
        ZentaoTask(id: 10, name: "功能开发", projectID: 1, projectName: "项目A", status: "doing", left: 8, consumed: 0),
        ZentaoTask(id: 99, name: "杂项", projectID: 1, projectName: "项目A", status: "doing", left: 5, consumed: 0),
    ]
    var entries = [
        DraftEntry(taskID: 10, hours: 4, left: 0, work: "白天开发"),
        DraftEntry(taskID: 10, hours: 2.5, left: 0, work: "晚上加班", isOvertime: true),
        DraftEntry(taskID: 10, hours: 3, left: 0, work: "追加", isManual: true),
        DraftEntry(taskID: 99, hours: 1, left: 0, work: "杂项记录"),
        DraftEntry(taskID: 10, hours: 2, left: 0, work: "已提交记录", isRecorded: true),
    ]
    DraftGenerator.recomputeLefts(&entries, tasks: tasks, fallbackTaskID: 99)
    #expect(entries[0].left == 4)
    #expect(entries[1].left == 1.5)
    #expect(entries[2].left == 0)
    #expect(entries[3].left == 4)
    #expect(entries[3].isFallback)
    #expect(!entries[0].isFallback)
    #expect(entries[4].left == 0)
}

@Test func repoKeysDisambiguateDuplicateNames() {
    let paths = ["/work/teamA/web", "/work/teamB/web", "/work/api"]
    let keys = DraftGenerator.repoKeys(for: paths)
    #expect(keys["/work/teamA/web"] == "teamA/web")
    #expect(keys["/work/teamB/web"] == "teamB/web")
    #expect(keys["/work/api"] == "api")
}

@MainActor @Test func generateEnforcesProjectMappingAndFallback() async {
    let actMapped = RepoActivity(repoPath: "/repos/app", commits: [
        GitCommit(hash: "1", date: Date(), subject: "feat: 完成首页", files: [GitFileChange(path: "a.swift", added: 10, deleted: 0)])
    ])
    let actUnmapped = RepoActivity(repoPath: "/repos/misc", commits: [
        GitCommit(hash: "2", date: Date(), subject: "fix: 修复样式", files: [GitFileChange(path: "b.css", added: 5, deleted: 0)])
    ])
    let tasks = [
        ZentaoTask(id: 101, name: "项目A任务", projectID: 1, projectName: "项目A", status: "doing", left: 10, consumed: 0),
        ZentaoTask(id: 202, name: "项目B任务", projectID: 2, projectName: "项目B", status: "doing", left: 10, consumed: 0),
        ZentaoTask(id: 999, name: "杂项任务", projectID: 3, projectName: "公共", status: "doing", left: 20, consumed: 0),
    ]
    let input = DraftInput(
        date: "2026-11-25",
        isWorkday: true,
        offDayOvertime: true,
        defaultHours: 8,
        activities: [actMapped, actUnmapped],
        mappings: [
            "/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 1, projectName: "项目A", excluded: false, sendDiff: false),
        ],
        openTasks: tasks,
        // 上次误记在项目B或非兜底任务，应被映射校验拦截。
        lastTasks: ["/repos/app": 202, "/repos/misc": 101],
        fallbackTaskID: 999,
        recorded: [],
        diffs: [:],
        promptTemplate: DraftGenerator.defaultPrompt
    )
    let out = await DraftGenerator.generate(input, provider: nil)
    #expect(out.entries.count == 1)
    #expect(out.entries[0].taskID == 999)
    #expect(out.entries[0].hours == 8)
    #expect(out.entries[0].left == 12)
    #expect(out.entries[0].isFallback)
}

@Test func parsesZentaoFailureReason() {
    let stringMsg = Data(#"{"result":"fail","message":"工时不能为空"}"#.utf8)
    #expect(ZentaoClient.failureReason(stringMsg) == "工时不能为空")

    let dictMsg = Data(#"{"status":"fail","message":{"consumed":["消耗工时必须大于0"]}}"#.utf8)
    #expect(ZentaoClient.failureReason(dictMsg) == "consumed：消耗工时必须大于0")

    let success = Data(#"{"result":"success","status":"success"}"#.utf8)
    #expect(ZentaoClient.failureReason(success) == nil)
}

@Test func mergeRecordedDeduplicatesRemoteAndLocal() {
    let remote = [
        ZentaoEstimate(taskID: 10, date: "2026-11-25", consumed: 4, left: 2, work: "1. 完成接口对接\n2. 修复样式", account: "a"),
        ZentaoEstimate(taskID: 20, date: "2026-11-25", consumed: 2, left: 0, work: "网页端直接补录", account: "a"),
    ]
    let local = [
        Submission(id: 1, date: "2026-11-25", taskID: 10, hours: 4, left: 2, work: "1. 完成接口对接  2. 修复样式", isOvertime: true, submittedAt: Date()),
        Submission(id: 2, date: "2026-11-25", taskID: 30, hours: 1.5, left: 3, work: "本地刚提交未回查", isOvertime: false, submittedAt: Date()),
    ]
    let merged = DraftGenerator.mergeRecorded(remote: remote, local: local)
    #expect(merged.count == 3)
    #expect(merged.allSatisfy { $0.isRecorded })
    #expect(merged.reduce(0) { $0 + $1.hours } == 7.5)
    #expect(merged.first(where: { $0.taskID == 10 })?.isOvertime == true)
    let hasTask20 = merged.contains(where: { $0.taskID == 20 && $0.hours == 2 })
    let hasTask30 = merged.contains(where: { $0.taskID == 30 && $0.hours == 1.5 })
    #expect(hasTask20)
    #expect(hasTask30)
}

@Test func detectsLoggedOutLocateWrapper() {
    let wrappedLocate = Data(#"{"status":"success","data":"{\"locate\":\"https:\\/\\/hwsz.chandao.com\\/user-login-L2VmZm9ydC5qc29u.json\"}"}"#.utf8)
    #expect(ZentaoClient.looksLoggedOut(wrappedLocate))

    let normalSuccess = Data(#"{"status":"success","data":"{\"title\":\"我的日志\",\"efforts\":[]}"}"#.utf8)
    #expect(!ZentaoClient.looksLoggedOut(normalSuccess))

    let plainLogin = Data(#"{"locate":"https://hwsz.chandao.com/user-login.json"}"#.utf8)
    #expect(ZentaoClient.looksLoggedOut(plainLogin))
}

@Test func detectsEffortModuleFromLoginRights() {
    let enterprise: [String: Any] = [
        "user": [
            "rights": [
                "rights": [
                    "effort": ["calendar": true, "createforobject": true],
                    "my": ["effort": true],
                ]
            ]
        ]
    ]
    #expect(ZentaoClient.detectEffortModule(enterprise) == true)

    let openSource: [String: Any] = [
        "user": [
            "rights": [
                "rights": [
                    "task": ["recordEstimate": true],
                    "my": ["task": true],
                ]
            ]
        ]
    ]
    #expect(ZentaoClient.detectEffortModule(openSource) == false)

    #expect(ZentaoClient.detectEffortModule(["status": "success"]) == nil)
}

@Test func parsesEffortsArrayAndDictionaryFormats() {
    let listObj: [String: Any] = [
        "efforts": [
            [
                "id": "30895",
                "objectType": "task",
                "objectID": "6802",
                "objectTitle": " 全栈开发 ",
                "project": "566",
                "account": "shenkun",
                "work": "安卓端开发\r\n",
                "date": "2026-11-24 00:00:00",
                "left": "300",
                "consumed": "12",
                "deleted": "0",
            ],
            [
                "id": "30896",
                "objectType": "bug",
                "objectID": "999",
                "objectTitle": "登录异常",
                "project": "566",
                "account": "shenkun",
                "work": "排查登录问题",
                "date": "2026-11-24",
                "left": "0",
                "consumed": "2",
                "deleted": "0",
            ],
            [
                "id": "30897",
                "objectType": "task",
                "objectID": "6802",
                "work": "已删除记录",
                "date": "2026-11-24",
                "consumed": "1",
                "deleted": "1",
            ],
        ]
    ]
    let parsedList = ZentaoClient.parseEfforts(listObj)
    #expect(parsedList?.count == 2)
    #expect(parsedList?[0].taskID == 6802)
    #expect(parsedList?[0].objectType == "task")
    #expect(parsedList?[0].objectTitle == "全栈开发")
    #expect(parsedList?[0].projectID == 566)
    #expect(parsedList?[0].work == "安卓端开发")
    #expect(parsedList?[0].date == "2026-11-24")
    #expect(parsedList?[1].taskID == 0)
    #expect(parsedList?[1].objectType == "bug")
    #expect(parsedList?[1].objectTitle == "登录异常")

    let dictObj: [String: Any] = [
        "efforts": [
            "30816": [
                "id": "30816",
                "objectType": "task",
                "objectID": "6802",
                "project": "566",
                "account": "shenkun",
                "work": "框架搭建",
                "date": "2026-11-19",
                "left": "300",
                "consumed": "8",
                "deleted": "0",
            ]
        ]
    ]
    let parsedDict = ZentaoClient.parseEfforts(dictObj, fallbackTaskID: 6802)
    #expect(parsedDict?.count == 1)
    #expect(parsedDict?[0].taskID == 6802)
    #expect(parsedDict?[0].consumed == 8)

    #expect(ZentaoClient.parseEfforts(["estimates": []]) == nil)
}

@Test func mergeRecordedPreservesTitleAndNonTaskEntries() {
    let remote = [
        ZentaoEstimate(
            taskID: 0,
            date: "2026-11-24",
            consumed: 2,
            left: 0,
            work: "排查线上问题",
            account: "a",
            objectType: "bug",
            objectTitle: "登录白屏",
            projectID: 566
        )
    ]
    let merged = DraftGenerator.mergeRecorded(remote: remote, local: [])
    #expect(merged.count == 1)
    #expect(merged[0].taskID == nil)
    #expect(merged[0].taskTitle == "登录白屏")
    #expect(merged[0].isRecorded)
    #expect(merged[0].hours == 2)
}

@MainActor @Test func logStorePersistsAndClearsPendingDrafts() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentaolog-store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let store = LogStore(db: db)

    let pending = DraftEntry(taskID: 101, hours: 3.5, left: 4.5, work: "1. 完成草稿持久化", isManual: true)
    let recorded = DraftEntry(taskID: 102, hours: 2, left: 0, work: "已提交记录", isRecorded: true)
    store.savePendingDrafts([pending, recorded], for: "2026-11-25")

    let loaded = store.pendingDrafts(since: "2026-11-20")
    #expect(loaded["2026-11-25"]?.count == 1)
    #expect(loaded["2026-11-25"]?[0].id == pending.id)
    #expect(loaded["2026-11-25"]?[0].work == "1. 完成草稿持久化")
    #expect(loaded["2026-11-25"]?[0].hours == 3.5)

    store.savePendingDrafts([], for: "2026-11-25")
    #expect(store.pendingDrafts(since: "2026-11-20").isEmpty)
}

@MainActor @Test func logModelPreservesDraftsAcrossDateSwitchAndReload() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentaolog-model-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    func makeContext() throws -> PluginContext {
        let db = try AppDatabase(url: url, migrations: LogMigrations.all)
        let settings = SettingsStore(database: db)
        settings[LogKeys.scanMode] = .manualOnly
        return PluginContext(
            database: db,
            settings: settings,
            reminders: ReminderCenter(),
            workCalendar: WorkCalendar(database: db, settings: settings),
            providers: AIProviderStore(settings: settings),
            webSessions: WebSessionManager(settings: settings),
            openPlugin: { _ in },
            openSettings: { _ in }
        )
    }

    let today = Calendar.current.startOfDay(for: Date())
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

    let model1 = try makeContext()
    let logModel1 = LogModel(context: model1)
    logModel1.lastScan = Date()
    logModel1.addManual()
    #expect(logModel1.drafts.count == 1)
    logModel1.drafts[0].work = "1. 完成草稿切页保留"
    logModel1.drafts[0].hours = 4

    // 切到昨天再切回今天，草稿仍保留
    await logModel1.select(date: yesterday)
    #expect(logModel1.drafts.isEmpty)
    await logModel1.select(date: today)
    #expect(logModel1.drafts.count == 1)
    #expect(logModel1.drafts[0].work == "1. 完成草稿切页保留")
    #expect(logModel1.drafts[0].hours == 4)

    // 再次点击今天（模拟从其他页面通过侧栏「最近日志 → 今天」返回）
    await logModel1.select(date: today)
    #expect(logModel1.drafts.count == 1)
    #expect(logModel1.drafts[0].work == "1. 完成草稿切页保留")

    // 用同一数据库重建 LogModel（模拟页面或应用重启）
    let logModel2 = LogModel(context: try makeContext())
    #expect(logModel2.drafts.count == 1)
    #expect(logModel2.drafts[0].work == "1. 完成草稿切页保留")
    #expect(logModel2.drafts[0].hours == 4)
}

@MainActor @Test func workCalendarPersistsAndClearsDailyOvertime() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentaolog-overtime-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let settings = SettingsStore(database: db)
    let cal = WorkCalendar(database: db, settings: settings)
    let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12))!

    cal.setOvertimeHours(2.5, on: day)
    #expect(cal.overtimeHours(on: day) == 2.5)

    cal.setOvertimeHours(4, on: day)
    #expect(cal.overtimeHours(on: day) == 4)

    cal.setOvertimeHours(0, on: day)
    #expect(cal.overtimeHours(on: day) == 0)
}

@MainActor @Test func logModelTargetHoursAndOvertimePersistence() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentaolog-target-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    func makeContext() throws -> PluginContext {
        let db = try AppDatabase(url: url, migrations: LogMigrations.all)
        let settings = SettingsStore(database: db)
        settings[LogKeys.scanMode] = .manualOnly
        return PluginContext(
            database: db,
            settings: settings,
            reminders: ReminderCenter(),
            workCalendar: WorkCalendar(database: db, settings: settings),
            providers: AIProviderStore(settings: settings),
            webSessions: WebSessionManager(settings: settings),
            openPlugin: { _ in },
            openSettings: { _ in }
        )
    }

    let wednesday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25))!
    let tuesday = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 24))!

    let ctx1 = try makeContext()
    ctx1.workCalendar.setOverride(tuesday, isOffDay: true, note: "测试调休")
    ctx1.workCalendar.setOverride(wednesday, isOffDay: false, note: "正常上班")

    let model1 = LogModel(context: ctx1)
    model1.lastScan = Date()
    await model1.select(date: wednesday)
    #expect(model1.baseWorkHours == 8)
    #expect(model1.targetHours == 8)
    #expect(model1.remainingTargetHours == 8)

    let normalEnd = ctx1.workCalendar.workEnd(on: wednesday)!
    model1.toggleOvertimeHours(2)
    #expect(model1.plannedOvertimeHours == 2)
    #expect(model1.targetHours == 10)
    #expect(model1.remainingTargetHours == 10)
    #expect(ctx1.workCalendar.workEnd(on: wednesday) == normalEnd)
    #expect(ctx1.workCalendar.effectiveWorkEnd(on: wednesday) == normalEnd.addingTimeInterval(2 * 3600))

    // 再次点击同档位归零
    model1.toggleOvertimeHours(2)
    #expect(model1.plannedOvertimeHours == 0)
    #expect(model1.targetHours == 8)
    #expect(ctx1.workCalendar.effectiveWorkEnd(on: wednesday) == normalEnd)

    // 设为 3.5 小时并切到休息日验证
    model1.plannedOvertimeHours = 3.5
    #expect(model1.targetHours == 11.5)
    await model1.select(date: tuesday)
    #expect(model1.baseWorkHours == 0)
    #expect(model1.targetHours == 0)
    model1.toggleOvertimeHours(3)
    #expect(model1.targetHours == 3)

    // 重建 LogModel 验证持久化
    let model2 = LogModel(context: try makeContext())
    await model2.select(date: wednesday)
    #expect(model2.plannedOvertimeHours == 3.5)
    #expect(model2.targetHours == 11.5)
    await model2.select(date: tuesday)
    #expect(model2.plannedOvertimeHours == 3)
    #expect(model2.targetHours == 3)
}

@MainActor @Test func generateSplitsNormalAndOvertimeByWorkEnd() async {
    let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 0, minute: 0))!
    let workEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: day)!
    let t15 = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: day)!
    let t20 = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: day)!

    let act = RepoActivity(repoPath: "/repos/app", commits: [
        GitCommit(hash: "1", date: t15, subject: "feat: 完成订单列表", files: [GitFileChange(path: "OrderList.swift", added: 20, deleted: 0)]),
        GitCommit(hash: "2", date: t20, subject: "fix: 修复支付超时重试", files: [GitFileChange(path: "PayRetry.swift", added: 10, deleted: 2)]),
    ])
    let tasks = [ZentaoTask(id: 101, name: "业务开发", projectID: 1, projectName: "项目A", status: "doing", left: 15, consumed: 0)]
    let input = DraftInput(
        date: "2026-11-25",
        isWorkday: true,
        offDayOvertime: true,
        defaultHours: 8,
        activities: [act],
        mappings: ["/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 1, projectName: "项目A", excluded: false, sendDiff: false)],
        openTasks: tasks,
        lastTasks: ["/repos/app": 101],
        fallbackTaskID: 999,
        recorded: [],
        diffs: [:],
        promptTemplate: DraftGenerator.defaultPrompt,
        overtimeHours: 2,
        workEnd: workEnd
    )

    let out = await DraftGenerator.generate(input, provider: nil)
    #expect(out.entries.count == 2)
    #expect(!out.entries[0].isOvertime)
    #expect(out.entries[0].hours == 8)
    #expect(out.entries[0].work.contains("完成订单列表"))
    #expect(!out.entries[0].work.contains("修复支付超时重试"))
    #expect(out.entries[0].left == 7)

    #expect(out.entries[1].isOvertime)
    #expect(out.entries[1].hours == 2)
    #expect(out.entries[1].work.contains("修复支付超时重试"))
    #expect(!out.entries[1].work.contains("完成订单列表"))
    #expect(out.entries[1].left == 5)
}

@MainActor @Test func generateSynthesizesOvertimeWhenNoPostWorkEndCommits() async {
    let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 0, minute: 0))!
    let workEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: day)!
    let t16 = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: day)!

    let act = RepoActivity(repoPath: "/repos/app", commits: [
        GitCommit(hash: "1", date: t16, subject: "feat: 完成报表导出", files: [GitFileChange(path: "Export.swift", added: 30, deleted: 0)]),
    ])
    let tasks = [ZentaoTask(id: 101, name: "报表模块", projectID: 1, projectName: "项目A", status: "doing", left: 12, consumed: 0)]
    let input = DraftInput(
        date: "2026-11-25",
        isWorkday: true,
        offDayOvertime: true,
        defaultHours: 8,
        activities: [act],
        mappings: ["/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 1, projectName: "项目A", excluded: false, sendDiff: false)],
        openTasks: tasks,
        lastTasks: ["/repos/app": 101],
        fallbackTaskID: 999,
        recorded: [],
        diffs: [:],
        promptTemplate: DraftGenerator.defaultPrompt,
        overtimeHours: 2,
        workEnd: workEnd
    )

    let out = await DraftGenerator.generate(input, provider: nil)
    #expect(out.entries.count == 2)
    #expect(!out.entries[0].isOvertime)
    #expect(out.entries[0].hours == 8)
    #expect(out.entries[0].left == 4)

    #expect(out.entries[1].isOvertime)
    #expect(out.entries[1].hours == 2)
    #expect(out.entries[1].taskID == 101)
    #expect(out.entries[1].work.contains("加班继续推进"))
    #expect(out.entries[1].left == 2)
}

@MainActor @Test func generateHandlesOnlyPostWorkEndCommitsWithOvertime() async {
    let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 0, minute: 0))!
    let workEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: day)!
    let t20 = Calendar.current.date(bySettingHour: 20, minute: 30, second: 0, of: day)!

    let act = RepoActivity(repoPath: "/repos/app", commits: [
        GitCommit(hash: "1", date: t20, subject: "feat: 晚上联调接口", files: [GitFileChange(path: "Api.swift", added: 15, deleted: 0)]),
    ])
    let tasks = [ZentaoTask(id: 101, name: "联调任务", projectID: 1, projectName: "项目A", status: "doing", left: 12, consumed: 0)]
    let input = DraftInput(
        date: "2026-11-25",
        isWorkday: true,
        offDayOvertime: true,
        defaultHours: 8,
        activities: [act],
        mappings: ["/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 1, projectName: "项目A", excluded: false, sendDiff: false)],
        openTasks: tasks,
        lastTasks: ["/repos/app": 101],
        fallbackTaskID: 999,
        recorded: [],
        diffs: [:],
        promptTemplate: DraftGenerator.defaultPrompt,
        overtimeHours: 2,
        workEnd: workEnd
    )

    let out = await DraftGenerator.generate(input, provider: nil)
    #expect(out.entries.count == 2)
    #expect(!out.entries[0].isOvertime)
    #expect(out.entries[0].hours == 8)
    #expect(out.entries[1].isOvertime)
    #expect(out.entries[1].hours == 2)
}

@MainActor @Test func generateOvertimeOnlyAfterNormalRecorded() async {
    let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 0, minute: 0))!
    let workEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: day)!
    let t15 = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: day)!
    let t20 = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: day)!

    let act = RepoActivity(repoPath: "/repos/app", commits: [
        GitCommit(hash: "1", date: t15, subject: "feat: 白天功能开发", files: [GitFileChange(path: "Day.swift", added: 10, deleted: 0)]),
        GitCommit(hash: "2", date: t20, subject: "fix: 晚上加班修复问题", files: [GitFileChange(path: "Night.swift", added: 10, deleted: 0)]),
    ])
    let tasks = [ZentaoTask(id: 101, name: "业务开发", projectID: 1, projectName: "项目A", status: "doing", left: 10, consumed: 8)]
    let recorded = [ZentaoEstimate(taskID: 101, date: "2026-11-25", consumed: 8, left: 10, work: "白天功能开发", account: "a")]
    let input = DraftInput(
        date: "2026-11-25",
        isWorkday: true,
        offDayOvertime: true,
        defaultHours: 8,
        activities: [act],
        mappings: ["/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 1, projectName: "项目A", excluded: false, sendDiff: false)],
        openTasks: tasks,
        lastTasks: ["/repos/app": 101],
        fallbackTaskID: 999,
        recorded: recorded,
        diffs: [:],
        promptTemplate: DraftGenerator.defaultPrompt,
        overtimeHours: 2,
        workEnd: workEnd
    )

    let out = await DraftGenerator.generate(input, provider: nil)
    let pending = out.entries.filter { !$0.isRecorded }
    #expect(pending.count == 1)
    #expect(pending[0].isOvertime)
    #expect(pending[0].hours == 2)
    #expect(pending[0].work.contains("晚上加班修复问题"))
}

@MainActor @Test func generateOffDayUsesPlannedOvertimeHours() async {
    let act = RepoActivity(repoPath: "/repos/app", commits: [
        GitCommit(hash: "1", date: Date(), subject: "feat: 周末紧急支持", files: [GitFileChange(path: "Hotfix.swift", added: 10, deleted: 0)]),
    ])
    let tasks = [ZentaoTask(id: 101, name: "线上支持", projectID: 1, projectName: "项目A", status: "doing", left: 10, consumed: 0)]

    let withOvertime = DraftInput(
        date: "2026-11-28",
        isWorkday: false,
        offDayOvertime: true,
        defaultHours: 8,
        activities: [act],
        mappings: ["/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 1, projectName: "项目A", excluded: false, sendDiff: false)],
        openTasks: tasks,
        lastTasks: ["/repos/app": 101],
        fallbackTaskID: 999,
        recorded: [],
        diffs: [:],
        promptTemplate: DraftGenerator.defaultPrompt,
        overtimeHours: 3
    )
    let out1 = await DraftGenerator.generate(withOvertime, provider: nil)
    #expect(out1.entries.count == 1)
    #expect(out1.entries[0].isOvertime)
    #expect(out1.entries[0].hours == 3)

    let withoutOvertime = DraftInput(
        date: "2026-11-28",
        isWorkday: false,
        offDayOvertime: true,
        defaultHours: 8,
        activities: [act],
        mappings: ["/repos/app": RepoMapping(repoPath: "/repos/app", projectID: 1, projectName: "项目A", excluded: false, sendDiff: false)],
        openTasks: tasks,
        lastTasks: ["/repos/app": 101],
        fallbackTaskID: 999,
        recorded: [],
        diffs: [:],
        promptTemplate: DraftGenerator.defaultPrompt,
        overtimeHours: 0
    )
    let out2 = await DraftGenerator.generate(withoutOvertime, provider: nil)
    #expect(out2.entries.isEmpty)
}
