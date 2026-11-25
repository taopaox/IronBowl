import Foundation
import IronBowlKit

/// 按中国工作周规范（周一为每周第一天，周日为最后一天）表示的一周区间。
public nonisolated struct WeekRange: Sendable, Equatable, Hashable, Codable {
    public let startDate: Date
    public let endDate: Date
    public let days: [Date]
    public let isoYear: Int
    public let weekOfYear: Int

    public init(startDate: Date, endDate: Date, days: [Date], isoYear: Int, weekOfYear: Int) {
        self.startDate = startDate
        self.endDate = endDate
        self.days = days
        self.isoYear = isoYear
        self.weekOfYear = weekOfYear
    }

    public var dayStrings: [String] {
        days.map(WorkCalendar.dayString)
    }

    public var startDateString: String {
        WorkCalendar.dayString(startDate)
    }

    public var endDateString: String {
        WorkCalendar.dayString(endDate)
    }

    public var title: String {
        "\(isoYear)年第\(weekOfYear)周"
    }

    public var rangeText: String {
        "\(CN.monthDay(startDate)) – \(CN.monthDay(endDate))"
    }

    public var shortRangeText: String {
        "\(CN.slash(startDate))–\(CN.slash(endDate))"
    }

    private static var gregorianCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    private static var isoCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal
    }

    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func containing(_ date: Date) -> WeekRange {
        let cal = gregorianCalendar
        let dayStart = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: dayStart) // 1 = 周日, 2 = 周一, ..., 7 = 周六
        let offsetFromMonday = (weekday + 5) % 7
        let monday = cal.date(byAdding: .day, value: -offsetFromMonday, to: dayStart) ?? dayStart
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
        let sunday = days.last ?? monday

        let iso = isoCalendar
        let isoYear = iso.component(.yearForWeekOfYear, from: monday)
        let weekOfYear = iso.component(.weekOfYear, from: monday)

        return WeekRange(
            startDate: monday,
            endDate: sunday,
            days: days,
            isoYear: isoYear,
            weekOfYear: weekOfYear
        )
    }

    public static func fromStartDateString(_ string: String) -> WeekRange? {
        guard let date = ymdFormatter.date(from: string) else { return nil }
        return containing(date)
    }

    public func shifted(byWeeks delta: Int) -> WeekRange {
        let cal = Self.gregorianCalendar
        let target = cal.date(byAdding: .day, value: delta * 7, to: startDate) ?? startDate
        return Self.containing(target)
    }

    public func relativeBadge(now: Date = Date()) -> String? {
        let current = Self.containing(now)
        if startDateString == current.startDateString {
            return "本周"
        }
        if startDateString == current.shifted(byWeeks: -1).startDateString {
            return "上周"
        }
        return nil
    }
}
