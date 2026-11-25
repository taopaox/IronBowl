import Foundation
import IronBowlKit
import Testing
@testable import ReportPlugin
@testable import ZentaoLogPlugin

@Test func weekRangeComputesMondayToSundayBoundaries() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current

    // 2026-11-25 是周三
    let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 18, minute: 30))!
    let week = WeekRange.containing(wed)
    #expect(week.startDateString == "2026-11-23")
    #expect(week.endDateString == "2026-11-29")
    #expect(week.days.count == 7)
    #expect(week.isoYear == 2026)
    #expect(week.weekOfYear == 48)
    #expect(week.title == "2026年第48周")

    // 周一与周日都归属同一周
    let mon = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 0, minute: 0))!
    let sun = cal.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 23, minute: 59))!
    #expect(WeekRange.containing(mon) == week)
    #expect(WeekRange.containing(sun) == week)

    // 前后周切换与相对标签
    let prev = week.shifted(byWeeks: -1)
    #expect(prev.startDateString == "2026-11-16")
    #expect(prev.endDateString == "2026-11-22")
    #expect(week.relativeBadge(now: wed) == "本周")
    #expect(prev.relativeBadge(now: wed) == "上周")
    #expect(week.shifted(byWeeks: -2).relativeBadge(now: wed) == nil)

    // 跨年周（2026-12-31 周四，周一 12-28 到周日 2027-01-03）
    let dec31 = cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!
    let crossYear = WeekRange.containing(dec31)
    #expect(crossYear.startDateString == "2026-12-28")
    #expect(crossYear.endDateString == "2027-01-03")
    #expect(WeekRange.fromStartDateString("2026-11-23") == week)
}

@MainActor @Test func reportStorePersistsUpdatesListsAndDeletes() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "report-store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: ReportMigrations.all)
    let store = ReportStore(db: db)

    let w1 = WeeklyReportRecord(
        weekStart: "2026-11-16",
        weekEnd: "2026-11-22",
        title: "第47周周报",
        content: "## 本周完成工作\n\n1. A",
        extraNotes: "",
        style: WeeklyReportStyle.standard.rawValue,
        providerName: "本地规则汇总",
        totalHours: 40,
        generatedAt: Date(),
        updatedAt: Date()
    )
    let w2 = WeeklyReportRecord(
        weekStart: "2026-11-23",
        weekEnd: "2026-11-29",
        title: "第48周周报",
        content: "## 本周完成工作\n\n1. B",
        extraNotes: "补充",
        style: WeeklyReportStyle.byProject.rawValue,
        providerName: "Codex",
        totalHours: 42,
        generatedAt: Date(),
        updatedAt: Date()
    )

    store.save(w1)
    store.save(w2)

    let loaded = store.report(forWeekStart: "2026-11-23")
    #expect(loaded?.title == "第48周周报")
    #expect(loaded?.totalHours == 42)

    // 覆盖更新
    var updated = w2
    updated.content = "## 本周完成工作\n\n1. B（已修改）"
    store.save(updated)
    #expect(store.report(forWeekStart: "2026-11-23")?.content.contains("已修改") == true)

    let recent = store.recentReports()
    #expect(recent.map(\.weekStart) == ["2026-11-23", "2026-11-16"])

    store.delete(weekStart: "2026-11-16")
    #expect(store.report(forWeekStart: "2026-11-16") == nil)
    #expect(store.recentReports().map(\.weekStart) == ["2026-11-23"])
}

@Test func generatorPromptAndFallbackRespectStylesAndOptions() async {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let mon = cal.date(from: DateComponents(year: 2026, month: 11, day: 23))!
    let tue = cal.date(from: DateComponents(year: 2026, month: 11, day: 24))!
    let week = WeekRange.containing(mon)

    let days = [
        DailyReportDay(
            date: mon,
            dateString: "2026-11-23",
            weekdayText: "周一",
            isWorkday: true,
            holidayName: nil,
            items: [
                DailyLogItem(id: "1", date: "2026-11-23", taskID: 10, taskTitle: "周报模块", projectID: 1, projectName: "饭碗", hours: 8, work: "1. 完成周报数据查询\n2. 联调周报生成", isOvertime: false, isDraft: false),
            ]
        ),
        DailyReportDay(
            date: tue,
            dateString: "2026-11-24",
            weekdayText: "周二",
            isWorkday: true,
            holidayName: nil,
            items: [
                DailyLogItem(id: "2", date: "2026-11-24", taskID: 10, taskTitle: "周报模块", projectID: 1, projectName: "饭碗", hours: 2, work: "1. 完成周报数据查询\n2. 支持 Markdown 导出", isOvertime: true, isDraft: false),
                DailyLogItem(id: "3", date: "2026-11-24", taskID: 20, taskTitle: "运维支持", projectID: 2, projectName: "后台", hours: 4, work: "排查测试环境告警", isOvertime: false, isDraft: true),
            ]
        ),
    ]

    let stdInput = WeeklyReportInput(
        week: week,
        days: days,
        extraNotes: "周三参加需求评审",
        style: .standard,
        includeHours: true,
        promptTemplate: WeeklyReportGenerator.defaultPrompt
    )
    let promptText = WeeklyReportGenerator.prompt(stdInput)
    #expect(promptText.contains("2026年第48周"))
    #expect(promptText.contains("14h"))
    #expect(promptText.contains("完成周报数据查询"))
    #expect(promptText.contains("周三参加需求评审"))

    let stdOut = await WeeklyReportGenerator.generate(stdInput, provider: nil)
    #expect(!stdOut.usedAI)
    #expect(stdOut.content.contains("## 本周完成工作"))
    #expect(stdOut.content.contains("### 饭碗（10h）"))
    #expect(stdOut.content.contains("## 工时统计"))
    #expect(stdOut.content.contains("## 补充说明"))
    #expect(stdOut.content.contains("周三参加需求评审"))
    // 重复要点去重
    #expect(stdOut.content.components(separatedBy: "完成周报数据查询").count == 2)

    let projectInput = WeeklyReportInput(
        week: week,
        days: days,
        extraNotes: "",
        style: .byProject,
        includeHours: false,
        promptTemplate: WeeklyReportGenerator.defaultPrompt
    )
    let projectOut = await WeeklyReportGenerator.generate(projectInput, provider: nil)
    #expect(projectOut.content.contains("## 饭碗\n"))
    #expect(!projectOut.content.contains("## 工时汇总"))

    let conciseInput = WeeklyReportInput(
        week: week,
        days: days,
        extraNotes: "",
        style: .concise,
        includeHours: true,
        promptTemplate: WeeklyReportGenerator.defaultPrompt
    )
    let conciseOut = await WeeklyReportGenerator.generate(conciseInput, provider: nil)
    #expect(conciseOut.content.contains("## 本周工作要点"))
    #expect(conciseOut.content.contains("[饭碗] 完成周报数据查询"))
    #expect(conciseOut.content.contains("**本周工时**：共 14h"))
}

@MainActor @Test func reportModelQueriesWeekLogsGeneratesAndPersistsAcrossWeekSwitch() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "report-model-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let migrations = ZentaoLogPlugin().migrations + ReportMigrations.all
    let db = try AppDatabase(url: url, migrations: migrations)
    let settings = SettingsStore(database: db)
    let workCalendar = WorkCalendar(database: db, settings: settings)
    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: ReminderCenter(),
        workCalendar: workCalendar,
        providers: AIProviderStore(settings: settings),
        openPlugin: { _ in },
        openSettings: { _ in }
    )

    let logStore = LogStore(db: db)
    let currentWeek = WeekRange.containing(Date())
    let mondayStr = currentWeek.dayStrings[0]
    let tuesdayStr = currentWeek.dayStrings[1]

    logStore.add(Submission(id: nil, date: mondayStr, taskID: 101, hours: 8, left: 4, work: "1. 完成周报插件数据层", isOvertime: false, submittedAt: Date()))
    logStore.savePendingDrafts([DraftEntry(taskID: 102, hours: 2.5, left: 0, work: "1. 编写周报界面", isOvertime: true)], for: tuesdayStr)

    let model = WeeklyReportModel(context: context)
    #expect(model.totalHours == 10.5)
    #expect(model.loggedDaysCount == 2)
    #expect(!model.hasCurrentWeekReport)

    model.includeDrafts = false
    #expect(model.totalHours == 8)
    #expect(model.loggedDaysCount == 1)

    model.includeDrafts = true
    #expect(model.totalHours == 10.5)

    await model.generate()
    #expect(model.hasReportContent)
    #expect(model.hasCurrentWeekReport)
    #expect(model.reportContent.contains("完成周报插件数据层"))
    #expect(model.reportContent.contains("编写周报界面"))

    // 切换到上周并切回，已生成的周报应持久保留
    await model.previousWeek()
    #expect(!model.hasReportContent)
    await model.goToCurrentWeek()
    #expect(model.hasReportContent)
    #expect(model.reportContent.contains("完成周报插件数据层"))
}
