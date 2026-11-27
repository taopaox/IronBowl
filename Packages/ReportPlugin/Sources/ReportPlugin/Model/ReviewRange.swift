import Foundation
import IronBowlKit

/// 述职 / 复盘周期粒度：季度、半年度、全年。
public nonisolated enum ReviewScopeKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case quarterly
    case halfYearly
    case yearly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quarterly: "季度总结"
        case .halfYearly: "半年度述职"
        case .yearly: "年度述职"
        }
    }

    public var shortName: String {
        switch self {
        case .quarterly: "季度"
        case .halfYearly: "半年度"
        case .yearly: "全年"
        }
    }
}

/// 季度 / 半年度 / 全年周期范围计算。
public nonisolated struct ReviewRange: Equatable, Hashable, Sendable {
    public let scopeKind: ReviewScopeKind
    public let year: Int
    /// quarterly: 1...4；halfYearly: 1...2；yearly: 1。
    public let periodIndex: Int

    public init(scopeKind: ReviewScopeKind, year: Int, periodIndex: Int) {
        self.scopeKind = scopeKind
        self.year = max(2000, min(2099, year))
        switch scopeKind {
        case .quarterly:
            self.periodIndex = min(4, max(1, periodIndex))
        case .halfYearly:
            self.periodIndex = min(2, max(1, periodIndex))
        case .yearly:
            self.periodIndex = 1
        }
    }

    public static func containing(_ date: Date, scopeKind: ReviewScopeKind) -> ReviewRange {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: date)
        let month = cal.component(.month, from: date)
        let index: Int
        switch scopeKind {
        case .quarterly:
            index = ((month - 1) / 3) + 1
        case .halfYearly:
            index = month <= 6 ? 1 : 2
        case .yearly:
            index = 1
        }
        return ReviewRange(scopeKind: scopeKind, year: year, periodIndex: index)
    }

    public static func fromPeriodKey(_ key: String) -> ReviewRange? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 4, let year = Int(trimmed) {
            return ReviewRange(scopeKind: .yearly, year: year, periodIndex: 1)
        }
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let year = Int(parts[0]) else { return nil }
        let suffix = String(parts[1]).uppercased()
        if suffix.hasPrefix("Q"), let q = Int(suffix.dropFirst()), (1...4).contains(q) {
            return ReviewRange(scopeKind: .quarterly, year: year, periodIndex: q)
        }
        if suffix.hasPrefix("H"), let h = Int(suffix.dropFirst()), (1...2).contains(h) {
            return ReviewRange(scopeKind: .halfYearly, year: year, periodIndex: h)
        }
        return nil
    }

    public var periodKey: String {
        switch scopeKind {
        case .quarterly: "\(year)-Q\(periodIndex)"
        case .halfYearly: "\(year)-H\(periodIndex)"
        case .yearly: "\(year)"
        }
    }

    public var title: String {
        switch scopeKind {
        case .quarterly: "\(year)年第\(periodIndex)季度"
        case .halfYearly: "\(year)年\(periodIndex == 1 ? "上半年" : "下半年")"
        case .yearly: "\(year)年度"
        }
    }

    public var months: [Int] {
        switch scopeKind {
        case .quarterly:
            let start = (periodIndex - 1) * 3 + 1
            return Array(start...(start + 2))
        case .halfYearly:
            return periodIndex == 1 ? Array(1...6) : Array(7...12)
        case .yearly:
            return Array(1...12)
        }
    }

    public var monthKeys: [String] {
        months.map { String(format: "%04d-%02d", year, $0) }
    }

    public var startDate: Date {
        let cal = Calendar(identifier: .gregorian)
        return cal.date(from: DateComponents(year: year, month: months.first ?? 1, day: 1))!
    }

    public var endDate: Date {
        let cal = Calendar(identifier: .gregorian)
        let lastMonth = months.last ?? 12
        let firstOfLast = cal.date(from: DateComponents(year: year, month: lastMonth, day: 1))!
        let dayCount = cal.range(of: .day, in: .month, for: firstOfLast)?.count ?? 30
        return cal.date(from: DateComponents(year: year, month: lastMonth, day: dayCount))!
    }

    public var days: [Date] {
        let cal = Calendar(identifier: .gregorian)
        return months.flatMap { m -> [Date] in
            guard let first = cal.date(from: DateComponents(year: year, month: m, day: 1)),
                  let count = cal.range(of: .day, in: .month, for: first)?.count else { return [] }
            return (1...count).compactMap { cal.date(from: DateComponents(year: year, month: m, day: $0)) }
        }
    }

    public var startDateString: String { WorkCalendar.dayString(startDate) }
    public var endDateString: String { WorkCalendar.dayString(endDate) }

    public var rangeText: String {
        "\(startDateString) ~ \(endDateString)"
    }

    public func shifted(by delta: Int) -> ReviewRange {
        switch scopeKind {
        case .quarterly:
            let total = year * 4 + (periodIndex - 1) + delta
            let nextYear = total >= 0 ? total / 4 : (total - 3) / 4
            let nextIdx = ((total % 4) + 4) % 4 + 1
            return ReviewRange(scopeKind: .quarterly, year: nextYear, periodIndex: nextIdx)
        case .halfYearly:
            let total = year * 2 + (periodIndex - 1) + delta
            let nextYear = total >= 0 ? total / 2 : (total - 1) / 2
            let nextIdx = ((total % 2) + 2) % 2 + 1
            return ReviewRange(scopeKind: .halfYearly, year: nextYear, periodIndex: nextIdx)
        case .yearly:
            return ReviewRange(scopeKind: .yearly, year: year + delta, periodIndex: 1)
        }
    }

    public func isCurrent(now: Date = Date()) -> Bool {
        self == Self.containing(now, scopeKind: scopeKind)
    }
}
