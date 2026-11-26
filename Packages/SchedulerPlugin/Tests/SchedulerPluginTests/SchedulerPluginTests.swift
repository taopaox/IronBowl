import Foundation
import IronBowlKit
import Testing
@testable import SchedulerPlugin

@MainActor @Test func schedulerPluginLifecycleAndHomeCard() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "scheduler-plugin-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
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

    let plugin = SchedulerPlugin()
    #expect(plugin.id == "scheduler")
    #expect(plugin.title == "定时任务")
    #expect(!scheduler.isStarted)

    plugin.start(context: context)
    #expect(scheduler.isStarted)

    let seeded = try #require(scheduler.tasks.first(where: { $0.id == TaskScheduler.defaultClockOutReminderTaskID }))
    #expect(seeded.name == "打卡提醒")
    #expect(seeded.actionID == TaskScheduler.coreClockOutReminderActionID)
    #expect(seeded.isEnabled)
    #expect(seeded.schedule.kind == .beforeWorkEnd)
    #expect(seeded.schedule.minutesBeforeWorkEnd == 5)
    #expect(seeded.notifyStyle == .cornerCard)
    #expect(seeded.parameters["keepVisible"] == "true")

    scheduler.setEnabled(taskID: seeded.id, enabled: false)

    scheduler.saveTask(ScheduledTask(
        id: "t.card",
        name: "测试提醒",
        actionID: TaskScheduler.coreReminderActionID,
        schedule: TaskSchedule(kind: .daily, hour: 17, minute: 0)
    ))

    #expect(plugin.homeCards.count == 1)
    #expect(plugin.menuBarItems.count == 1)
    #expect(plugin.homeCards[0].detail()?.contains("测试提醒") == true)
    let menuText = plugin.menuBarItems[0].text()
    #expect(menuText?.hasPrefix("距任务 ") == true)
    #expect(menuText?.contains(":") == false)

    plugin.stop()
    #expect(!scheduler.isStarted)
}
