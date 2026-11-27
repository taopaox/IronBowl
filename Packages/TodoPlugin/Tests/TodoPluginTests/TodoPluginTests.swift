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

@MainActor
@Test func scratchpadStoreCRUDJSONAndDerivedTitle() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "scratchpad-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: [])
    let store = ScratchpadStore(database: db)

    let first = try #require(store.createNote(title: "", content: "# 联调参数\n{\"b\":2,\"a\":1}", colorTag: .blue))
    let second = try #require(store.createNote(title: "测试账号", content: "admin / 123456", colorTag: .green, isPinned: true))

    // 置顶的排在前面
    #expect(store.notes.map(\.id) == [second.id, first.id])
    #expect(first.displayTitle == "联调参数")
    #expect(ScratchpadStore.derivedTitle(title: "", content: "") == "无标题便签")

    // JSON 美化与压缩
    let pretty = try ScratchpadStore.formatJSON(#"{"b":2,"a":1}"#).get()
    #expect(pretty.contains("\n"))
    #expect(pretty.contains("\"a\" : 1"))
    let minified = try ScratchpadStore.minifyJSON(pretty).get()
    #expect(minified == #"{"a":1,"b":2}"#)

    store.togglePinned(id: first.id)
    #expect(store.notes.first?.id == first.id)

    store.delete(id: second.id)
    #expect(store.notes.count == 1)
}
