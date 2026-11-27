import AppKit
import SwiftUI

/// 工作台插件协议。每个功能（日志、万年历、待办…）都是一个插件。
public protocol IronBowlPlugin: AnyObject {
    /// 稳定唯一 ID，用于设置里的启用开关和侧边栏选择。
    var id: String { get }
    var title: String { get }
    /// 左侧栏显示的标题（默认与 `title` 相同）。
    var sidebarTitle: String { get }
    /// 左侧栏所属分组标题（如「汇报」）；为 nil 或空白时显示在顶部主列表。
    var sidebarSection: String? { get }
    /// SF Symbol 名称。
    var systemImage: String { get }
    /// 只占位、尚未实现。
    var isComingSoon: Bool { get }
    /// 左侧边栏标题右侧的语义状态角标（如「今日未写」「本周未写」）。
    var sidebarBadge: SidebarBadge? { get }
    /// 是否以可折叠目录形式在左侧栏展示（子条目来自 `sidebarChildren`）。
    var isSidebarDirectory: Bool { get }
    /// 当前插件自身是否已打开内嵌网页（例如飞书主页）。
    var isSidebarWebOpen: Bool { get }
    /// 当前插件自身的内嵌网页是否处于休眠状态。
    var isSidebarWebSuspended: Bool { get }
    /// 插件自己的数据库迁移。
    var migrations: [DatabaseMigration] { get }

    /// 工作台启动且插件已启用时调用一次。
    func start(context: PluginContext)
    /// 插件被停用时调用，用于清理定时器和后台状态。
    func stop()
    func makeMainView() -> AnyView
    /// 插件在设置窗口左侧导航里的页面（按插件分组显示）。
    var settingsPages: [SettingsPage] { get }
    /// 插件能提供给菜单栏显示的信息项。
    var menuBarItems: [MenuBarItem] { get }
    /// 固定在主窗口左侧栏「固定网页」分区的条目。
    var sidebarPinnedItems: [SidebarPinnedItem] { get }
    /// 紧跟在目录插件下方缩进展示的子条目。
    var sidebarChildren: [SidebarPinnedItem] { get }
    /// 用户从主窗口左侧栏主动点击该插件时调用。
    func onSidebarSelect()
    /// 用户从左侧栏关闭该插件当前打开的内嵌网页时调用。
    func onSidebarCloseWeb()
    /// 按会话 ID 关闭归属本插件的内嵌网页；若不属于本插件返回 false。
    func closeWebSession(id: String) -> Bool
    /// 首页的快捷标签。
    var quickActions: [QuickAction] { get }
    /// 首页的小卡片。
    var homeCards: [HomeCard] { get }
    /// 首页输入框的内容交给插件处理；处理了返回给用户看的结果，不处理返回 nil。
    func handleHomeInput(_ text: String) async -> String?
    /// 供全局 ⌘K 命令面板展示的插件直达子命令。
    var paletteCommands: [PaletteCommand] { get }
    /// 判断首页「今天」AI 对话是否应交由本插件按工作台业务规则处理。
    func canHandleChatIntent(_ text: String) -> Bool
    /// 按工作台业务规则处理首页对话意图，并通过 `onProgress` 实时上报执行步骤。
    func handleChatIntent(
        _ text: String,
        onProgress: @escaping @MainActor (ChatActivityItem) -> Void
    ) async -> ChatPluginExecutionResult?
    /// 若插件识别该对话卡片附件，返回可在聊天流内直接交互操作（编辑/重生成/提交）的视图。
    func makeInteractiveChatCard(for attachment: ChatCardAttachment) -> AnyView?
}

public extension IronBowlPlugin {
    var sidebarTitle: String { title }
    var sidebarSection: String? { nil }
    var isComingSoon: Bool { false }
    var sidebarBadge: SidebarBadge? { nil }
    var isSidebarDirectory: Bool { false }
    var isSidebarWebOpen: Bool { false }
    var isSidebarWebSuspended: Bool { false }
    var migrations: [DatabaseMigration] { [] }
    func start(context: PluginContext) {}
    func stop() {}
    var settingsPages: [SettingsPage] { [] }
    var menuBarItems: [MenuBarItem] { [] }
    var sidebarPinnedItems: [SidebarPinnedItem] { [] }
    var sidebarChildren: [SidebarPinnedItem] { [] }
    func onSidebarSelect() {}
    func onSidebarCloseWeb() {}
    func closeWebSession(id: String) -> Bool { false }
    var quickActions: [QuickAction] { [] }
    var homeCards: [HomeCard] { [] }
    func handleHomeInput(_ text: String) async -> String? { nil }
    var paletteCommands: [PaletteCommand] { [] }
    func canHandleChatIntent(_ text: String) -> Bool { false }
    func handleChatIntent(
        _ text: String,
        onProgress: @escaping @MainActor (ChatActivityItem) -> Void
    ) async -> ChatPluginExecutionResult? { nil }
    func makeInteractiveChatCard(for attachment: ChatCardAttachment) -> AnyView? { nil }
}

/// 左侧栏插件条目右侧的状态角标。
public struct SidebarBadge: Equatable {
    public let text: String
    public let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }
}

/// 侧栏中按 `sidebarSection` 归组后的插件分区。
public struct SidebarPluginSection: Identifiable {
    public let title: String
    public let plugins: [IronBowlPlugin]
    public var id: String { title }

    public init(title: String, plugins: [IronBowlPlugin]) {
        self.title = title
        self.plugins = plugins
    }
}

/// 将已启用插件按 `sidebarSection` 拆分为顶部未分组列表与保序分组列表。
public enum SidebarPluginGrouping {
    public static func partition(_ plugins: [IronBowlPlugin]) -> (ungrouped: [IronBowlPlugin], sections: [SidebarPluginSection]) {
        var ungrouped: [IronBowlPlugin] = []
        var sectionOrder: [String] = []
        var grouped: [String: [IronBowlPlugin]] = [:]

        for plugin in plugins {
            let raw = plugin.sidebarSection?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let section = raw, !section.isEmpty else {
                ungrouped.append(plugin)
                continue
            }
            if grouped[section] == nil {
                sectionOrder.append(section)
                grouped[section] = []
            }
            grouped[section]?.append(plugin)
        }

        let sections = sectionOrder.compactMap { title -> SidebarPluginSection? in
            guard let items = grouped[title], !items.isEmpty else { return nil }
            return SidebarPluginSection(title: title, plugins: items)
        }
        return (ungrouped, sections)
    }
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

/// 固定在主窗口左侧栏的条目（例如固定网页、AI 目录子项）。
public struct SidebarPinnedItem: Identifiable {
    public let id: String
    public let pluginID: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let iconImage: NSImage?
    public let iconIsTemplate: Bool
    public let isSelected: Bool
    public let isOpen: Bool
    public let isSuspended: Bool
    public let isNeverSuspend: Bool
    public let canMoveUp: Bool
    public let canMoveDown: Bool
    public let action: () -> Void
    public let onClose: (() -> Void)?
    public let onRename: ((String) -> Void)?
    public let onEdit: (() -> Void)?
    public let onMoveUp: (() -> Void)?
    public let onMoveDown: (() -> Void)?
    public let onToggleNeverSuspend: (() -> Void)?
    public let onSuspendNow: (() -> Void)?
    public let onUnpin: (() -> Void)?
    public let onDelete: (() -> Void)?
    public let onOpenInBrowser: (() -> Void)?

    public init(
        id: String,
        pluginID: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        iconImage: NSImage? = nil,
        iconIsTemplate: Bool = false,
        isSelected: Bool,
        isOpen: Bool = false,
        isSuspended: Bool = false,
        isNeverSuspend: Bool = false,
        canMoveUp: Bool = false,
        canMoveDown: Bool = false,
        action: @escaping () -> Void,
        onClose: (() -> Void)? = nil,
        onRename: ((String) -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onMoveUp: (() -> Void)? = nil,
        onMoveDown: (() -> Void)? = nil,
        onToggleNeverSuspend: (() -> Void)? = nil,
        onSuspendNow: (() -> Void)? = nil,
        onUnpin: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onOpenInBrowser: (() -> Void)? = nil
    ) {
        self.id = id
        self.pluginID = pluginID
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconImage = iconImage
        self.iconIsTemplate = iconIsTemplate
        self.isSelected = isSelected
        self.isOpen = isOpen
        self.isSuspended = isSuspended
        self.isNeverSuspend = isNeverSuspend
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.action = action
        self.onClose = onClose
        self.onRename = onRename
        self.onEdit = onEdit
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onToggleNeverSuspend = onToggleNeverSuspend
        self.onSuspendNow = onSuspendNow
        self.onUnpin = onUnpin
        self.onDelete = onDelete
        self.onOpenInBrowser = onOpenInBrowser
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

/// 全局 ⌘K 命令面板中的插件动作项。
public struct PaletteCommand: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let keywords: [String]
    public let systemImage: String
    public let badge: String?
    public let searchHaystack: String
    public let action: () -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        systemImage: String,
        badge: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.systemImage = systemImage
        self.badge = badge
        self.searchHaystack = ([title, subtitle ?? "", badge ?? ""] + keywords)
            .joined(separator: " ")
            .lowercased()
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
    public let webSessions: WebSessionManager
    public let scheduler: TaskScheduler
    public let todos: TodoStore
    public let scratchpad: ScratchpadStore
    public let clipboard: ClipboardHistoryStore
    /// 打开主窗口并切到某个插件页。
    public let openPlugin: (String) -> Void
    /// 打开设置窗口，可指定页面 id。
    public let openSettings: (String?) -> Void
    /// 切换到首页「今天」并绑定指定工作目录发起对话。
    public let openChatInWorkspace: (String) -> Void
    /// 从万年历等解耦插件向禅道日报写入外部草稿（独立版万年历中为 nil）。
    public let appendDailyLogDraft: ((_ work: String, _ hours: Double, _ date: Date) -> Bool)?

    public init(
        database: AppDatabase,
        settings: SettingsStore,
        reminders: ReminderCenter,
        workCalendar: WorkCalendar,
        providers: AIProviderStore,
        webSessions: WebSessionManager? = nil,
        scheduler: TaskScheduler? = nil,
        todos: TodoStore? = nil,
        scratchpad: ScratchpadStore? = nil,
        clipboard: ClipboardHistoryStore? = nil,
        openPlugin: @escaping (String) -> Void,
        openSettings: @escaping (String?) -> Void,
        openChatInWorkspace: @escaping (String) -> Void = { _ in },
        appendDailyLogDraft: ((_ work: String, _ hours: Double, _ date: Date) -> Bool)? = nil
    ) {
        self.database = database
        self.settings = settings
        self.reminders = reminders
        self.workCalendar = workCalendar
        self.providers = providers
        self.webSessions = webSessions ?? WebSessionManager(settings: settings)
        self.scheduler = scheduler ?? TaskScheduler(
            database: database,
            settings: settings,
            workCalendar: workCalendar,
            reminders: reminders,
            openPlugin: openPlugin,
            openSettings: openSettings
        )
        self.todos = todos ?? TodoStore(database: database)
        self.scratchpad = scratchpad ?? ScratchpadStore(database: database)
        self.clipboard = clipboard ?? ClipboardHistoryStore(database: database, settings: settings)
        self.openPlugin = openPlugin
        self.openSettings = openSettings
        self.openChatInWorkspace = openChatInWorkspace
        self.appendDailyLogDraft = appendDailyLogDraft
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
                description: Text(AppBrand.slogan)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.canvas)
            .overlay(alignment: .top) { WindowTitleBarArea(height: 52) }
        )
    }
}
