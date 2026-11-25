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
        case .cornerCard: "右上角玻璃卡片（不操作不消失）"
        case .centerDialog: "屏幕中央玻璃弹框"
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

/// 弹出提醒：系统通知，或工作台自己画的玻璃面板（右上角 / 屏幕中央，点按钮才消失，勿扰模式下也会出现）。
public final class ReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    private var panels: [String: NSPanel] = [:]
    private var systemContents: [String: ReminderContent] = [:]
    private var categories: Set<UNNotificationCategory> = []

    override public init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func show(_ content: ReminderContent, style: ReminderStyle) {
        dismiss(id: content.id)
        switch style {
        case .system: showSystem(content)
        case .cornerCard: showPanel(content, centered: false)
        case .centerDialog: showPanel(content, centered: true)
        }
    }

    public func dismiss(id: String) {
        panels.removeValue(forKey: id)?.orderOut(nil)
        if systemContents.removeValue(forKey: id) != nil {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
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

    private func showSystem(_ content: ReminderContent) {
        let center = UNUserNotificationCenter.current()
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
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
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
