import Foundation
import Testing
import UserNotifications
@testable import IronBowlKit

@Test func systemNotificationStatusEvaluation() {
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .notDetermined,
            alertSetting: .notSupported,
            alertStyle: .none
        ) == .notDetermined
    )
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .denied,
            alertSetting: .enabled,
            alertStyle: .banner
        ) == .denied
    )
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .authorized,
            alertSetting: .enabled,
            alertStyle: .banner
        ) == .authorized
    )
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .authorized,
            alertSetting: .enabled,
            alertStyle: .alert
        ) == .authorized
    )
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .authorized,
            alertSetting: .disabled,
            alertStyle: .banner
        ) == .alertsDisabled
    )
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .authorized,
            alertSetting: .enabled,
            alertStyle: .none
        ) == .alertsDisabled
    )
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .provisional,
            alertSetting: .enabled,
            alertStyle: .banner
        ) == .authorized
    )
    #expect(
        SystemNotificationStatus.evaluate(
            authorizationStatus: .provisional,
            alertSetting: .enabled,
            alertStyle: .none
        ) == .alertsDisabled
    )

    #expect(SystemNotificationStatus.authorized.canPresentAlert)
    #expect(!SystemNotificationStatus.denied.canPresentAlert)
    #expect(!SystemNotificationStatus.alertsDisabled.canPresentAlert)
    #expect(!SystemNotificationStatus.notDetermined.canPresentAlert)
    #expect(!SystemNotificationStatus.unavailable.canPresentAlert)
}

@Test func systemNotificationSettingsURLsIncludeAppAndFallbacks() {
    let urls = ReminderCenter.systemNotificationSettingsURLs(bundleIdentifier: "com.taopaox.ironbowl")
    #expect(urls.map(\.absoluteString) == [
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.taopaox.ironbowl",
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.notifications",
    ])

    let nilBundleURLs = ReminderCenter.systemNotificationSettingsURLs(bundleIdentifier: nil)
    #expect(nilBundleURLs.map(\.absoluteString) == [
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.notifications",
    ])

    let emptyBundleURLs = ReminderCenter.systemNotificationSettingsURLs(bundleIdentifier: "")
    #expect(emptyBundleURLs.map(\.absoluteString) == [
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.notifications",
    ])
}

@MainActor
@Test func reminderCenterReportsUnavailableOutsideAppBundle() async {
    let center = ReminderCenter()
    let status = await center.systemNotificationStatus()
    #expect(status == .unavailable)

    let content = ReminderContent(
        id: "test.preview",
        title: "测试提醒",
        message: "测试正文",
        actions: [ReminderAction(id: "ok", title: "确定", isPrimary: true) {}]
    )
    let result = await center.showAndReport(content, style: .system)
    #expect(result == .unavailable)
    #expect(center.history.count == 1)
    #expect(center.unreadCount == 1)
    #expect(center.history.first?.deliveryStatus == .unavailable)
}

@Test func reminderSourceInferenceByReminderID() {
    #expect(ReminderSource.infer(fromReminderID: "zentao.log.reminder") == .zentao)
    #expect(ReminderSource.infer(fromReminderID: "scheduler.task.123") == .scheduler)
    #expect(ReminderSource.infer(fromReminderID: "core.attendance.issue") == .attendance)
    #expect(ReminderSource.infer(fromReminderID: "custom.notice") == .general)
}

@Test func reminderHistoryStoreCRUDAndPruning() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "reminder-store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let store = ReminderHistoryStore(db: db)

    let base = Date(timeIntervalSince1970: 1_764_000_000)
    let first = try #require(store.insert(ReminderHistoryDraft(
        reminderID: "zentao.log.reminder",
        title: "写日报提醒",
        message: "今天还没提交日报",
        systemImage: "square.and.pencil",
        source: .zentao,
        style: .cornerCard,
        targetPluginID: "zentao.log",
        createdAt: base
    )))
    let second = try #require(store.insert(ReminderHistoryDraft(
        reminderID: "scheduler.task.abc",
        title: "喝水提醒",
        message: "休息五分钟",
        systemImage: "bell.badge",
        source: .scheduler,
        style: .system,
        targetPluginID: "scheduler",
        createdAt: base.addingTimeInterval(60)
    )))
    let third = try #require(store.insert(ReminderHistoryDraft(
        reminderID: "core.attendance.issue",
        title: "考勤同步异常",
        message: "请登录钉钉 CLI",
        systemImage: "exclamationmark.triangle.fill",
        source: .attendance,
        style: .cornerCard,
        targetSettingsPage: "worktime",
        createdAt: base.addingTimeInterval(120)
    )))

    var list = store.fetchRecent()
    #expect(list.map(\.id) == [third.id, second.id, first.id])
    #expect(list.allSatisfy { !$0.isRead })

    store.updateDelivery(id: second.id, status: .permissionDenied, detail: "未授权")
    store.markHandled(id: first.id, actionTitle: "去写日志", at: base.addingTimeInterval(180))
    list = store.fetchRecent()
    let updatedFirst = try #require(list.first { $0.id == first.id })
    #expect(updatedFirst.isRead)
    #expect(updatedFirst.handledActionTitle == "去写日志")
    #expect(updatedFirst.readAt != nil)

    let updatedSecond = try #require(list.first { $0.id == second.id })
    #expect(updatedSecond.deliveryStatus == .permissionDenied)
    #expect(updatedSecond.deliveryDetail == "未授权")

    store.setRead(id: first.id, isRead: false)
    #expect(store.fetchRecent().first { $0.id == first.id }?.isRead == false)

    store.markAllRead(source: .scheduler)
    #expect(store.fetchRecent().first { $0.id == second.id }?.isRead == true)
    #expect(store.fetchRecent().first { $0.id == third.id }?.isRead == false)

    store.markAllRead()
    let allRead = store.fetchRecent().allSatisfy(\.isRead)
    #expect(allRead)

    store.delete(id: third.id)
    #expect(store.fetchRecent().map(\.id) == [second.id, first.id])

    store.prune(keepingLatest: 1)
    #expect(store.fetchRecent().map(\.id) == [second.id])

    store.clearAll(source: .scheduler)
    #expect(store.fetchRecent().isEmpty)
}

@MainActor
@Test func reminderCenterPersistsHistoryAndSkipsNonRecordedPreviews() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "reminder-center-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])

    let center = ReminderCenter(database: db)
    #expect(center.history.isEmpty)
    #expect(center.unreadCount == 0)

    let recorded = ReminderContent(
        id: "zentao.log.reminder",
        title: "今天的禅道日志还没写",
        message: "点一下就能生成草稿",
        systemImage: "square.and.pencil",
        source: .zentao,
        targetPluginID: "zentao.log",
        actions: [ReminderAction(id: "write", title: "去写日志", isPrimary: true) {}]
    )
    let preview = ReminderContent(
        id: "zentao.log.preview.system",
        title: "预览提醒",
        message: "不写入历史",
        source: .zentao,
        recordInHistory: false,
        actions: [ReminderAction(id: "ok", title: "知道了", isPrimary: true) {}]
    )

    let r1 = await center.showAndReport(recorded, style: .system)
    let r2 = await center.showAndReport(preview, style: .system)
    #expect(r1 == .unavailable)
    #expect(r2 == .unavailable)
    #expect(center.history.count == 1)
    #expect(center.unreadCount == 1)

    let item = try #require(center.history.first)
    #expect(item.title == "今天的禅道日志还没写")
    #expect(item.source == .zentao)
    #expect(item.style == .system)
    #expect(item.deliveryStatus == .unavailable)
    #expect(item.targetPluginID == "zentao.log")

    // 同一数据库重新加载也能完整恢复
    let reloaded = ReminderCenter(database: db)
    #expect(reloaded.history.count == 1)
    #expect(reloaded.unreadCount == 1)

    reloaded.markHandled(id: item.id, actionTitle: "去写日志")
    #expect(reloaded.unreadCount == 0)
    #expect(reloaded.history.first?.handledActionTitle == "去写日志")

    reloaded.setRead(id: item.id, isRead: false)
    #expect(reloaded.unreadCount == 1)

    reloaded.markAllRead()
    #expect(reloaded.unreadCount == 0)

    reloaded.deleteHistory(id: item.id)
    #expect(reloaded.history.isEmpty)

    let another = ReminderContent(
        id: "scheduler.task.1",
        title: "定时喝水",
        message: "站起来活动一下",
        actions: [ReminderAction(id: "ok", title: "知道了", isPrimary: true) {}]
    )
    _ = await reloaded.showAndReport(another, style: .system)
    #expect(reloaded.history.count == 1)
    reloaded.clearHistory()
    #expect(reloaded.history.isEmpty)
}
