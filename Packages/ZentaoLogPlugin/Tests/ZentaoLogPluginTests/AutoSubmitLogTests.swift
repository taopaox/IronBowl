import Foundation
import IronBowlKit
import Testing
@testable import ZentaoLogPlugin

@MainActor @Test func zentaoPluginSeedsDaily5PMWorkdayAutoSubmitTask() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentao-seed-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let settings = SettingsStore(database: db)
    settings[LogKeys.scanMode] = .manualOnly
    let workCalendar = WorkCalendar(database: db, settings: settings)
    let reminders = ReminderCenter()
    let scheduler = TaskScheduler(
        database: db,
        settings: settings,
        workCalendar: workCalendar,
        reminders: reminders
    )
    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: reminders,
        workCalendar: workCalendar,
        providers: AIProviderStore(settings: settings),
        scheduler: scheduler,
        openPlugin: { _ in },
        openSettings: { _ in }
    )

    let plugin = ZentaoLogPlugin()
    #expect(plugin.title == "禅道日志")
    #expect(plugin.sidebarTitle == "日报")
    #expect(plugin.sidebarSection == "汇报")
    plugin.start(context: context)
    defer { plugin.stop() }

    #expect(scheduler.action(id: ZentaoLogPlugin.autoSubmitActionID) != nil)
    let seeded = scheduler.tasks.first(where: { $0.id == ZentaoLogPlugin.defaultAutoSubmitTaskID })
    #expect(seeded != nil)
    #expect(seeded?.isEnabled == true)
    #expect(seeded?.schedule.kind == .workdays)
    #expect(seeded?.schedule.hour == 17)
    #expect(seeded?.schedule.minute == 0)
    #expect(seeded?.parameters["draftStrategy"] == AutoLogDraftStrategy.regenerate.rawValue)
    #expect(seeded?.parameters["allowFallbackOnAIFailure"] == "true")
}

@MainActor @Test func autoSubmitFailsWhenZentaoNotConfigured() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentao-unconf-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let settings = SettingsStore(database: db)
    settings[LogKeys.scanMode] = .manualOnly
    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: ReminderCenter(),
        workCalendar: WorkCalendar(database: db, settings: settings),
        providers: AIProviderStore(settings: settings),
        openPlugin: { _ in },
        openSettings: { _ in }
    )
    let model = LogModel(context: context)

    let outcome = await model.autoGenerateAndSubmitToday()
    #expect(outcome.status == .failed)
    #expect(outcome.summary.contains("未配置禅道账号"))
    #expect(outcome.actionSettingsPageID == ZentaoLogPlugin.settingsAccountID)
}

@MainActor @Test func autoSubmitDoesNotDisturbSelectedHistoricalDate() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "zentao-date-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let settings = SettingsStore(database: db)
    settings[LogKeys.scanMode] = .manualOnly
    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: ReminderCenter(),
        workCalendar: WorkCalendar(database: db, settings: settings),
        providers: AIProviderStore(settings: settings),
        openPlugin: { _ in },
        openSettings: { _ in }
    )
    let model = LogModel(context: context)
    model.lastScan = Date()
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
    await model.select(date: yesterday)
    let selectedBefore = model.dateString

    let outcome = await model.autoGenerateAndSubmitToday()
    #expect(outcome.status == .failed)
    #expect(model.dateString == selectedBefore)
}
