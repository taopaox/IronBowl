import AppKit
import Darwin
import Foundation
import IronBowlKit
import Observation
import SwiftUI

/// 主工作台与独立版万年历同时运行时的状态栏日历自动避让策略。
public nonisolated enum CalendarMenuBarPolicy {
    public static let standaloneBundleID = "com.taopaox.ironbowl.calendar"
    public static let standaloneLifecycleNotification = Notification.Name("com.taopaox.ironbowl.standaloneCalendar.lifecycle")
    public static let standaloneProbeNotification = Notification.Name("com.taopaox.ironbowl.standaloneCalendar.probe")

    public enum StandaloneLifecycleEvent: String, Sendable, Equatable {
        case alive
        case willTerminate
    }

    public static func shouldShowEmbeddedMenuBar(settingEnabled: Bool, isStandaloneRunning: Bool) -> Bool {
        settingEnabled && !isStandaloneRunning
    }

    public static func encodeLifecyclePayload(_ event: StandaloneLifecycleEvent, pid: pid_t) -> String {
        "\(event.rawValue)|\(pid)"
    }

    public static func decodeLifecyclePayload(_ payload: String?) -> (event: StandaloneLifecycleEvent, pid: pid_t)? {
        guard let payload else { return nil }
        let parts = payload.split(separator: "|", maxSplits: 1)
        guard parts.count == 2,
              let event = StandaloneLifecycleEvent(rawValue: String(parts[0])),
              let pid = pid_t(parts[1]),
              pid > 0 else { return nil }
        return (event, pid)
    }

    public static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    public static func postStandaloneLifecycle(
        _ event: StandaloneLifecycleEvent,
        pid: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        DistributedNotificationCenter.default().postNotificationName(
            standaloneLifecycleNotification,
            object: encodeLifecyclePayload(event, pid: pid),
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public static func postStandaloneProbe() {
        DistributedNotificationCenter.default().postNotificationName(
            standaloneProbeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @MainActor
    public static func runningStandalonePIDs(
        bundleID: String = standaloneBundleID,
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        excludingPID: pid_t? = nil
    ) -> Set<pid_t> {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return Set(apps.compactMap { app in
            guard !app.isTerminated,
                  app.processIdentifier != currentPID,
                  app.processIdentifier != excludingPID else { return nil }
            return app.processIdentifier
        })
    }

    @MainActor
    public static func isStandaloneRunning(
        bundleID: String = standaloneBundleID,
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        excludingPID: pid_t? = nil
    ) -> Bool {
        !runningStandalonePIDs(
            bundleID: bundleID,
            currentPID: currentPID,
            excludingPID: excludingPID
        ).isEmpty
    }
}

/// 独立版万年历跨进程存活状态聚合器：融合 `NSRunningApplication` 快照、分布式生命周期广播与 PID 存活探针。
public nonisolated struct StandaloneCalendarPresenceState: Sendable, Equatable {
    public private(set) var announcedAlivePIDs: Set<pid_t> = []
    public private(set) var terminatingPIDs: Set<pid_t> = []

    public init() {}

    public mutating func handleLifecycleEvent(
        _ event: CalendarMenuBarPolicy.StandaloneLifecycleEvent,
        pid: pid_t,
        currentPID: pid_t
    ) {
        guard pid > 0, pid != currentPID else { return }
        switch event {
        case .alive:
            terminatingPIDs.remove(pid)
            announcedAlivePIDs.insert(pid)
        case .willTerminate:
            announcedAlivePIDs.remove(pid)
            terminatingPIDs.insert(pid)
        }
    }

    public mutating func reconcile(
        runningPIDs: Set<pid_t>,
        isProcessAlive: (pid_t) -> Bool
    ) -> Bool {
        terminatingPIDs = terminatingPIDs.intersection(runningPIDs)
        announcedAlivePIDs = announcedAlivePIDs.filter { pid in
            !terminatingPIDs.contains(pid) && (runningPIDs.contains(pid) || isProcessAlive(pid))
        }
        let activeRunning = runningPIDs.subtracting(terminatingPIDs)
        return !activeRunning.isEmpty || !announcedAlivePIDs.isEmpty
    }
}

enum CalendarKeys {
    /// 每周第一天：2 = 周一，1 = 周日（Calendar.weekday）。
    static let firstWeekday = SettingKey<Int>("calendar.firstWeekday", default: 2)
    static let weatherSource = SettingKey<WeatherSource>("weather.source", default: .openMeteo)
    static let city = SettingKey<City?>("weather.city", default: nil)
    static let qweatherKey = SettingKey<String>("weather.qweatherKey", default: "")
    static let qweatherHost = SettingKey<String>("weather.qweatherHost", default: "devapi.qweather.com")
    static let refreshMinutes = SettingKey<Int>("weather.refreshMinutes", default: 30)
    /// 菜单栏日历：是否显示，以及显示哪些内容。
    static let menuBarEnabled = SettingKey<Bool>("calendar.menuBar.enabled", default: true)
    static let menuBarStyle = SettingKey<CalendarMenuBarStyle>("calendar.menuBar.style", default: .nativeMinimal)
    static let menuBarLogo = SettingKey<Bool>("calendar.menuBar.logo", default: false)
    // 时间选项
    static let menuBarTime = SettingKey<Bool>("calendar.menuBar.time", default: true)
    static let menuBarTimeIcon = SettingKey<Bool>("calendar.menuBar.time.icon", default: false)
    static let menuBarTime24Hour = SettingKey<Bool>("calendar.menuBar.time.24hour", default: true)
    static let menuBarTimePeriod = SettingKey<Bool>("calendar.menuBar.time.period", default: false)
    static let menuBarTimeSeconds = SettingKey<Bool>("calendar.menuBar.time.seconds", default: false)
    // 日期选项
    static let menuBarDateSection = SettingKey<Bool>("calendar.menuBar.dateSection", default: true)
    static let menuBarLunar = SettingKey<Bool>("calendar.menuBar.lunar", default: false)
    static let menuBarDate = SettingKey<Bool>("calendar.menuBar.date", default: true)
    static let menuBarWeekday = SettingKey<Bool>("calendar.menuBar.weekday", default: true)
    static let menuBarHolidayBadge = SettingKey<Bool>("calendar.menuBar.holidayBadge", default: true)
    // 天气选项
    static let menuBarWeatherSection = SettingKey<Bool>("calendar.menuBar.weatherSection", default: true)
    static let menuBarWeather = SettingKey<Bool>("calendar.menuBar.weather", default: true)
    static let menuBarAQI = SettingKey<Bool>("calendar.menuBar.aqi", default: false)
    static let popoverStyle = SettingKey<CalendarPopoverStyle>("calendar.popover.style", default: .appearance)
    /// 上次的天气，断网时也有东西看。
    static let lastWeather = SettingKey<WeatherSnapshot?>("weather.last", default: nil)
}

public nonisolated struct MenuBarDisplayConfig: Sendable, Equatable {
    public var showLogo: Bool

    public var timeEnabled: Bool
    public var timeShowIcon: Bool
    public var timeUse24Hour: Bool
    public var timeShowPeriod: Bool
    public var timeShowSeconds: Bool

    public var dateEnabled: Bool
    public var dateShowLunar: Bool
    public var dateShowSolar: Bool
    public var dateShowWeekday: Bool
    public var showHolidayBadge: Bool

    public var weatherEnabled: Bool
    public var weatherShowWeather: Bool
    public var weatherShowAQI: Bool

    public init(
        showLogo: Bool = false,
        timeEnabled: Bool = true,
        timeShowIcon: Bool = false,
        timeUse24Hour: Bool = true,
        timeShowPeriod: Bool = false,
        timeShowSeconds: Bool = false,
        dateEnabled: Bool = true,
        dateShowLunar: Bool = false,
        dateShowSolar: Bool = true,
        dateShowWeekday: Bool = true,
        showHolidayBadge: Bool = true,
        weatherEnabled: Bool = true,
        weatherShowWeather: Bool = true,
        weatherShowAQI: Bool = false
    ) {
        self.showLogo = showLogo
        self.timeEnabled = timeEnabled
        self.timeShowIcon = timeShowIcon
        self.timeUse24Hour = timeUse24Hour
        self.timeShowPeriod = timeShowPeriod
        self.timeShowSeconds = timeShowSeconds
        self.dateEnabled = dateEnabled
        self.dateShowLunar = dateShowLunar
        self.dateShowSolar = dateShowSolar
        self.dateShowWeekday = dateShowWeekday
        self.showHolidayBadge = showHolidayBadge
        self.weatherEnabled = weatherEnabled
        self.weatherShowWeather = weatherShowWeather
        self.weatherShowAQI = weatherShowAQI
    }
}

public nonisolated enum MenuBarSegment: Sendable, Equatable {
    case logo
    case symbol(String)
    case text(String)
}

/// 一个月历格子。
struct DayCell: Identifiable, Hashable {
    let date: Date
    let inMonth: Bool
    var id: Date { date }
}

@Observable
public final class CalendarModel {
    public let context: PluginContext
    public let meetings: MeetingScheduleService
    var settings: SettingsStore { context.settings }
    var workCalendar: WorkCalendar { context.workCalendar }

    /// 当前显示月份的 1 号。
    var month: Date
    var selected: Date
    var weather: WeatherSnapshot?
    var weatherError: String?
    var isLoadingWeather = false
    /// 时钟：按是否开启「精确到秒」在整分钟和整秒之间动态切换，跨天后「今天」的刷新也靠它。
    public private(set) var now = Date()
    /// macOS 真实的系统深浅外观，不受应用自身强制外观（`NSApp.appearance`）影响。
    public private(set) var systemColorScheme: ColorScheme
    /// 独立版「万年历」是否正在运行（主工作台据此自动隐藏内置状态栏日历，避免重复显示）。
    public private(set) var isStandaloneCalendarRunning = false
    private enum ClockMode { case minute, second }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private var clockMode: ClockMode?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var standalonePresence = StandaloneCalendarPresenceState()
    @ObservationIgnored private var lastStandaloneReconcileAt: Date = .distantPast
    @ObservationIgnored nonisolated(unsafe) private var runningAppsObservation: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var systemThemeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var standaloneLaunchObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var standaloneTerminateObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var standaloneLifecycleObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var standaloneProbeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    private var isStandaloneHost: Bool {
        Bundle.main.bundleIdentifier == CalendarMenuBarPolicy.standaloneBundleID
    }

    nonisolated static var cal: Calendar { Lunar.gregorian }

    public init(context: PluginContext) {
        self.context = context
        self.meetings = MeetingScheduleService(settings: context.settings)
        let today = Self.cal.startOfDay(for: Date())
        selected = today
        month = Self.firstOfMonth(today)
        weather = context.settings[CalendarKeys.lastWeather]
        systemColorScheme = Self.currentSystemColorScheme()
        systemThemeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSystemColorScheme()
            }
        }
        if isStandaloneHost {
            CalendarMenuBarPolicy.postStandaloneLifecycle(.alive)
            standaloneProbeObserver = DistributedNotificationCenter.default().addObserver(
                forName: CalendarMenuBarPolicy.standaloneProbeNotification,
                object: nil,
                queue: nil
            ) { _ in
                CalendarMenuBarPolicy.postStandaloneLifecycle(.alive)
            }
        } else {
            refreshStandaloneCalendarState()
            let ws = NSWorkspace.shared
            runningAppsObservation = ws.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshStandaloneCalendarState()
                }
            }
            standaloneLifecycleObserver = DistributedNotificationCenter.default().addObserver(
                forName: CalendarMenuBarPolicy.standaloneLifecycleNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                let payload = note.object as? String
                Task { @MainActor [weak self] in
                    guard let self,
                          let (event, pid) = CalendarMenuBarPolicy.decodeLifecyclePayload(payload) else { return }
                    self.standalonePresence.handleLifecycleEvent(
                        event,
                        pid: pid,
                        currentPID: ProcessInfo.processInfo.processIdentifier
                    )
                    self.refreshStandaloneCalendarState()
                }
            }
            let wsCenter = ws.notificationCenter
            standaloneLaunchObserver = wsCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == CalendarMenuBarPolicy.standaloneBundleID else { return }
                Task { @MainActor [weak self] in
                    self?.refreshStandaloneCalendarState()
                }
            }
            standaloneTerminateObserver = wsCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == CalendarMenuBarPolicy.standaloneBundleID else { return }
                let terminatedPID = app?.processIdentifier
                Task { @MainActor [weak self] in
                    self?.refreshStandaloneCalendarState(excludingPID: terminatedPID)
                }
            }
            wakeObserver = wsCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshStandaloneCalendarState()
                    CalendarMenuBarPolicy.postStandaloneProbe()
                }
            }
            CalendarMenuBarPolicy.postStandaloneProbe()
        }
    }

    deinit {
        runningAppsObservation?.invalidate()
        let distCenter = DistributedNotificationCenter.default()
        if let systemThemeObserver {
            distCenter.removeObserver(systemThemeObserver)
        }
        if let standaloneLifecycleObserver {
            distCenter.removeObserver(standaloneLifecycleObserver)
        }
        if let standaloneProbeObserver {
            distCenter.removeObserver(standaloneProbeObserver)
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let standaloneLaunchObserver {
            wsCenter.removeObserver(standaloneLaunchObserver)
        }
        if let standaloneTerminateObserver {
            wsCenter.removeObserver(standaloneTerminateObserver)
        }
        if let wakeObserver {
            wsCenter.removeObserver(wakeObserver)
        }
    }

    /// 读取 macOS 全局 `AppleInterfaceStyle` 偏好，直接判断系统处于深色还是浅色模式。
    public nonisolated static func currentSystemColorScheme() -> ColorScheme {
        let style = CFPreferencesCopyValue(
            "AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
        return style?.caseInsensitiveCompare("dark") == .orderedSame ? .dark : .light
    }

    /// 刷新已记录的 macOS 真实系统外观。
    public func refreshSystemColorScheme() {
        let current = Self.currentSystemColorScheme()
        if systemColorScheme != current {
            systemColorScheme = current
        }
    }

    public var appAppearance: AppearanceMode {
        settings[AppSharedKeys.appearance]
    }

    public func start() {
        isRunning = true
        if isStandaloneHost {
            CalendarMenuBarPolicy.postStandaloneLifecycle(.alive)
        } else {
            refreshStandaloneCalendarState()
            CalendarMenuBarPolicy.postStandaloneProbe()
        }
        Task {
            await refreshWeatherIfNeeded()
            await meetings.refresh(around: month)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.refreshWeatherIfNeeded()
                    await self.meetings.refresh(around: self.month)
                }
            }
        }
        timer?.tolerance = 60
        syncClockTimer()
    }

    public func stop() {
        isRunning = false
        if isStandaloneHost {
            CalendarMenuBarPolicy.postStandaloneLifecycle(.willTerminate)
        }
        timer?.invalidate()
        timer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        clockMode = nil
    }

    /// 刷新独立版「万年历」的运行状态（融合系统运行列表、跨进程通知与 PID 存活核验）。
    public func refreshStandaloneCalendarState(excludingPID: pid_t? = nil) {
        guard !isStandaloneHost else { return }
        if let excludingPID {
            standalonePresence.handleLifecycleEvent(
                .willTerminate,
                pid: excludingPID,
                currentPID: ProcessInfo.processInfo.processIdentifier
            )
        }
        let runningPIDs = CalendarMenuBarPolicy.runningStandalonePIDs(excludingPID: excludingPID)
        let running = standalonePresence.reconcile(
            runningPIDs: runningPIDs,
            isProcessAlive: CalendarMenuBarPolicy.isProcessAlive
        )
        lastStandaloneReconcileAt = Date()
        if isStandaloneCalendarRunning != running {
            isStandaloneCalendarRunning = running
        }
    }

    private func reconcileStandaloneCalendarIfDue(minInterval: TimeInterval) {
        guard !isStandaloneHost else { return }
        guard Date().timeIntervalSince(lastStandaloneReconcileAt) >= minInterval else { return }
        refreshStandaloneCalendarState()
    }

    /// 跨进程设置变更后同步天气快照、会议日程与时钟精度。
    public func syncExternalChanges() {
        weather = settings[CalendarKeys.lastWeather]
        syncClockTimer()
        Task { await meetings.refresh(around: month) }
    }

    /// 根据是否开启「时间精确到秒」在整分钟与整秒定时器之间动态切换。
    public func syncClockTimer() {
        guard isRunning else { return }
        let target: ClockMode = needsSecondTick ? .second : .minute
        guard clockMode != target || clockTimer == nil else { return }
        clockTimer?.invalidate()
        clockTimer = nil
        clockMode = target
        now = Date()
        let timer: Timer
        switch target {
        case .second:
            let next = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 1)
            timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.now = Date()
                    self?.reconcileStandaloneCalendarIfDue(minInterval: 15)
                }
            }
            timer.tolerance = 0.05
        case .minute:
            let next = Self.cal.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime)
                ?? Date().addingTimeInterval(60)
            timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.now = Date()
                    self?.reconcileStandaloneCalendarIfDue(minInterval: 0)
                }
            }
            timer.tolerance = 0.5
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    public var needsSecondTick: Bool {
        settings[CalendarKeys.menuBarTime] && settings[CalendarKeys.menuBarTimeSeconds]
    }

    public var menuBarConfig: MenuBarDisplayConfig {
        MenuBarDisplayConfig(
            showLogo: settings[CalendarKeys.menuBarLogo],
            timeEnabled: settings[CalendarKeys.menuBarTime],
            timeShowIcon: settings[CalendarKeys.menuBarTimeIcon],
            timeUse24Hour: settings[CalendarKeys.menuBarTime24Hour],
            timeShowPeriod: settings[CalendarKeys.menuBarTimePeriod],
            timeShowSeconds: settings[CalendarKeys.menuBarTimeSeconds],
            dateEnabled: settings[CalendarKeys.menuBarDateSection],
            dateShowLunar: settings[CalendarKeys.menuBarLunar],
            dateShowSolar: settings[CalendarKeys.menuBarDate],
            dateShowWeekday: settings[CalendarKeys.menuBarWeekday],
            showHolidayBadge: settings[CalendarKeys.menuBarHolidayBadge],
            weatherEnabled: settings[CalendarKeys.menuBarWeatherSection],
            weatherShowWeather: settings[CalendarKeys.menuBarWeather],
            weatherShowAQI: settings[CalendarKeys.menuBarAQI]
        )
    }

    public var menuBarStyle: CalendarMenuBarStyle {
        get { settings[CalendarKeys.menuBarStyle] }
        set { settings[CalendarKeys.menuBarStyle] = newValue }
    }

    public var menuBarSnapshot: CalendarMenuBarSnapshot {
        CalendarMenuBarSnapshot.make(
            at: now,
            weather: weather,
            holidayBadge: dayBadge(now),
            config: menuBarConfig
        )
    }

    public nonisolated static func formatTime(
        _ date: Date,
        use24Hour: Bool,
        showPeriod: Bool,
        showSeconds: Bool
    ) -> String {
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = c.second ?? 0
        let displayHour: String
        if use24Hour {
            displayHour = String(format: "%02d", hour)
        } else {
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            displayHour = "\(h12)"
        }
        var time = "\(displayHour):\(String(format: "%02d", minute))"
        if showSeconds {
            time += ":\(String(format: "%02d", second))"
        }
        if showPeriod {
            let period = hour < 12 ? "上午" : "下午"
            return "\(period) \(time)"
        }
        return time
    }

    public nonisolated static func popoverTimeParts(_ date: Date, use24Hour: Bool) -> (period: String?, time: String) {
        let time = formatTime(date, use24Hour: use24Hour, showPeriod: false, showSeconds: false)
        if use24Hour {
            return (nil, time)
        }
        let hour = cal.component(.hour, from: date)
        return (hour < 12 ? "上午" : "下午", time)
    }

    public nonisolated static func formatShortTime(_ date: Date, use24Hour: Bool) -> String {
        formatTime(date, use24Hour: use24Hour, showPeriod: !use24Hour, showSeconds: false)
    }

    public nonisolated static func menuBarSegments(
        at date: Date,
        weather: WeatherSnapshot?,
        config: MenuBarDisplayConfig
    ) -> [MenuBarSegment] {
        var segments: [MenuBarSegment] = []
        if config.showLogo {
            segments.append(.logo)
        }
        if config.weatherEnabled, let w = weather {
            if config.weatherShowWeather {
                segments.append(.symbol(w.symbol))
                segments.append(.text("\(Int(w.temperature.rounded()))°"))
            }
            if config.weatherShowAQI, let aqi = w.aqi {
                segments.append(.text("AQI \(aqi)"))
            }
        }
        if config.dateEnabled {
            if config.dateShowSolar {
                segments.append(.text(CN.monthDay(date)))
            }
            if config.dateShowWeekday {
                segments.append(.text(CN.weekdayShort(date)))
            }
            if config.dateShowLunar {
                segments.append(.text(Lunar.lunar(date).text))
            }
        }
        if config.timeEnabled {
            if config.timeShowIcon {
                segments.append(.symbol("clock"))
            }
            segments.append(.text(Self.formatTime(
                date,
                use24Hour: config.timeUse24Hour,
                showPeriod: config.timeShowPeriod,
                showSeconds: config.timeShowSeconds
            )))
        }
        return segments
    }

    public var menuBarSegments: [MenuBarSegment] {
        Self.menuBarSegments(at: now, weather: weather, config: menuBarConfig)
    }

    /// 菜单栏文字，比如「11月25日 周三 12:25」（图标在视图里拼）。
    public var menuBarText: String {
        menuBarSegments.compactMap { segment in
            if case .text(let s) = segment { return s }
            return nil
        }.joined(separator: " ")
    }

    public var menuBarSymbol: String? {
        let cfg = menuBarConfig
        return cfg.weatherEnabled && cfg.weatherShowWeather ? weather?.symbol : nil
    }

    public var menuBarEnabled: Bool {
        get { settings[CalendarKeys.menuBarEnabled] }
        set { settings[CalendarKeys.menuBarEnabled] = newValue }
    }

    public var use24HourTime: Bool {
        get { settings[CalendarKeys.menuBarTime24Hour] }
        set { settings[CalendarKeys.menuBarTime24Hour] = newValue }
    }

    public var popoverTimeParts: (period: String?, time: String) {
        Self.popoverTimeParts(now, use24Hour: use24HourTime)
    }

    /// 主工作台是否应显示内置状态栏日历（独立版「万年历」运行时自动避让隐藏）。
    public var shouldShowEmbeddedMenuBar: Bool {
        CalendarMenuBarPolicy.shouldShowEmbeddedMenuBar(
            settingEnabled: menuBarEnabled,
            isStandaloneRunning: isStandaloneCalendarRunning
        )
    }

    public var popoverStyle: CalendarPopoverStyle {
        get { settings[CalendarKeys.popoverStyle] }
        set { settings[CalendarKeys.popoverStyle] = newValue }
    }

    // MARK: 月份与格子

    static func firstOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d))!
    }

    var year: Int { Self.cal.component(.year, from: month) }
    var monthNumber: Int { Self.cal.component(.month, from: month) }

    /// 42 个格子（6 周），按「每周第一天」对齐。
    var cells: [DayCell] {
        let first = settings[CalendarKeys.firstWeekday]
        let weekday = Self.cal.component(.weekday, from: month)
        let lead = (weekday - first + 7) % 7
        let start = Self.cal.date(byAdding: .day, value: -lead, to: month)!
        return (0..<42).map { i in
            let d = Self.cal.date(byAdding: .day, value: i, to: start)!
            return DayCell(date: d, inMonth: Self.cal.isDate(d, equalTo: month, toGranularity: .month))
        }
    }

    /// 表头：一 二 三 … 日
    var weekdaySymbols: [(text: String, weekend: Bool)] {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let first = settings[CalendarKeys.firstWeekday]
        return (0..<7).map { i in
            let wd = (first - 1 + i) % 7 // 0 = 周日
            return (names[wd], wd == 0 || wd == 6)
        }
    }

    func go(year: Int? = nil, month m: Int? = nil) {
        var c = Self.cal.dateComponents([.year, .month], from: month)
        if let year { c.year = year }
        if let m { c.month = m }
        c.day = 1
        if let d = Self.cal.date(from: c) {
            month = d
            Task { await meetings.refresh(around: d) }
        }
    }

    func shiftMonth(_ delta: Int) {
        if let d = Self.cal.date(byAdding: .month, value: delta, to: month) {
            month = d
            Task { await meetings.refresh(around: d) }
        }
    }

    func select(_ d: Date) {
        let day = Self.cal.startOfDay(for: d)
        if selected != day { selected = day }
        if !Self.cal.isDate(d, equalTo: month, toGranularity: .month) {
            let nextMonth = Self.firstOfMonth(d)
            month = nextMonth
            Task { await meetings.refresh(around: nextMonth) }
        }
    }

    func goToday() { select(Date()) }

    // MARK: 文案

    /// 百度式的倒计时：今天 → 距下一个法定节假日；将来 → 还有 N 天；过去 → 已经过去 N 天。
    func countdownText(for d: Date) -> String {
        let today = Self.cal.startOfDay(for: Date())
        let days = Self.cal.dateComponents([.day], from: today, to: Self.cal.startOfDay(for: d)).day ?? 0
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        if days == 0 {
            if let h = workCalendar.nextHoliday(after: today) {
                let n = Self.cal.dateComponents([.day], from: today, to: h.date).day ?? 0
                return "距离 \(Self.cal.component(.year, from: h.date))年\(h.name) 还有 \(n) 天"
            }
            return "今天"
        }
        return days > 0 ? "距离 \(f.string(from: d)) 还有 \(days) 天" : "距离 \(f.string(from: d)) 已经过去 \(-days) 天"
    }

    func dayBadge(_ d: Date) -> String? {
        switch workCalendar.dayInfo(d).kind {
        case .holiday: "休"
        case .makeupWorkday: "班"
        default: nil
        }
    }

    // MARK: 天气

    func refreshWeatherIfNeeded() async {
        guard settings[CalendarKeys.city] != nil else { return }
        let age = weather.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if age > Double(settings[CalendarKeys.refreshMinutes] * 60) { await refreshWeather() }
    }

    func refreshWeather() async {
        guard let city = settings[CalendarKeys.city] else {
            weatherError = WeatherError.noCity.localizedDescription
            return
        }
        guard !isLoadingWeather else { return }
        isLoadingWeather = true
        defer { isLoadingWeather = false }
        do {
            let w = try await WeatherService.fetch(source: settings[CalendarKeys.weatherSource], city: city,
                                                   qweatherKey: settings[CalendarKeys.qweatherKey],
                                                   qweatherHost: settings[CalendarKeys.qweatherHost])
            weather = w
            weatherError = nil
            settings[CalendarKeys.lastWeather] = w
        } catch {
            weatherError = error.localizedDescription
        }
    }

    func weather(on d: Date) -> WeatherDay? { weather?.day(Lunar.dayKey(d)) }

    var weatherShort: String? {
        guard let w = weather else { return nil }
        return "\(w.text) \(Int(w.temperature.rounded()))°"
    }

    // MARK: 会议日程联动

    /// 菜单栏展示：当前进行中或 60 分钟内即将开始的会议。
    public var nextMeetingMenuBarText: String? {
        guard let meeting = meetings.nextUpcomingMeeting(now: now, withinMinutes: 60) else { return nil }
        let rawTitle = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortTitle = rawTitle.count > 10 ? String(rawTitle.prefix(9)) + "…" : rawTitle
        if meeting.isOngoing(at: now) {
            return "会议中 \(shortTitle)"
        }
        let mins = max(1, meeting.minutesUntilStart(from: now))
        return "\(mins)分后 \(shortTitle)"
    }

    /// 将会议记录一键写入指定日期的禅道日报草稿。
    @discardableResult
    public func logMeeting(_ event: MeetingEvent, on date: Date) -> Bool {
        context.appendDailyLogDraft?("参加会议：\(event.title)", event.suggestedLogHours, date) ?? false
    }
}
