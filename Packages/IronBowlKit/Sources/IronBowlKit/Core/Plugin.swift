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
    /// 插件的设置页（显示在设置窗口里），没有就返回 nil。
    func makeSettingsView() -> AnyView?
    /// 插件能提供给菜单栏显示的信息项。
    var menuBarItems: [MenuBarItem] { get }
}

public extension IronBowlPlugin {
    var isComingSoon: Bool { false }
    var migrations: [DatabaseMigration] { [] }
    func start(context: PluginContext) {}
    func makeSettingsView() -> AnyView? { nil }
    var menuBarItems: [MenuBarItem] { [] }
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

    public init(
        database: AppDatabase,
        settings: SettingsStore,
        reminders: ReminderCenter,
        workCalendar: WorkCalendar,
        providers: AIProviderStore,
        openPlugin: @escaping (String) -> Void
    ) {
        self.database = database
        self.settings = settings
        self.reminders = reminders
        self.workCalendar = workCalendar
        self.providers = providers
        self.openPlugin = openPlugin
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
        )
    }
}
