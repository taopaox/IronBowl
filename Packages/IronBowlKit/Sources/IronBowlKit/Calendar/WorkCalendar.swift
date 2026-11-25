import Foundation
import GRDB
import Observation

public nonisolated enum HolidaySource: String, Codable, Sendable, CaseIterable, Identifiable {
    case holidayCNjsDelivr
    case holidayCNGitHub
    case timor
    case manual

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .holidayCNjsDelivr: "holiday-cn（jsDelivr，推荐）"
        case .holidayCNGitHub: "holiday-cn（GitHub 原地址）"
        case .timor: "timor.tech"
        case .manual: "仅手动标记"
        }
    }
}

public nonisolated enum HolidayUpdateFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case yearly, monthly, manualOnly
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .yearly: "每年一次"
        case .monthly: "每月一次"
        case .manualOnly: "只在手动点击时"
        }
    }
}

/// 一天的类型。
public nonisolated struct DayInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case workday, weekend, holiday, makeupWorkday }
    public let kind: Kind
    /// 节假日名称，比如"国庆节"。
    public let name: String?
    public var isWorkday: Bool { kind == .workday || kind == .makeupWorkday }
}

/// 工作日、上下班时间、节假日。
@Observable
public final class WorkCalendar {
    public static let weekdaysKey = SettingKey<[Int]>("work.weekdays", default: [2, 3, 4, 5, 6]) // Calendar.weekday：1=周日
    public static let startKey = SettingKey<String>("work.start", default: "09:00")
    public static let endKey = SettingKey<String>("work.end", default: "18:00")
    public static let lunchMinutesKey = SettingKey<Int>("work.lunchMinutes", default: 60)
    public static let sourceKey = SettingKey<HolidaySource>("holiday.source", default: .holidayCNjsDelivr)
    public static let frequencyKey = SettingKey<HolidayUpdateFrequency>("holiday.frequency", default: .yearly)
    public static let lastFetchKey = SettingKey<Date?>("holiday.lastFetch", default: nil)

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let settings: SettingsStore
    private var holidays: [String: (isOffDay: Bool, name: String)] = [:]
    private var overrides: [String: (isOffDay: Bool, note: String)] = [:]
    public private(set) var isUpdating = false
    public private(set) var lastError: String?

    nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public nonisolated static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    public init(database: AppDatabase, settings: SettingsStore) {
        self.database = database
        self.settings = settings
        reload()
    }

    public func reload() {
        let (h, o) = (try? database.pool.read { db in
            (try Row.fetchAll(db, sql: "SELECT date, isOffDay, name FROM holiday"),
             try Row.fetchAll(db, sql: "SELECT date, isOffDay, note FROM holidayOverride"))
        }) ?? ([], [])
        holidays = Dictionary(uniqueKeysWithValues: h.map { ($0["date"] as String, (isOffDay: $0["isOffDay"] as Bool, name: $0["name"] as String)) })
        overrides = Dictionary(uniqueKeysWithValues: o.map { ($0["date"] as String, (isOffDay: $0["isOffDay"] as Bool, note: $0["note"] as String)) })
    }

    // MARK: 查询

    public func dayInfo(_ date: Date) -> DayInfo {
        let key = Self.dayString(date)
        let weekday = Calendar.current.component(.weekday, from: date)
        let normallyWork = settings[Self.weekdaysKey].contains(weekday)
        if let o = overrides[key] {
            return DayInfo(kind: o.isOffDay ? (normallyWork ? .holiday : .weekend) : (normallyWork ? .workday : .makeupWorkday),
                           name: o.note.isEmpty ? nil : o.note)
        }
        if let h = holidays[key] {
            return DayInfo(kind: h.isOffDay ? .holiday : .makeupWorkday, name: h.name)
        }
        return DayInfo(kind: normallyWork ? .workday : .weekend, name: nil)
    }

    public func isWorkday(_ date: Date) -> Bool { dayInfo(date).isWorkday }

    public func override(for date: Date) -> Bool? { overrides[Self.dayString(date)]?.isOffDay }

    /// 默认工时（小时）= 下班 − 上班 − 午休。
    public var defaultWorkHours: Double {
        let start = minutes(settings[Self.startKey]) ?? 540
        let end = minutes(settings[Self.endKey]) ?? 1080
        return max(0, Double(end - start - settings[Self.lunchMinutesKey]) / 60)
    }

    /// 某天的下班时刻。
    public func workEnd(on date: Date = Date()) -> Date? {
        guard let m = minutes(settings[Self.endKey]) else { return nil }
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: date)
    }

    func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    // MARK: 手动标记

    /// isOffDay = nil 表示清除手动标记。
    public func setOverride(_ date: Date, isOffDay: Bool?, note: String = "") {
        let key = Self.dayString(date)
        try? database.pool.write { db in
            if let isOffDay {
                try db.execute(sql: "INSERT OR REPLACE INTO holidayOverride(date, isOffDay, note) VALUES (?, ?, ?)",
                               arguments: [key, isOffDay, note])
            } else {
                try db.execute(sql: "DELETE FROM holidayOverride WHERE date = ?", arguments: [key])
            }
        }
        reload()
    }

    // MARK: 节假日数据

    /// 按更新频率判断是否需要联网更新。
    public func updateIfNeeded() async {
        let source = settings[Self.sourceKey]
        guard source != .manual else { return }
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let hasThisYear = holidays.keys.contains { $0.hasPrefix("\(year)-") }
        let hasNextYear = holidays.keys.contains { $0.hasPrefix("\(year + 1)-") }
        let last = settings[Self.lastFetchKey]
        let due: Bool
        switch settings[Self.frequencyKey] {
        case .manualOnly:
            due = !hasThisYear && last == nil
        case .yearly:
            let decemberCheck = cal.component(.month, from: now) == 12 && !hasNextYear
                && (last.map { now.timeIntervalSince($0) > 7 * 86400 } ?? true)
            due = !hasThisYear || last.map { cal.component(.year, from: $0) < year } ?? true || decemberCheck
        case .monthly:
            due = last.map { now.timeIntervalSince($0) > 30 * 86400 } ?? true
        }
        if due { await updateNow() }
    }

    /// 立即拉取今年和明年的数据。
    public func updateNow() async {
        let source = settings[Self.sourceKey]
        guard source != .manual, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        let year = Calendar.current.component(.year, from: Date())
        var errors: [String] = []
        for y in [year, year + 1] {
            do {
                let days = try await HolidayFetcher.fetch(source: source, year: y)
                guard !days.isEmpty else { continue }
                try await database.pool.write { db in
                    try db.execute(sql: "DELETE FROM holiday WHERE date LIKE ?", arguments: ["\(y)-%"])
                    for d in days {
                        try db.execute(sql: "INSERT OR REPLACE INTO holiday(date, isOffDay, name, source) VALUES (?, ?, ?, ?)",
                                       arguments: [d.date, d.isOffDay, d.name, source.rawValue])
                    }
                }
            } catch {
                // 明年的数据可能还没发布，只在今年失败时报错。
                if y == year { errors.append("\(y)：\(error.localizedDescription)") }
            }
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "；")
        if errors.isEmpty { settings[Self.lastFetchKey] = Date() }
        reload()
    }

    /// 已缓存数据覆盖到的年份。
    public var cachedYears: [Int] {
        Set(holidays.keys.compactMap { Int($0.prefix(4)) }).sorted()
    }
}

nonisolated struct HolidayDay: Sendable {
    let date: String
    let isOffDay: Bool
    let name: String
}

nonisolated enum HolidayFetcher {
    @concurrent
    static func fetch(source: HolidaySource, year: Int) async throws -> [HolidayDay] {
        let url: URL
        switch source {
        case .holidayCNjsDelivr: url = URL(string: "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/\(year).json")!
        case .holidayCNGitHub: url = URL(string: "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/\(year).json")!
        case .timor: url = URL(string: "https://timor.tech/api/holiday/year/\(year)")!
        case .manual: return []
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("IronBowl/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        switch source {
        case .timor:
            struct R: Decodable { let code: Int; let holiday: [String: Item]? }
            struct Item: Decodable { let holiday: Bool; let name: String; let date: String }
            let r = try JSONDecoder().decode(R.self, from: data)
            return (r.holiday ?? [:]).values.map { HolidayDay(date: $0.date, isOffDay: $0.holiday, name: $0.name) }
        default:
            struct R: Decodable { let days: [Item] }
            struct Item: Decodable { let name: String; let date: String; let isOffDay: Bool }
            return try JSONDecoder().decode(R.self, from: data).days.map { HolidayDay(date: $0.date, isOffDay: $0.isOffDay, name: $0.name) }
        }
    }
}
