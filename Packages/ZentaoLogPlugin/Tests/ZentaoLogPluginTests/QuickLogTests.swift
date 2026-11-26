import Foundation
import IronBowlKit
import Testing
@testable import ZentaoLogPlugin

@MainActor @Test func quickLogSavesTodayWithoutSwitchingTheOpenReport() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "quick-log-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: LogMigrations.all)
    let settings = SettingsStore(database: db)
    settings[LogKeys.gitRoot] = url.path
    settings[LogKeys.fallbackTaskID] = 12
    let context = PluginContext(database: db, settings: settings, reminders: ReminderCenter(),
                                workCalendar: WorkCalendar(database: db, settings: settings),
                                providers: AIProviderStore(settings: settings), openPlugin: { _ in }, openSettings: { _ in })
    let model = LogModel(context: context)
    let today = Date()
    let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: today))
    await model.select(date: yesterday)
    let capture = QuickLogCapture(model: model)
    #expect(capture.savesOriginal)
    capture.text = "和产品对需求 90 分钟"
    capture.hours = QuickLogCapture.suggestedHours(in: capture.text)
    capture.save()
    capture.save()
    let reloaded = LogModel(context: context)
    let saved = try #require(reloaded.pendingEntries(on: today).first)
    #expect(saved.work == "和产品对需求 90 分钟")
    #expect(saved.hours == 1.5 && saved.taskID == 12 && saved.isManual)
    #expect(reloaded.pendingEntries(on: today).count == 1)
    #expect(model.dateString == WorkCalendar.dayString(yesterday) && model.drafts.isEmpty)
    capture.text = "取消这条"
    capture.dismiss()
    #expect(capture.text.isEmpty && model.pendingEntries(on: today).count == 1)
}

@MainActor @Test func quickLogSuggestsEditableHalfHourUnits() {
    #expect(QuickLogCapture.suggestedHours(in: "评审 2.5 小时") == 2.5)
    #expect(QuickLogCapture.suggestedHours(in: "联调半小时") == 0.5)
    #expect(QuickLogCapture.suggestedHours(in: "测试 2h") == 2)
    #expect(QuickLogCapture.suggestedHours(in: "处理第 3 个工单") == 1)
}
