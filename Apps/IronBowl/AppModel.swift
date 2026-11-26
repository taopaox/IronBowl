import AIWebPlugin
import AppKit
import CalendarPlugin
import FeishuPlugin
import IronBowlKit
import Observation
import ReportPlugin
import SchedulerPlugin
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
        case .never: "从不显示"
        }
    }
    var detail: String {
        switch self {
        case .always: "无论主窗口是否关闭，程序坞图标始终保留。"
        case .whenWindowOpen: "平时仅在菜单栏运行，打开主窗口时在程序坞显示。"
        case .never: "只保留菜单栏图标，不在程序坞显示。"
        }
    }
}

enum AppKeys {
    static let appearance = AppSharedKeys.appearance
    static let fontScale = AppSharedKeys.fontScale
    static let enabledPlugins = SettingKey<[String]?>("app.enabledPlugins", default: nil)
    static let knownPlugins = SettingKey<[String]>("app.knownPlugins", default: [])
    static let menuBarItems = SettingKey<[String]>("app.menuBarItems", default: ["zentao.status"])
    static let dockMode = SettingKey<DockMode>("app.dockMode", default: .whenWindowOpen)
    static let lastPlugin = SettingKey<String>("app.lastPlugin", default: AppModel.homeID)
}

/// 应用级状态：共享服务 + 插件列表。
@Observable
final class AppModel {
    static let homeID = "home"
    /// 给 AppDelegate 用（程序坞点击重新打开窗口）。
    nonisolated(unsafe) static weak var shared: AppModel?
    let database: AppDatabase
    let settings: SettingsStore
    let reminders = ReminderCenter()
    let workCalendar: WorkCalendar
    let providers: AIProviderStore
    let chat: ChatStore
    let webSessions: WebSessionManager
    let scheduler: TaskScheduler
    let systemMonitor: SystemMonitor
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
            CalendarPlugin(),
            FeishuPlugin(),
            AIWebPlugin(),
            SchedulerPlugin(),
            ReportPlugin(),
            MonthlyReportPlugin(),
            ComingSoonPlugin(id: "todo", title: "待办", systemImage: "checklist"),
        ]
        self.plugins = plugins
        defer { AppModel.shared = self }
        do {
            database = try AppDatabase(migrations: plugins.flatMap(\.migrations))
        } catch {
            fatalError("打开数据库失败：\(error)")
        }
        settings = SettingsStore(database: database)
        if let existingEnabled = settings[AppKeys.enabledPlugins] {
            let known = Set(settings[AppKeys.knownPlugins])
            var nextEnabled = Set(existingEnabled)
            var changed = false
            for p in plugins where !known.contains(p.id) {
                if !nextEnabled.contains(p.id) {
                    nextEnabled.insert(p.id)
                    changed = true
                }
            }
            if changed {
                settings[AppKeys.enabledPlugins] = plugins.map(\.id).filter { nextEnabled.contains($0) }
            }
        }
        let allIDs = plugins.map(\.id)
        if settings[AppKeys.knownPlugins] != allIDs {
            settings[AppKeys.knownPlugins] = allIDs
        }
        workCalendar = WorkCalendar(database: database, settings: settings)
        providers = AIProviderStore(settings: settings)
        chat = ChatStore(database: database, settings: settings, providers: providers)
        let webSessions = WebSessionManager(settings: settings)
        self.webSessions = webSessions
        let scheduler = TaskScheduler(
            database: database,
            settings: settings,
            workCalendar: workCalendar,
            reminders: reminders,
            openPlugin: { id in AppModel.shared?.open(plugin: id) },
            openSettings: { page in AppModel.shared?.openSettings(page: page) }
        )
        self.scheduler = scheduler
        systemMonitor = SystemMonitor { [weak webSessions] in
            webSessions?.activeWebProcessDescriptors() ?? []
        }
        selection = settings[AppKeys.lastPlugin]
        context = PluginContext(
            database: database, settings: settings, reminders: reminders,
            workCalendar: workCalendar, providers: providers, webSessions: webSessions,
            scheduler: scheduler,
            openPlugin: { [weak self] id in self?.open(plugin: id) },
            openSettings: { [weak self] page in self?.openSettings(page: page) }
        )
        syncPlugins()
        applyDockMode()
        applyAppearance()
        DS.fontScale = settings[AppKeys.fontScale]
        settings.onExternalChange = { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            DS.fontScale = self.settings[AppKeys.fontScale]
            self.calendarModel?.syncExternalChanges()
            self.scheduler.recomputeNextRuns()
        }
        workCalendar.onChange = { [weak self] in
            self?.scheduler.recomputeNextRuns()
        }
        workCalendar.onAttendanceIssue = { [weak self] issue in
            self?.showAttendanceIssue(issue)
        }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                Task { await self.workCalendar.syncAttendanceIfNeeded() }
            }
        }
        clock?.tolerance = 5
        Task {
            await providers.autodetectMissingPaths()
            await providers.loadAllModels()
            await workCalendar.updateIfNeeded()
            await workCalendar.syncAttendanceIfNeeded()
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
        syncPlugins()
        if !enabled, selection == id {
            select(Self.homeID)
        }
    }

    private func syncPlugins() {
        let enabled = enabledIDs
        for p in plugins {
            let isRunning = started.contains(p.id)
            if enabled.contains(p.id), !isRunning {
                p.start(context: context)
                started.insert(p.id)
            } else if !enabled.contains(p.id), isRunning {
                p.stop()
                started.remove(p.id)
            }
        }
    }

    func plugin(_ id: String?) -> IronBowlPlugin? { plugins.first { $0.id == id } }

    func select(_ id: String) {
        selection = id
        settings[AppKeys.lastPlugin] = id
    }

    func open(plugin id: String) {
        select(id)
        openMainWindow?()
        NSApp.activate()
    }

    // MARK: 设置窗口

    /// 钉钉考勤自动同步遇到没安装 / 没登录 / 没权限时，右上角提醒一次（同一天同类问题只提醒一次）。
    private func showAttendanceIssue(_ issue: DingTalkAttendanceError) {
        var actions = [
            ReminderAction(id: "off", title: "关闭同步") { [weak self] in
                self?.settings[WorkCalendar.dingtalkEnabledKey] = false
            },
            ReminderAction(id: "settings", title: "查看设置") { [weak self] in
                self?.openSettings(page: "worktime")
            },
        ]
        switch issue {
        case .missingExecutable, .notLoggedIn:
            actions.append(ReminderAction(id: "setup", title: issue == .notLoggedIn ? "去登录" : "去安装", isPrimary: true) {
                DingTalkAttendance.openSetupInTerminal()
            })
        default:
            break
        }
        let content = ReminderContent(
            id: "core.attendance.issue",
            title: "钉钉考勤同步不可用",
            message: "\(issue.localizedDescription)。今天先按固定的 \(settings[WorkCalendar.startKey])–\(settings[WorkCalendar.endKey]) 计算下班时间。",
            systemImage: "exclamationmark.triangle.fill",
            actions: actions
        )
        reminders.show(content, style: .cornerCard)
    }

    var settingsSelection = "general"
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    func openSettings(page: String? = nil) {
        if let page { settingsSelection = page }
        openSettingsWindow?()
        NSApp.activate()
    }

    // MARK: 菜单栏

    /// 万年历插件的状态（启用时才有）。
    var calendarModel: CalendarModel? {
        guard enabledIDs.contains(CalendarPlugin.pluginID) else { return nil }
        return (plugin(CalendarPlugin.pluginID) as? CalendarPlugin)?.model
    }

    /// 菜单栏单独的日历图标。
    var calendarMenuShown: Bool {
        get { calendarModel?.menuBarEnabled ?? false }
        set {
            guard let model = calendarModel, model.menuBarEnabled != newValue else { return }
            model.menuBarEnabled = newValue
        }
    }

    /// 所有可选的菜单栏信息项（核心 + 已启用插件）。
    var availableMenuBarItems: [MenuBarItem] {
        let core = MenuBarItem(id: "core.offwork", title: "离下班还有多久") { [weak self] in
            let now = Date()
            guard let self, workCalendar.isWorkday(now), let end = workCalendar.effectiveWorkEnd(on: now), end > now else { return nil }
            return "距下班 " + countdown(to: end, from: now)
        }
        return [core] + enabledPlugins.flatMap(\.menuBarItems)
    }

    var menuBarText: String {
        _ = now // 每 30 秒刷新一次倒计时
        let items = Dictionary(availableMenuBarItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return settings[AppKeys.menuBarItems].compactMap { items[$0]?.text() }.joined(separator: " ")
    }

    /// 供主状态栏与设置页预览渲染「双行微缩仪表卡」的分段数据。
    var menuBarCardSegments: [MenuBarCardSegment] {
        _ = now // 每 30 秒刷新一次倒计时
        let current = Date()
        let items = Dictionary(availableMenuBarItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var segments: [MenuBarCardSegment] = []

        for id in settings[AppKeys.menuBarItems] {
            if id == "core.offwork" {
                guard workCalendar.isWorkday(current),
                      let end = workCalendar.effectiveWorkEnd(on: current),
                      end > current else { continue }
                let ot = workCalendar.overtimeHours(on: current)
                let pct = Int(((workCalendar.workProgress(on: current) ?? 0) * 100).rounded())
                let top = ot > 0 ? "加班 · \(pct)%" : "距下班 · \(pct)%"
                segments.append(.stacked(
                    top: top,
                    bottom: countdown(to: end, from: current),
                    topTone: ot > 0 ? .purple : .amber
                ))
                continue
            }

            guard let text = items[id]?.text(), !text.isEmpty else { continue }
            if id == "zentao.nextReminder", text.hasPrefix("距提醒 ") {
                segments.append(.stacked(
                    top: "距提醒",
                    bottom: String(text.dropFirst("距提醒 ".count)),
                    topTone: .amber
                ))
            } else if id == "scheduler.next", text.hasPrefix("距任务 ") {
                segments.append(.stacked(
                    top: "距任务",
                    bottom: String(text.dropFirst("距任务 ".count)),
                    topTone: .indigo
                ))
            } else {
                segments.append(.inline(text: text, tone: inlineTone(for: id, text: text)))
            }
        }
        return segments
    }

    private func inlineTone(for id: String, text: String) -> MenuBarCardTone {
        switch id {
        case "zentao.status":
            text == "✓" ? .green : .rose
        case "zentao.hours":
            text.hasPrefix("已写") ? .green : .rose
        case "calendar.weather":
            .sky
        case "zentao.commits", "calendar.date", "calendar.lunar":
            .slate
        default:
            .white
        }
    }

    // MARK: 外观

    var appearance: AppearanceMode {
        get { settings[AppKeys.appearance] }
        set {
            settings[AppKeys.appearance] = newValue
            applyAppearance()
        }
    }

    /// 字体缩放档位。
    static let fontScales: [Double] = AppSharedKeys.fontScales

    /// 字体缩放。根视图用 `.id(app.fontScale)` 重建，所有界面一起变大变小。
    var fontScale: Double {
        get { settings[AppKeys.fontScale] }
        set {
            settings[AppKeys.fontScale] = newValue
            DS.fontScale = newValue
        }
    }

    /// 设置整个应用的外观：主窗口、设置、菜单栏面板、提醒卡片都会跟着变。
    func applyAppearance() {
        NSApp?.appearance = settings[AppKeys.appearance].nsAppearance
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
        if !isOpen {
            webSessions.detachAllDisplays()
        }
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
