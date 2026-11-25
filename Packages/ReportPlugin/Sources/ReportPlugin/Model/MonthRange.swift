import Foundation
import IronBowlKit

/// 自然月内按工作周切分的一个周片段（仅包含落在本自然月内的日期）。
public nonisolated struct MonthWeekSlice: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let weekOfYear: Int
    public let days: [Date]

    public init(id: String, weekOfYear: Int, days: [Date]) {
        self.id = id
        self.weekOfYear = weekOfYear
        self.days = days
    }

    public var dayStrings: [String] {
        days.map(WorkCalendar.dayString)
    }

    public var label: String {
        "第\(weekOfYear)周"
    }

    public var shortRangeText: String {
        guard let first = days.first else { return "" }
        guard let last = days.last, days.count > 1 else {
            return CN.slash(first)
        }
        return "\(CN.slash(first))–\(CN.slash(last))"
    }
}

/// 自然月区间（每月 1 日至月末）。
public nonisolated struct MonthRange: Sendable, Equatable, Hashable, Codable {
    public let year: Int
    public let month: Int
    public let startDate: Date
    public let endDate: Date
    public let days: [Date]

    public init(year: Int, month: Int, startDate: Date, endDate: Date, days: [Date]) {
        self.year = year
        self.month = month
        self.startDate = startDate
        self.endDate = endDate
        self.days = days
    }

    public var monthKey: String {
        String(format: "%04d-%02d", year, month)
    }

    public var startDateString: String {
        WorkCalendar.dayString(startDate)
    }

    public var endDateString: String {
        WorkCalendar.dayString(endDate)
    }

    public var dayStrings: [String] {
        days.map(WorkCalendar.dayString)
    }

    public var title: String {
        "\(year)年\(month)月"
    }

    public var rangeText: String {
        "\(CN.monthDay(startDate)) – \(CN.monthDay(endDate))"
    }

    public var shortRangeText: String {
        "\(CN.slash(startDate))–\(CN.slash(endDate))"
    }

    public var weeks: [MonthWeekSlice] {
        var order: [String] = []
        var grouped: [String: (weekOfYear: Int, days: [Date])] = [:]
        for day in days {
            let week = WeekRange.containing(day)
            let key = week.startDateString
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (week.weekOfYear, [day])
            } else {
                grouped[key]?.days.append(day)
            }
        }
        return order.compactMap { key in
            guard let item = grouped[key] else { return nil }
            return MonthWeekSlice(id: key, weekOfYear: item.weekOfYear, days: item.days)
        }
    }

    private static var gregorianCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    public static func containing(_ date: Date) -> MonthRange {
        let cal = gregorianCalendar
        let comps = cal.dateComponents([.year, .month], from: date)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let firstDay = cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? cal.startOfDay(for: date)
        let dayCount = cal.range(of: .day, in: .month, for: firstDay)?.count ?? 28
        let days = (1...dayCount).compactMap { cal.date(from: DateComponents(year: year, month: month, day: $0)) }
        let lastDay = days.last ?? firstDay
        return MonthRange(year: year, month: month, startDate: firstDay, endDate: lastDay, days: days)
    }

    public static func fromMonthKey(_ key: String) -> MonthRange? {
        let parts = key.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else {
            return nil
        }
        let cal = gregorianCalendar
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return nil
        }
        return containing(date)
    }

    public func shifted(byMonths delta: Int) -> MonthRange {
        let cal = Self.gregorianCalendar
        let target = cal.date(byAdding: .month, value: delta, to: startDate) ?? startDate
        return Self.containing(target)
    }

    public func relativeBadge(now: Date = Date()) -> String? {
        let current = Self.containing(now)
        if monthKey == current.monthKey {
            return "本月"
        }
        if monthKey == current.shifted(byMonths: -1).monthKey {
            return "上月"
        }
        return nil
    }
}
