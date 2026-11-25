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

@Test func monthRangeComputesBoundariesWeeksAndRelativeBadges() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current

    // 2026-11（30天）
    let nov25 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25))!
    let nov = MonthRange.containing(nov25)
    #expect(nov.monthKey == "2026-11")
    #expect(nov.startDateString == "2026-11-01")
    #expect(nov.endDateString == "2026-11-30")
    #expect(nov.days.count == 30)
    #expect(nov.title == "2026年11月")
    #expect(nov.weeks.count == 6)
    #expect(nov.weeks.first?.id == "2026-10-26")
    #expect(nov.weeks.first?.dayStrings == ["2026-11-01"])
    #expect(nov.weeks.last?.id == "2026-11-30")
    #expect(nov.weeks.last?.dayStrings == ["2026-11-30"])

    // 2024-02 闰年（29天）与 2025-02 平年（28天）
    let leapFeb = MonthRange.fromMonthKey("2024-02")!
    #expect(leapFeb.days.count == 29)
    #expect(leapFeb.endDateString == "2024-02-29")

    let normalFeb = MonthRange.fromMonthKey("2025-02")!
    #expect(normalFeb.days.count == 28)
    #expect(normalFeb.endDateString == "2025-02-28")

    // 前后月切换与相对标签
    let oct = nov.shifted(byMonths: -1)
    #expect(oct.monthKey == "2026-10")
    #expect(oct.days.count == 31)
    #expect(nov.relativeBadge(now: nov25) == "本月")
    #expect(oct.relativeBadge(now: nov25) == "上月")
    #expect(nov.shifted(byMonths: -2).relativeBadge(now: nov25) == nil)
    #expect(MonthRange.fromMonthKey("2026-13") == nil)
}

@MainActor @Test func reportStorePersistsMonthlyReportsAndQueriesWeeklyMatches() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "report-monthly-store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: ReportMigrations.all)
    let store = ReportStore(db: db)

    let m1 = MonthlyReportRecord(
        monthKey: "2026-10",
        periodStart: "2026-10-01",
        periodEnd: "2026-10-31",
        title: "2026年10月工作月报",
        content: "## 本月重点成果\n\n1. A",
        extraNotes: "",
        style: WeeklyReportStyle.standard.rawValue,
        providerName: "本地规则汇总",
        totalHours: 160,
        generatedAt: Date(),
        updatedAt: Date()
    )
    let m2 = MonthlyReportRecord(
        monthKey: "2026-11",
        periodStart: "2026-11-01",
        periodEnd: "2026-11-30",
        title: "2026年11月工作月报",
        content: "## 本月重点成果\n\n1. B",
        extraNotes: "补充",
        style: WeeklyReportStyle.byProject.rawValue,
        providerName: "Codex",
        totalHours: 168,
        generatedAt: Date(),
        updatedAt: Date()
    )
    store.saveMonthly(m1)
    store.saveMonthly(m2)

    let loaded = store.monthlyReport(forMonthKey: "2026-11")
    #expect(loaded?.title == "2026年11月工作月报")
    #expect(loaded?.totalHours == 168)

    var updated = m2
    updated.content = "## 本月重点成果\n\n1. B（已更新）"
    store.saveMonthly(updated)
    #expect(store.monthlyReport(forMonthKey: "2026-11")?.content.contains("已更新") == true)
    #expect(store.recentMonthlyReports().map(\.monthKey) == ["2026-11", "2026-10"])

    store.deleteMonthly(monthKey: "2026-10")
    #expect(store.monthlyReport(forMonthKey: "2026-10") == nil)
    #expect(store.recentMonthlyReports().map(\.monthKey) == ["2026-11"])

    // 验证月报可检索当月内的已有周报
    store.save(WeeklyReportRecord(
        weekStart: "2026-11-16",
        weekEnd: "2026-11-22",
        title: "第47周周报",
        content: "1. 周报内容A",
        extraNotes: "",
        style: WeeklyReportStyle.standard.rawValue,
        providerName: "本地规则汇总",
        totalHours: 40,
        generatedAt: Date(),
        updatedAt: Date()
    ))
    store.save(WeeklyReportRecord(
        weekStart: "2026-11-23",
        weekEnd: "2026-11-29",
        title: "第48周周报",
        content: "1. 周报内容B",
        extraNotes: "",
        style: WeeklyReportStyle.standard.rawValue,
        providerName: "本地规则汇总",
        totalHours: 40,
        generatedAt: Date(),
        updatedAt: Date()
    ))
    let nov = MonthRange.fromMonthKey("2026-11")!
    let matched = store.weeklyReports(matchingWeekStarts: nov.weeks.map(\.id))
    #expect(matched.map(\.weekStart) == ["2026-11-16", "2026-11-23"])
}

@Test func monthlyGeneratorPromptAndFallbackRespectStylesAndWeeklyRefs() async {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let nov = MonthRange.fromMonthKey("2026-11")!
    let d1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 5))!
    let d2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 18))!

    let days = [
        DailyReportDay(
            date: d1,
            dateString: "2026-11-05",
            weekdayText: "周四",
            isWorkday: true,
            holidayName: nil,
            items: [
                DailyLogItem(id: "m1", date: "2026-11-05", taskID: 10, taskTitle: "架构重构", projectID: 1, projectName: "饭碗", hours: 8, work: "1. 完成插件底座升级\n2. 优化存储层", isOvertime: false, isDraft: false),
            ]
        ),
        DailyReportDay(
            date: d2,
            dateString: "2026-11-18",
            weekdayText: "周三",
            isWorkday: true,
            holidayName: nil,
            items: [
                DailyLogItem(id: "m2", date: "2026-11-18", taskID: 20, taskTitle: "周报月报", projectID: 1, projectName: "饭碗", hours: 8, work: "1. 完成插件底座升级\n2. 实现周报月报功能", isOvertime: false, isDraft: false),
            ]
        ),
    ]
    let weeklyRefs = [
        WeeklyReportRecord(
            weekStart: "2026-11-02",
            weekEnd: "2026-11-08",
            title: "2026年第45周工作周报",
            content: "## 本周完成工作\n\n1. 完成插件底座升级",
            extraNotes: "",
            style: WeeklyReportStyle.standard.rawValue,
            providerName: "本地规则汇总",
            totalHours: 40,
            generatedAt: Date(),
            updatedAt: Date()
        ),
    ]

    let stdInput = MonthlyReportInput(
        month: nov,
        days: days,
        weeklySummaries: weeklyRefs,
        extraNotes: "本月完成架构文档归档",
        style: .standard,
        includeHours: true,
        promptTemplate: WeeklyReportGenerator.defaultMonthlyPrompt
    )
    let promptText = WeeklyReportGenerator.prompt(stdInput)
    #expect(promptText.contains("2026年11月"))
    #expect(promptText.contains("16h"))
    #expect(promptText.contains("2026年第45周工作周报"))
    #expect(promptText.contains("本月完成架构文档归档"))

    let stdOut = await WeeklyReportGenerator.generate(stdInput, provider: nil)
    #expect(!stdOut.usedAI)
    #expect(stdOut.title == "2026年11月工作月报")
    #expect(stdOut.content.contains("## 本月重点成果"))
    #expect(stdOut.content.contains("## 本月工时统计"))
    #expect(stdOut.content.contains("## 下月工作计划"))
    #expect(stdOut.content.components(separatedBy: "完成插件底座升级").count == 2)

    let projectInput = MonthlyReportInput(
        month: nov,
        days: days,
        weeklySummaries: [],
        extraNotes: "",
        style: .byProject,
        includeHours: false,
        promptTemplate: WeeklyReportGenerator.defaultMonthlyPrompt
    )
    let projectOut = await WeeklyReportGenerator.generate(projectInput, provider: nil)
    #expect(projectOut.content.contains("## 饭碗\n"))
    #expect(!projectOut.content.contains("## 月度工时汇总"))

    let conciseInput = MonthlyReportInput(
        month: nov,
        days: days,
        weeklySummaries: [],
        extraNotes: "",
        style: .concise,
        includeHours: true,
        promptTemplate: WeeklyReportGenerator.defaultMonthlyPrompt
    )
    let conciseOut = await WeeklyReportGenerator.generate(conciseInput, provider: nil)
    #expect(conciseOut.content.contains("## 本月工作要点"))
    #expect(conciseOut.content.contains("**本月工时**：共 16h"))
}

@MainActor @Test func reportModelSupportsMonthlyModeAndSwitchesCleanlyWithWeekly() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "report-model-monthly-\(UUID().uuidString).sqlite")
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
    let currentMonth = MonthRange.containing(Date())
    let firstDay = currentMonth.dayStrings.first!
    let lastDay = currentMonth.dayStrings.last!

    logStore.add(Submission(id: nil, date: firstDay, taskID: 101, hours: 8, left: 4, work: "1. 月初需求设计", isOvertime: false, submittedAt: Date()))
    logStore.savePendingDrafts([DraftEntry(taskID: 102, hours: 3, left: 0, work: "1. 月末验收发布", isOvertime: true)], for: lastDay)

    let model = WeeklyReportModel(context: context)
    await model.switchPeriodKind(.monthly)

    #expect(model.periodKind == .monthly)
    #expect(model.totalHours == 11)
    #expect(model.loggedDaysCount == 2)
    #expect(!model.hasCurrentMonthReport)

    await model.generate()
    #expect(model.hasReportContent)
    #expect(model.hasCurrentMonthReport)
    #expect(model.reportContent.contains("月初需求设计"))
    #expect(model.reportContent.contains("月末验收发布"))

    // 按周筛选只保留最后一周的记录
    let lastWeekID = currentMonth.weeks.last!.id
    model.selectedWeekFilter = lastWeekID
    #expect(model.filteredDays.map(\.dateString) == [lastDay])
    model.clearActiveFilter()
    #expect(model.filteredDays.count == 2)

    // 切到上月再切回本月，并切换到周报后再切回月报，均应持久保留
    await model.previousMonth()
    #expect(!model.hasReportContent)
    await model.goToCurrentMonth()
    #expect(model.hasReportContent)

    await model.switchPeriodKind(.weekly)
    #expect(model.periodKind == .weekly)
    await model.switchPeriodKind(.monthly)
    #expect(model.hasReportContent)
    #expect(model.reportContent.contains("月初需求设计"))
}

@MainActor @Test func weeklyAndMonthlyPluginsHaveDistinctIDsMigrationsAndLockedModes() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "report-dual-plugins-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let weeklyPlugin = ReportPlugin()
    let monthlyPlugin = MonthlyReportPlugin()

    #expect(weeklyPlugin.id == "report")
    #expect(monthlyPlugin.id == "report.monthly")
    #expect(weeklyPlugin.title == "周报")
    #expect(monthlyPlugin.title == "月报")

    let combinedMigrations = weeklyPlugin.migrations + monthlyPlugin.migrations
    #expect(Set(combinedMigrations.map(\.identifier)).count == 2)

    let db = try AppDatabase(url: url, migrations: ZentaoLogPlugin().migrations + combinedMigrations)
    let settings = SettingsStore(database: db)
    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: ReminderCenter(),
        workCalendar: WorkCalendar(database: db, settings: settings),
        providers: AIProviderStore(settings: settings),
        openPlugin: { _ in },
        openSettings: { _ in }
    )

    weeklyPlugin.start(context: context)
    monthlyPlugin.start(context: context)
    defer {
        weeklyPlugin.stop()
        monthlyPlugin.stop()
    }

    #expect(weeklyPlugin.model?.lockedPeriodKind == .weekly)
    #expect(weeklyPlugin.model?.periodKind == .weekly)
    #expect(monthlyPlugin.model?.lockedPeriodKind == .monthly)
    #expect(monthlyPlugin.model?.periodKind == .monthly)

    // 锁定模式下不会相互切换周期
    await weeklyPlugin.model?.switchPeriodKind(.monthly)
    await monthlyPlugin.model?.switchPeriodKind(.weekly)
    #expect(weeklyPlugin.model?.periodKind == .weekly)
    #expect(monthlyPlugin.model?.periodKind == .monthly)
}

@Test func titaCredentialParserExtractsCookiesAndIdentifiers() {
    // 1. Chrome Copy as cURL (-H 'cookie: ...')
    let curlWithHeader = """
    curl 'https://www.tita.net/api/v1/880017/804751550/summary/detail?summaryType=26&summaryDate=2026-11-04' \\
      -H 'accept: application/json, text/plain, */*' \\
      -H 'cookie: sid=abc123; uid=xyz'
    """
    let parsed1 = TitaCredentialParser.parse(curlWithHeader)
    #expect(parsed1.cookie == "sid=abc123; uid=xyz")
    #expect(parsed1.baseURL == "https://www.tita.net")
    #expect(parsed1.tenantID == "880017")
    #expect(parsed1.userID == "804751550")

    // 2. Chrome Copy as cURL (-b '...')
    let curlWithB = "curl 'https://www.tita.net/u/804751550/Home/' -b 'token=foo; bar=baz'"
    let parsed2 = TitaCredentialParser.parse(curlWithB)
    #expect(parsed2.cookie == "token=foo; bar=baz")
    #expect(parsed2.userID == "804751550")
    #expect(parsed2.tenantID == nil)

    // 3. Raw HTTP header block
    let headerBlock = """
    Accept: application/json
    Cookie: a=1; b=2
    Referer: https://www.tita.net/
    """
    let parsed3 = TitaCredentialParser.parse(headerBlock)
    #expect(parsed3.cookie == "a=1; b=2")

    // 4. Plain cookie string
    let plain = TitaCredentialParser.parse("  a=1; b=2  ")
    #expect(plain.cookie == "a=1; b=2")
}

@Test func titaBSGlobalParserExtractsTenantUserAndName() {
    let html = """
    <script>
    window.BSGlobal = {
      tenantInfo: { Id: 880017, Name: "某公司" },
      loginUserInfo: { Id: 804751550, Name: "\\u5f20\\u4e09" },
      apiPath: "//www.tita.net"
    };
    </script>
    """
    let info = TitaBSGlobalParser.parse(html: html, finalURL: URL(string: "https://www.tita.net/u/804751550/Home"))
    #expect(info?.tenantID == "880017")
    #expect(info?.userID == "804751550")
    #expect(info?.userName == "张三")
}

@Test func titaPeriodCodeComputesWeeklyAndMonthlyCodes() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current

    // 2026年11月：周一分别是 11/2(W1), 11/9(W2), 11/16(W3), 11/23(W4), 11/30(W5)
    let w1 = WeekRange.containing(cal.date(from: DateComponents(year: 2026, month: 11, day: 4))!)
    let w3 = WeekRange.containing(cal.date(from: DateComponents(year: 2026, month: 11, day: 18))!)
    let w4 = WeekRange.containing(cal.date(from: DateComponents(year: 2026, month: 11, day: 25))!)
    let w5CrossMonth = WeekRange.containing(cal.date(from: DateComponents(year: 2026, month: 12, day: 2))!) // 周一为 2026-11-30

    #expect(TitaPeriodCode.weeklySummaryDate(for: w1) == "2026-11-01")
    #expect(TitaPeriodCode.weeklyStatusDate(for: w1) == "2026/11/01")
    #expect(TitaPeriodCode.weeklySummaryDate(for: w3) == "2026-11-03")
    #expect(TitaPeriodCode.weeklySummaryDate(for: w4) == "2026-11-04")
    #expect(TitaPeriodCode.weeklySummaryDate(for: w5CrossMonth) == "2026-11-05")

    // 2026年6月1日恰好是周一 -> W1
    let jun1Week = WeekRange.containing(cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!)
    #expect(TitaPeriodCode.weeklySummaryDate(for: jun1Week) == "2026-06-01")

    let nov = MonthRange.fromMonthKey("2026-11")!
    #expect(TitaPeriodCode.monthlySummaryDate(for: nov) == "2026-11-01")
    #expect(TitaPeriodCode.monthlyStatusDate(for: nov) == "2026/11/01")

    let editorURL = TitaPeriodCode.webEditorURL(
        baseURL: "https://www.tita.net",
        userID: "804751550",
        periodKind: .weekly,
        summaryDate: "2026-11-04",
        templateID: 1006,
        isCreate: false
    )
    #expect(editorURL?.absoluteString == "https://www.tita.net/u/804751550/Home/#/summary/template?isCreate=false&hideNavTop=true&reportType=26&currentTime=2026-11-04&templateId=1006&activeKey=week")
}

@Test func titaRichTextConverterAndMapperWorkEndToEnd() async throws {
    let md = """
    ## 亮点与成功经验

    ### 饭碗
    1. 完成 **Tita** 对接 `API` 开发
    2. 支持自动拆分

    ## 问题与不足

    - 暂无明显阻塞

    ## 改进思考与行动

    - 补充单元测试

    ## 下一步工作计划

    1. 上线验收
    """

    let mapped = TitaContentMapper.map(markdown: md, toModules: TitaContentMapper.defaultModuleNames)
    #expect(mapped.count == 4)
    #expect(mapped[0].contains("完成 **Tita** 对接 `API` 开发"))
    #expect(mapped[1].contains("暂无明显阻塞"))
    #expect(mapped[2].contains("补充单元测试"))
    #expect(mapped[3].contains("上线验收"))

    // 标准周报风格也能自动归类工时和计划
    let standardMd = """
    ## 本周完成工作

    1. 完成任务 A

    ## 工时统计

    - 总工时 40h

    ## 问题与风险

    - 联调延迟

    ## 下周工作计划

    1. 推进任务 B
    """
    let stdMapped = TitaContentMapper.map(markdown: standardMd, toModules: TitaContentMapper.defaultModuleNames)
    #expect(stdMapped[0].contains("完成任务 A"))
    #expect(stdMapped[0].contains("总工时 40h"))
    #expect(stdMapped[1].contains("联调延迟"))
    #expect(stdMapped[3].contains("推进任务 B"))

    // HTML 转换验证
    let converted = TitaRichTextConverter.convert(markdown: mapped[0])
    #expect(converted.richText.contains("<strong>饭碗</strong>"))
    #expect(converted.richText.contains("<ol><li class=\"tita-rich-editor-li\"><p style=\"text-align:left\">完成 <strong>Tita</strong> 对接 <code>API</code> 开发</p></li>"))
    #expect(converted.plainText.contains("完成 Tita 对接 API 开发"))
    #expect(TitaRichTextConverter.plainTextFromHTML(converted.richText).contains("饭碗"))

    // 风格兜底测试 (.tita)
    let week = WeekRange.fromStartDateString("2026-11-23")!
    let input = WeeklyReportInput(
        week: week,
        days: [],
        extraNotes: "补充测试说明",
        style: .tita,
        includeHours: true,
        promptTemplate: WeeklyReportGenerator.defaultPrompt
    )
    let out = await WeeklyReportGenerator.generate(input, provider: nil)
    #expect(out.content.contains("## 亮点与成功经验"))
    #expect(out.content.contains("## 改进思考与行动"))
}

@Test func titaSubmitPayloadBuilderPreservesOtherModules() throws {
    let detail = TitaReportDetail(
        dailyID: "880017_804751550_26_4_12345",
        summaryDate: "2026-11-04",
        summaryType: .weekly,
        submitState: .unSubmit,
        templateID: 1006,
        delayDate: nil,
        modules: [
            TitaReportModule(moduleId: 1, moduleName: "心情", moduleType: "select", moduleObjType: 1, sortIndex: 1, isDelete: false, plainText: "", richTextHTML: "", rawObjectDataJSON: "0"),
            TitaReportModule(moduleId: 2, moduleName: "OKR", moduleType: "table", moduleObjType: 2, sortIndex: 2, isDelete: false, plainText: "", richTextHTML: "", rawObjectDataJSON: "{\"rows\":[]}"),
            TitaReportModule(moduleId: 3, moduleName: "工作总结（亮点与成功经验）", moduleType: "richtext", moduleObjType: 0, sortIndex: 3, isDelete: false, plainText: "", richTextHTML: "", rawObjectDataJSON: "{}"),
            TitaReportModule(moduleId: 7, moduleName: "附件", moduleType: "dfs", moduleObjType: 4, sortIndex: 7, isDelete: false, plainText: "", richTextHTML: "", rawObjectDataJSON: "{\"files\":[\"a.pdf\"]}"),
            TitaReportModule(moduleId: 8, moduleName: "@ta查看", moduleType: "at", moduleObjType: 5, sortIndex: 8, isDelete: false, plainText: "", richTextHTML: "", rawObjectDataJSON: "{\"userIds\":[100]}"),
        ]
    )

    let converted = TitaRichTextConverter.convert(markdown: "1. 完成开发")
    let payload = try TitaSubmitPayloadBuilder.buildSubmitBody(detail: detail, updatedRichTexts: [3: converted])

    #expect(payload["OKRModuleValue"] as? String == "{\"rows\":[]}")
    #expect(payload["DfsModuleValue"] as? String == "{\"files\":[\"a.pdf\"]}")
    #expect(payload["AtModuleValue"] as? String == "{\"userIds\":[100]}")
    let richValues = try #require(payload["ModuleRichValues"] as? [String])
    #expect(richValues.count == 1)
    #expect(richValues[0].contains("完成开发"))
}
