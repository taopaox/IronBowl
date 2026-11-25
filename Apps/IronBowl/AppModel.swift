import AppKit
import IronBowlKit
import Observation
import ServiceManagement
import SwiftUI
import ZentaoLogPlugin

enum DockMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case always, whenWindowOpen, never
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .always: "一直显示"
        case .whenWindowOpen: "只在主窗口打开时显示"
        case .never: "从不显示（只留菜单栏图标）"
        }
    }
}

enum AppKeys {
    static let enabledPlugins = SettingKey<[String]?>("app.enabledPlugins", default: nil)
    static let menuBarItems = SettingKey<[String]>("app.menuBarItems", default: ["zentao.status"])
    static let dockMode = SettingKey<DockMode>("app.dockMode", default: .whenWindowOpen)
    static let lastPlugin = SettingKey<String>("app.lastPlugin", default: ZentaoLogPlugin.pluginID)
}

/// 应用级状态：共享服务 + 插件列表。
@Observable
final class AppModel {
    let database: AppDatabase
    let settings: SettingsStore
    let reminders = ReminderCenter()
    let workCalendar: WorkCalendar
    let providers: AIProviderStore
    let plugins: [IronBowlPlugin]
    var context: PluginContext!

    var selection: String?
    var isMainWindowOpen = false
    /// 菜单栏倒计时用的时钟，每 30 秒更新。
    var now = Date()
    @ObservationIgnored private var clock: Timer?
    var launchError: String?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var started = Set<String>()

    init() {
        let plugins: [IronBowlPlugin] = [
            ZentaoLogPlugin(),
            ComingSoonPlugin(id: "calendar", title: "万年历", systemImage: "calendar"),
            ComingSoonPlugin(id: "feishu", title: "飞书知识库", systemImage: "book.pages"),
            ComingSoonPlugin(id: "todo", title: "待办", systemImage: "checklist"),
            ComingSoonPlugin(id: "report", title: "周报日报", systemImage: "doc.text"),
        ]
        self.plugins = plugins
        do {
            database = try AppDatabase(migrations: plugins.flatMap(\.migrations))
        } catch {
            fatalError("打开数据库失败：\(error)")
        }
        settings = SettingsStore(database: database)
        workCalendar = WorkCalendar(database: database, settings: settings)
        providers = AIProviderStore(settings: settings)
        selection = settings[AppKeys.lastPlugin]
        context = PluginContext(
            database: database, settings: settings, reminders: reminders,
            workCalendar: workCalendar, providers: providers,
            openPlugin: { [weak self] id in self?.open(plugin: id) }
        )
        startEnabledPlugins()
        applyDockMode()
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        clock?.tolerance = 5
        Task {
            await providers.autodetectMissingPaths()
            await workCalendar.updateIfNeeded()
        }
    }

    // MARK: 插件

    var enabledIDs: Set<String> {
        Set(settings[AppKeys.enabledPlugins] ?? plugins.map(\.id))
    }

    var enabledPlugins: [IronBowlPlugin] { plugins.filter { enabledIDs.contains($0.id) } }

    func setEnabled(_ id: String, _ enabled: Bool) {
        var ids = enabledIDs
        if enabled { ids.insert(id) } else { ids.remove(id) }
        settings[AppKeys.enabledPlugins] = plugins.map(\.id).filter { ids.contains($0) }
        startEnabledPlugins()
    }

    private func startEnabledPlugins() {
        for p in enabledPlugins where !started.contains(p.id) {
            p.start(context: context)
            started.insert(p.id)
        }
    }

    func plugin(_ id: String?) -> IronBowlPlugin? { plugins.first { $0.id == id } }

    func open(plugin id: String) {
        selection = id
        settings[AppKeys.lastPlugin] = id
        openMainWindow?()
        NSApp.activate()
    }

    // MARK: 菜单栏

    /// 所有可选的菜单栏信息项（核心 + 已启用插件）。
    var availableMenuBarItems: [MenuBarItem] {
        let core = MenuBarItem(id: "core.offwork", title: "离下班还有多久") { [weak self] in
            guard let self, workCalendar.isWorkday(Date()), let end = workCalendar.workEnd(), end > Date() else { return nil }
            return "下班 " + countdown(to: end)
        }
        return [core] + enabledPlugins.flatMap(\.menuBarItems)
    }

    var menuBarText: String {
        _ = now // 每 30 秒刷新一次倒计时
        let items = Dictionary(availableMenuBarItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return settings[AppKeys.menuBarItems].compactMap { items[$0]?.text() }.joined(separator: " ")
    }

    // MARK: 程序坞

    func applyDockMode() {
        let regular: Bool
        switch settings[AppKeys.dockMode] {
        case .always: regular = true
        case .never: regular = false
        case .whenWindowOpen: regular = isMainWindowOpen
        }
        NSApp?.setActivationPolicy(regular ? .regular : .accessory)
    }

    func mainWindow(isOpen: Bool) {
        isMainWindowOpen = isOpen
        applyDockMode()
        if isOpen { NSApp.activate() }
    }

    // MARK: 开机自启

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchError = nil
            } catch {
                launchError = "设置开机自启失败：\(error.localizedDescription)"
            }
        }
    }
}
