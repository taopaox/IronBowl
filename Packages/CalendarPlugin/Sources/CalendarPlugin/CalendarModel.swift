import Foundation
import IronBowlKit
import Observation

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
    static let menuBarWeather = SettingKey<Bool>("calendar.menuBar.weather", default: true)
    static let menuBarDate = SettingKey<Bool>("calendar.menuBar.date", default: true)
    static let menuBarWeekday = SettingKey<Bool>("calendar.menuBar.weekday", default: true)
    static let menuBarTime = SettingKey<Bool>("calendar.menuBar.time", default: true)
    static let menuBarLunar = SettingKey<Bool>("calendar.menuBar.lunar", default: false)
    /// 上次的天气，断网时也有东西看。
    static let lastWeather = SettingKey<WeatherSnapshot?>("weather.last", default: nil)
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
    var settings: SettingsStore { context.settings }
    var workCalendar: WorkCalendar { context.workCalendar }

    /// 当前显示月份的 1 号。
    var month: Date
    var selected: Date
    var weather: WeatherSnapshot?
    var weatherError: String?
    var isLoadingWeather = false
    /// 分钟级时钟：菜单栏时间、跨天后「今天」的刷新都靠它。
    public private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var minuteTimer: Timer?

    static var cal: Calendar { Lunar.gregorian }

    public init(context: PluginContext) {
        self.context = context
        let today = Self.cal.startOfDay(for: Date())
        selected = today
        month = Self.firstOfMonth(today)
        weather = context.settings[CalendarKeys.lastWeather]
    }

    public func start() {
        Task { await refreshWeatherIfNeeded() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshWeatherIfNeeded() }
            }
        }
        timer?.tolerance = 60
        scheduleMinuteTick()
    }

    /// 对齐到整分钟刷新 `now`，菜单栏时间不会慢半拍，也不用每秒刷新。
    private func scheduleMinuteTick() {
        let next = Self.cal.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        minuteTimer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        minuteTimer?.tolerance = 0.5
        RunLoop.main.add(minuteTimer!, forMode: .common)
    }

    /// 菜单栏文字，比如「11月25日 周三 12:25」（天气图标在视图里拼）。
    public var menuBarText: String {
        let d = now
        var parts: [String] = []
        if settings[CalendarKeys.menuBarWeather], let w = weather { parts.append("\(Int(w.temperature.rounded()))°") }
        if settings[CalendarKeys.menuBarDate] { parts.append(CN.monthDay(d)) }
        if settings[CalendarKeys.menuBarWeekday] { parts.append(CN.weekdayShort(d)) }
        if settings[CalendarKeys.menuBarLunar] { parts.append(Lunar.lunar(d).dayName) }
        if settings[CalendarKeys.menuBarTime] { parts.append(CN.time(d)) }
        return parts.joined(separator: " ")
    }

    public var menuBarSymbol: String? {
        settings[CalendarKeys.menuBarWeather] ? weather?.symbol : nil
    }

    public var menuBarEnabled: Bool {
        get { settings[CalendarKeys.menuBarEnabled] }
        set { settings[CalendarKeys.menuBarEnabled] = newValue }
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
        if let d = Self.cal.date(from: c) { month = d }
    }

    func shiftMonth(_ delta: Int) {
        if let d = Self.cal.date(byAdding: .month, value: delta, to: month) { month = d }
    }

    func select(_ d: Date) {
        selected = Self.cal.startOfDay(for: d)
        if !Self.cal.isDate(d, equalTo: month, toGranularity: .month) { month = Self.firstOfMonth(d) }
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
}
