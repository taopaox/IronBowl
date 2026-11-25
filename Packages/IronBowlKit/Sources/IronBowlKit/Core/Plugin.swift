import SwiftUI

/// 工作台插件协议。每个功能（日志、万年历、待办…）都是一个插件。
public protocol IronBowlPlugin: AnyObject {
    /// 稳定唯一 ID，用于设置里的启用开关和侧边栏选择。
    var id: String { get }
    var title: String { get }
    /// SF Symbol 名称。
    var systemImage: String { get }
    /// 只占位、尚未实现。
    var isComingSoon: Bool { get }
    /// 插件自己的数据库迁移。
    var migrations: [DatabaseMigration] { get }

    /// 工作台启动且插件已启用时调用一次。
    func start(context: PluginContext)
    func makeMainView() -> AnyView
    /// 插件在设置窗口左侧导航里的页面（按插件分组显示）。
    var settingsPages: [SettingsPage] { get }
    /// 插件能提供给菜单栏显示的信息项。
    var menuBarItems: [MenuBarItem] { get }
    /// 侧栏「最近」里的条目。
    var sidebarRecents: [SidebarRecent] { get }
    /// 首页的快捷标签。
    var quickActions: [QuickAction] { get }
    /// 首页的小卡片。
    var homeCards: [HomeCard] { get }
    /// 首页输入框的内容交给插件处理；处理了返回给用户看的结果，不处理返回 nil。
    func handleHomeInput(_ text: String) async -> String?
}

public extension IronBowlPlugin {
    var isComingSoon: Bool { false }
    var migrations: [DatabaseMigration] { [] }
    func start(context: PluginContext) {}
    var settingsPages: [SettingsPage] { [] }
    var menuBarItems: [MenuBarItem] { [] }
    var sidebarRecents: [SidebarRecent] { [] }
    var quickActions: [QuickAction] { [] }
    var homeCards: [HomeCard] { [] }
    func handleHomeInput(_ text: String) async -> String? { nil }
}

/// 设置窗口里的一页。
public struct SettingsPage: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let makeView: () -> AnyView

    public init(id: String, title: String, systemImage: String, makeView: @escaping () -> AnyView) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.makeView = makeView
    }
}

/// 侧栏「最近」里的一条。
public struct SidebarRecent: Identifiable {
    public let id: String
    public let title: String
    public let trailing: String
    public let action: () -> Void

    public init(id: String, title: String, trailing: String, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.trailing = trailing
        self.action = action
    }
}

/// 首页快捷标签。
public struct QuickAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let action: () -> Void

    public init(id: String, title: String, systemImage: String, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }
}

/// 首页小卡片。`value`、`detail` 在视图里求值，跟着 @Observable 状态刷新。
public struct HomeCard: Identifiable {
    public let id: String
    public let label: String
    public let value: () -> String
    public let detail: () -> String?
    public let action: (() -> Void)?

    public init(id: String, label: String, value: @escaping () -> String, detail: @escaping () -> String? = { nil }, action: (() -> Void)? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
        self.action = action
    }
}

/// 插件运行时能拿到的共享服务。
public final class PluginContext {
    public let database: AppDatabase
    public let settings: SettingsStore
    public let reminders: ReminderCenter
    public let workCalendar: WorkCalendar
    public let providers: AIProviderStore
    /// 打开主窗口并切到某个插件页。
    public let openPlugin: (String) -> Void
    /// 打开设置窗口，可指定页面 id。
    public let openSettings: (String?) -> Void

    public init(
        database: AppDatabase,
        settings: SettingsStore,
        reminders: ReminderCenter,
        workCalendar: WorkCalendar,
        providers: AIProviderStore,
        openPlugin: @escaping (String) -> Void,
        openSettings: @escaping (String?) -> Void
    ) {
        self.database = database
        self.settings = settings
        self.reminders = reminders
        self.workCalendar = workCalendar
        self.providers = providers
        self.openPlugin = openPlugin
        self.openSettings = openSettings
    }
}

/// 菜单栏可显示的一项信息。`text` 在 SwiftUI 视图里求值，读到的 @Observable 状态会自动触发刷新。
public struct MenuBarItem: Identifiable {
    public let id: String
    /// 设置里显示的名字。
    public let title: String
    public let text: () -> String?

    public init(id: String, title: String, text: @escaping () -> String?) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// 只占位的"即将推出"插件。
public final class ComingSoonPlugin: IronBowlPlugin {
    public let id: String
    public let title: String
    public let systemImage: String
    public var isComingSoon: Bool { true }

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }

    public func makeMainView() -> AnyView {
        AnyView(
            ContentUnavailableView(
                "\(title) 即将推出",
                systemImage: systemImage,
                description: Text("先把饭碗端稳，再慢慢加菜。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.canvas)
        )
    }
}
