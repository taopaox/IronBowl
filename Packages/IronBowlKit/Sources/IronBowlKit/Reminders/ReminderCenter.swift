import AppKit
import SwiftUI
@preconcurrency import UserNotifications

public nonisolated enum ReminderStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case cornerCard
    case centerDialog

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: "系统通知"
        case .cornerCard: "右上角浮动卡片（不操作不消失）"
        case .centerDialog: "屏幕中央弹框"
        }
    }
}

public struct ReminderAction: Identifiable {
    public let id: String
    public let title: String
    public let isPrimary: Bool
    public let handler: () -> Void

    public init(id: String, title: String, isPrimary: Bool = false, handler: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.isPrimary = isPrimary
        self.handler = handler
    }
}

public struct ReminderContent {
    /// 同一个 id 再次弹出会替换旧的。
    public let id: String
    public let title: String
    public let message: String
    public let systemImage: String
    public let actions: [ReminderAction]

    public init(id: String, title: String, message: String, systemImage: String = "bell.fill", actions: [ReminderAction]) {
        self.id = id
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions
    }
}

/// macOS 系统通知权限与弹窗样式状态。
public nonisolated enum SystemNotificationStatus: Equatable, Sendable {
    case unavailable
    case notDetermined
    case denied
    case alertsDisabled
    case authorized

    public var canPresentAlert: Bool { self == .authorized }

    /// 根据系统通知授权状态与横幅/提醒设置归纳当前可见状态。
    public static func evaluate(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting,
        alertStyle: UNAlertStyle
    ) -> SystemNotificationStatus {
        switch authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional:
            return (alertSetting == .disabled || alertStyle == .none) ? .alertsDisabled : .authorized
        @unknown default:
            return .denied
        }
    }
}

/// 提醒投递结果。
public nonisolated enum ReminderDeliveryResult: Equatable, Sendable {
    case delivered
    case unavailable
    case permissionDenied
    case alertsDisabled
    case failed(String)
}

/// 弹出提醒：系统通知，或工作台自己画的浮动面板（右上角 / 屏幕中央，点按钮才消失，勿扰模式下也会出现）。
public final class ReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    private var panels: [String: NSPanel] = [:]
    private var systemContents: [String: ReminderContent] = [:]
    private var categories: Set<UNNotificationCategory> = []

    private var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    override public init() {
        super.init()
        notificationCenter?.delegate = self
    }

    /// 读取当前系统通知权限与提醒样式状态。
    public func systemNotificationStatus() async -> SystemNotificationStatus {
        guard let center = notificationCenter else { return .unavailable }
        let settings = await center.notificationSettings()
        return SystemNotificationStatus.evaluate(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting,
            alertStyle: settings.alertStyle
        )
    }

    /// 主动向系统申请通知权限并返回最新状态。
    public func requestSystemNotificationAuthorization() async -> SystemNotificationStatus {
        guard let center = notificationCenter else { return .unavailable }
        if await systemNotificationStatus() == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        return await systemNotificationStatus()
    }

    /// 生成打开「系统设置 → 通知」的候选 URL 列表（优先直达当前应用）。
    public nonisolated static func systemNotificationSettingsURLs(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> [URL] {
        var urls: [URL] = []
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            var components = URLComponents()
            components.scheme = "x-apple.systempreferences"
            components.path = "com.apple.Notifications-Settings.extension"
            components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
            if let url = components.url {
                urls.append(url)
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            urls.append(url)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            urls.append(url)
        }
        return urls
    }

    /// 快捷打开 macOS「系统设置 → 通知 → 饭碗」。
    @discardableResult
    public static func openSystemNotificationSettings() -> Bool {
        for url in systemNotificationSettingsURLs() {
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    public func show(_ content: ReminderContent, style: ReminderStyle) {
        switch style {
        case .system:
            Task { _ = await showAndReport(content, style: .system) }
        case .cornerCard:
            dismiss(id: content.id)
            showPanel(content, centered: false)
        case .centerDialog:
            dismiss(id: content.id)
            showPanel(content, centered: true)
        }
    }

    /// 发送提醒并返回投递结果（供设置页预览等需要即时反馈的场景使用）。
    public func showAndReport(_ content: ReminderContent, style: ReminderStyle) async -> ReminderDeliveryResult {
        dismiss(id: content.id)
        switch style {
        case .system:
            return await showSystem(content)
        case .cornerCard:
            showPanel(content, centered: false)
            return .delivered
        case .centerDialog:
            showPanel(content, centered: true)
            return .delivered
        }
    }

    public func dismiss(id: String) {
        panels.removeValue(forKey: id)?.orderOut(nil)
        if systemContents.removeValue(forKey: id) != nil {
            notificationCenter?.removePendingNotificationRequests(withIdentifiers: [id])
            notificationCenter?.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    // MARK: 玻璃面板

    private func showPanel(_ content: ReminderContent, centered: Bool) {
        let view = ReminderPanelView(content: content, centered: centered) { [weak self] action in
            self?.dismiss(id: content.id)
            action.handler()
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSApp?.appearance
        panel.contentView = hosting

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            let origin = centered
                ? NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
                : NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12)
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
        }
        panels[content.id] = panel
    }

    // MARK: 系统通知

    private func showSystem(_ content: ReminderContent) async -> ReminderDeliveryResult {
        guard let center = notificationCenter else { return .unavailable }
        var status = await systemNotificationStatus()
        if status == .notDetermined {
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return .failed(error.localizedDescription)
            }
            status = await systemNotificationStatus()
            if !granted && status != .authorized {
                return status == .alertsDisabled ? .alertsDisabled : .permissionDenied
            }
        }
        switch status {
        case .unavailable:
            return .unavailable
        case .notDetermined, .denied:
            return .permissionDenied
        case .alertsDisabled:
            return .alertsDisabled
        case .authorized:
            systemContents[content.id] = content
            let category = UNNotificationCategory(
                identifier: content.id,
                actions: content.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: $0.isPrimary ? [.foreground] : []) },
                intentIdentifiers: []
            )
            categories = categories.filter { $0.identifier != content.id }
            categories.insert(category)
            center.setNotificationCategories(categories)

            let n = UNMutableNotificationContent()
            n.title = content.title
            n.body = content.message
            n.sound = .default
            n.categoryIdentifier = content.id
            let request = UNNotificationRequest(identifier: content.id, content: n, trigger: nil)
            do {
                try await center.add(request)
                return .delivered
            } catch {
                systemContents.removeValue(forKey: content.id)
                return .failed(error.localizedDescription)
            }
        }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let actionID = response.actionIdentifier
        await MainActor.run {
            guard let content = self.systemContents.removeValue(forKey: id) else { return }
            // 点通知本身 = 主按钮。
            let action = content.actions.first { $0.id == actionID }
                ?? (actionID == UNNotificationDefaultActionIdentifier ? content.actions.first { $0.isPrimary } : nil)
            action?.handler()
        }
    }
}

struct ReminderPanelView: View {
    let content: ReminderContent
    let centered: Bool
    let onAction: (ReminderAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: content.systemImage)
                    .font(DS.font(16))
                    .foregroundStyle(DS.text)
                    .frame(width: 32, height: 32)
                    .background(DS.well, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title).font(DS.font(15, .semibold))
                    Text(content.message).font(DS.body).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                ForEach(content.actions) { action in
                    if action.isPrimary {
                        Button(action.title) { onAction(action) }.buttonStyle(.dsPrimary)
                    } else {
                        Button(action.title) { onAction(action) }.buttonStyle(.dsSecondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: centered ? 420 : 350)
        .background(DS.card, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(DS.border) }
        .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        .padding(24) // 给阴影留空间
    }
}
