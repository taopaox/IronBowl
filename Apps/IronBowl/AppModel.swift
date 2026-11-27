import AIWebPlugin
import AppKit
import CalendarPlugin
import DevToolsPlugin
import FeishuPlugin
import IronBowlKit
import Observation
import ReportPlugin
import SchedulerPlugin
import SwiftUI
import TodoPlugin
import WorkspacePlugin
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

/// 菜单栏独立 Logo 左键点击行为。
enum MenuBarLogoAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case toggleHome
    case openHome
    case openMainWindow
    case unreadOrHome
    case openReminders
    case commandPalette
    case openMenuPanel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggleHome: "打开 / 收起首页"
        case .openHome: "仅打开首页"
        case .openMainWindow: "打开 / 收起主窗口"
        case .unreadOrHome: "有未读看提醒，无未读进首页"
        case .openReminders: "打开消息提醒"
        case .commandPalette: "打开命令面板与搜索"
        case .openMenuPanel: "弹出快捷面板"
        }
    }

    var detail: String {
        switch self {
        case .toggleHome: "左键秒开首页「今天」，已在前台首页时再点一次收起；右键弹出快捷面板。"
        case .openHome: "左键直接打开并前置首页「今天」，再次点击不会收起窗口；右键弹出快捷面板。"
        case .openMainWindow: "左键打开主窗口并保留上次页面，已在前台时再点一次收起；右键弹出快捷面板。"
        case .unreadOrHome: "有未读消息时直接跳转「消息提醒」，无未读时打开或收起首页；右键弹出快捷面板。"
        case .openReminders: "左键直接打开「消息提醒」中心；右键弹出快捷面板。"
        case .commandPalette: "左键呼出全局命令面板与全文搜索（同 ⌃⌥⌘K）；右键弹出快捷面板。"
        case .openMenuPanel: "左键弹出原状态栏快捷面板；右键直接打开 / 收起首页。"
        }
    }
}

enum AppKeys {
    static let appearance = AppSharedKeys.appearance
    static let fontScale = AppSharedKeys.fontScale
    static let enabledPlugins = SettingKey<[String]?>("app.enabledPlugins", default: nil)
    static let knownPlugins = SettingKey<[String]>("app.knownPlugins", default: [])
    static let menuBarItems = SettingKey<[String]>("app.menuBarItems", default: ["zentao.status"])
    static let menuBarLogoClickAction = SettingKey<MenuBarLogoAction>("app.menuBar.logoClickAction", default: .toggleHome)
    static let menuBarLogoShowUnreadBadge = SettingKey<Bool>("app.menuBar.logoShowUnreadBadge", default: true)
    static let dockMode = SettingKey<DockMode>("app.dockMode", default: .whenWindowOpen)
    static let lastPlugin = SettingKey<String>("app.lastPlugin", default: AppModel.homeID)
    static let commandPaletteShortcut = SettingKey<Bool>("app.commandPalette.globalShortcut", default: true)
}

/// 应用级状态：共享服务 + 插件列表。
@Observable
final class AppModel {
    static let homeID = "home"
    static let remindersID = "reminders"
    /// 给 AppDelegate 用（程序坞点击重新打开窗口）。
    nonisolated(unsafe) static weak var shared: AppModel?
    let database: AppDatabase
    let settings: SettingsStore
    let userProfile: UserProfileStore
    let reminders: ReminderCenter
    let workCalendar: WorkCalendar
    let providers: AIProviderStore
    let chat: ChatStore
    let webSessions: WebSessionManager
    let scheduler: TaskScheduler
    let systemMonitor: SystemMonitor
    let updater = AppUpdater()
    let launchAtLogin = LaunchAtLoginController()
    let plugins: [IronBowlPlugin]
    var context: PluginContext!
    var commandPalette: CommandPaletteController!

    var selection: String?
    var isMainWindowOpen = false
    /// 数据恢复后递增，触发原生页面保活容器销毁重建缓存页。
    var pageDeckResetToken = 0
    /// 主窗口关闭后闲置收缩后台页面缓存的触发令牌。
    var pageDeckTrimToken = 0
    /// 菜单栏倒计时用的时钟，每 30 秒更新。
    var now = Date()
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var backgroundTrimTask: Task<Void, Never>?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var hideMainWindow: (() -> Void)?
    @ObservationIgnored var isMainWindowFrontmost: (() -> Bool)?
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
            WorkLedgerPlugin(),
            AnnualReviewPlugin(),
            TodoPlugin(),
            ScratchpadPlugin(),
            WorkspacePlugin(),
            DevToolsPlugin(),
        ]
        self.plugins = plugins
        defer { AppModel.shared = self }
        do {
            database = try AppDatabase(migrations: plugins.flatMap(\.migrations))
        } catch {
            fatalError("打开数据库失败：\(error)")
        }
        reminders = ReminderCenter(database: database)
        settings = SettingsStore(database: database)
        userProfile = UserProfileStore(settings: settings)
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
        if selection == FeishuPlugin.pluginID || selection == AIWebPlugin.pluginID {
            webSessions.armColdLaunchDeferral()
        }
        context = PluginContext(
            database: database, settings: settings, reminders: reminders,
            workCalendar: workCalendar, providers: providers, webSessions: webSessions,
            scheduler: scheduler,
            openPlugin: { [weak self] id in self?.open(plugin: id) },
            openSettings: { [weak self] page in self?.openSettings(page: page) },
            openChatInWorkspace: { [weak self] path in self?.openChat(inWorkspace: path) },
            appendDailyLogDraft: { [database, settings] work, hours, date in
                ZentaoLogPlugin.appendExternalDraft(work: work, hours: hours, on: date, database: database, settings: settings)
            }
        )
        context.clipboard.startMonitoring()
        syncPlugins()
        commandPalette = CommandPaletteController(app: self)
        commandPalette.syncShortcut()
        chat.onTurnCompleted = { [weak self] in
            guard let self else { return }
            self.workCalendar.reload()
            self.context.todos.reload()
            self.context.scratchpad.reload()
            self.context.clipboard.reload()
            NotificationCenter.default.post(
                name: ZentaoLogPlugin.externalDraftAddedNotification,
                object: WorkCalendar.dayString(Date())
            )
        }
        applyDockMode()
        applyAppearance()
        DS.fontScale = settings[AppKeys.fontScale]
        settings.onExternalChange = { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            DS.fontScale = self.settings[AppKeys.fontScale]
            self.userProfile.reloadAvatar()
            self.calendarModel?.syncExternalChanges()
            self.scheduler.recomputeNextRuns()
        }
        workCalendar.onChange = { [weak self] in
            self?.scheduler.recomputeNextRuns()
        }
        workCalendar.onAttendanceIssue = { [weak self] issue in
            self?.showAttendanceIssue(issue)
        }
        workCalendar.onClockOutSynced = { [weak self] day, _ in
            if Calendar.current.isDateInToday(day) {
                self?.scheduler.dismissActiveClockOutReminders()
            }
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
            _ = try? WorkbenchBridgeCLI.ensureInstalled()
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

    var enabledPlugins: [IronBowlPlugin] {
        let ids = enabledIDs
        return plugins.filter { ids.contains($0.id) }
    }

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
        webSessions.cancelColdLaunchDeferral()
        guard selection != id else { return }
        selection = id
        settings.setDeferred(id, for: AppKeys.lastPlugin)
    }

    func open(plugin id: String) {
        select(id)
        showMainWindow()
    }

    func showMainWindow() {
        openMainWindow?()
    }

    func toggleMainWindow(targetPluginID: String? = nil) {
        let isFrontmost = isMainWindowFrontmost?() ?? false
        if isFrontmost {
            if let targetPluginID, selection != targetPluginID {
                select(targetPluginID)
                showMainWindow()
            } else {
                hideMainWindow?()
            }
        } else {
            if let targetPluginID {
                select(targetPluginID)
            }
            showMainWindow()
        }
    }

    var menuBarLogoClickAction: MenuBarLogoAction {
        get { settings[AppKeys.menuBarLogoClickAction] }
        set { settings[AppKeys.menuBarLogoClickAction] = newValue }
    }

    var menuBarLogoShowUnreadBadge: Bool {
        get { settings[AppKeys.menuBarLogoShowUnreadBadge] }
        set { settings[AppKeys.menuBarLogoShowUnreadBadge] = newValue }
    }

    func performMenuBarLogoAction(_ action: MenuBarLogoAction, togglePopover: () -> Void) {
        switch action {
        case .toggleHome:
            toggleMainWindow(targetPluginID: Self.homeID)
        case .openHome:
            open(plugin: Self.homeID)
        case .openMainWindow:
            toggleMainWindow(targetPluginID: nil)
        case .unreadOrHome:
            if reminders.unreadCount > 0 {
                open(plugin: Self.remindersID)
            } else {
                toggleMainWindow(targetPluginID: Self.homeID)
            }
        case .openReminders:
            if (isMainWindowFrontmost?() ?? false) && selection == Self.remindersID {
                hideMainWindow?()
            } else {
                open(plugin: Self.remindersID)
            }
        case .commandPalette:
            commandPalette.toggle()
        case .openMenuPanel:
            togglePopover()
        }
    }

    func openChat(inWorkspace path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.defaultWorkspacePath = trimmed
        if let thread = chat.selectedThread, (chat.messagesByThread[thread.id] ?? []).isEmpty {
            chat.updateThread(thread.id, workspacePath: trimmed)
        } else {
            let folderName = URL(fileURLWithPath: trimmed).lastPathComponent
            let title = folderName.isEmpty ? "工作区对话" : "\(folderName) 对话"
            _ = chat.createThread(title: title, workspacePath: trimmed)
        }
        open(plugin: Self.homeID)
    }

    func closeWebSession(id: String) {
        for plugin in enabledPlugins where plugin.closeWebSession(id: id) {
            return
        }
        webSessions.remove(id: id)
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
            source: .attendance,
            targetSettingsPage: "worktime",
            actions: actions
        )
        reminders.show(content, style: .cornerCard)
    }

    var settingsSelection = "general"
    @ObservationIgnored var openSettingsWindow: (() -> Void)?

    func openSettings(page: String? = nil) {
        if let page { settingsSelection = page }
        openSettingsWindow?()
    }

    // MARK: 菜单栏

    /// 万年历插件的状态（启用时才有）。
    var calendarModel: CalendarModel? {
        guard enabledIDs.contains(CalendarPlugin.pluginID) else { return nil }
        return (plugin(CalendarPlugin.pluginID) as? CalendarPlugin)?.model
    }

    /// 菜单栏单独的日历图标（独立版万年历运行时自动避让隐藏，且不覆盖用户持久化开关）。
    var calendarMenuShown: Bool {
        calendarModel?.shouldShowEmbeddedMenuBar ?? false
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
        case "zentao.bugs":
            .rose
        case "calendar.nextMeeting":
            .amber
        case "calendar.weather", "devtools.ports":
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
        let targetPolicy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        if NSApp?.activationPolicy() != targetPolicy {
            NSApp?.setActivationPolicy(targetPolicy)
        }
    }

    func mainWindow(isOpen: Bool) {
        let changed = (isMainWindowOpen != isOpen)
        isMainWindowOpen = isOpen
        backgroundTrimTask?.cancel()
        backgroundTrimTask = nil
        if changed {
            webSessions.setHostWindowOpen(isOpen)
        }
        if !isOpen {
            backgroundTrimTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard let self, !Task.isCancelled, !self.isMainWindowOpen else { return }
                self.pageDeckTrimToken &+= 1
            }
        }
        applyDockMode()
    }

    // MARK: 数据恢复后全量重载

    func reloadAllStoresAfterRestore() {
        settings.reload()
        webSessions.setHostWindowOpen(isMainWindowOpen)
        applyAppearance()
        DS.fontScale = settings[AppKeys.fontScale]
        userProfile.reloadAvatar()
        workCalendar.reload()
        context.todos.reload()
        context.scratchpad.reload()
        context.clipboard.reload()
        reminders.reloadHistory()
        scheduler.recomputeNextRuns()
        chat.loadThreads()
        calendarModel?.syncExternalChanges()
        applyDockMode()
        for p in plugins where started.contains(p.id) {
            p.stop()
            started.remove(p.id)
        }
        syncPlugins()
        pageDeckResetToken &+= 1
    }
}
