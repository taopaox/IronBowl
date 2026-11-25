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
}
