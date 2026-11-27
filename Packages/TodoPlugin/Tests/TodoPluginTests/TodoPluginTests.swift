import Foundation
import IronBowlKit
import Testing
import ZentaoLogPlugin
@testable import TodoPlugin

@MainActor
@Test func todoStoreCRUDCountsAndReminders() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "todo-store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: ZentaoLogPlugin().migrations)
    let settings = SettingsStore(database: db)
    let calendar = WorkCalendar(database: db, settings: settings)
    let store = TodoStore(database: db)

    let today = Calendar.current.startOfDay(for: Date())
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let todayKey = WorkCalendar.dayString(today)
    let yesterdayKey = WorkCalendar.dayString(yesterday)

    let overdueItem = try #require(store.add(
        title: "补齐旧需求测试",
        notes: "覆盖边界用例",
        dueDate: yesterdayKey,
        priority: .urgent,
        estimatedHours: 1.5
    ))
    let dueReminderTime = Date().addingTimeInterval(-60)
    let todayItem = try #require(store.add(
        title: "参加架构评审会",
        dueDate: todayKey,
        remindAt: dueReminderTime,
        priority: .important,
        estimatedHours: 2.0
    ))

    #expect(store.items.count == 2)
    #expect(store.overdueCount(now: today) == 1)
    #expect(store.todayIncompleteCount(now: today) == 2)
    #expect(store.dueReminderItems().map(\.id) == [todayItem.id])

    store.markReminded(id: todayItem.id)
    #expect(store.dueReminderItems().isEmpty)

    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: ReminderCenter(database: db),
        workCalendar: calendar,
        providers: AIProviderStore(settings: settings),
        todos: store,
        openPlugin: { _ in },
        openSettings: { _ in }
    )
    #expect(TodoPlugin.sendToDailyDraft(item: todayItem, context: context))

    let refreshed = try #require(store.items.first { $0.id == todayItem.id })
    #expect(refreshed.loggedDate == todayKey)

    let logService = ZentaoDailyLogService(database: db, settings: settings)
    let drafts = logService.loadLocal(from: todayKey, to: todayKey, includeDrafts: true)[todayKey] ?? []
    #expect(drafts.count == 1)
    #expect(drafts[0].work.contains("参加架构评审会"))
    #expect(drafts[0].hours == 2.0)

    store.toggleCompleted(id: overdueItem.id)
    #expect(store.overdueCount(now: today) == 0)

    store.clearCompleted()
    #expect(store.items.count == 1)
}
