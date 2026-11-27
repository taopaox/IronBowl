import Foundation
import IronBowlKit
import Observation
import ZentaoLogPlugin

public nonisolated enum LedgerPeriodMode: String, CaseIterable, Sendable, Hashable {
    case monthly = "按月"
    case yearly = "按年"
}

public nonisolated struct LedgerDayStat: Sendable, Identifiable, Equatable {
    public let date: Date
    public let dateString: String
    public let dayNumber: Int
    public let isWorkday: Bool
    public let normalHours: Double
    public let overtimeHours: Double
    public let clockInText: String?
    public let offWorkText: String?

    public var id: String { dateString }
    public var totalHours: Double { normalHours + overtimeHours }
}

public nonisolated struct LedgerMonthStat: Sendable, Identifiable, Equatable {
    public let month: Int
    public let monthKey: String
    public let title: String
    public let normalHours: Double
    public let overtimeHours: Double
    public let loggedDaysCount: Int
    public let expectedWorkdaysCount: Int

    public var id: Int { month }
    public var totalHours: Double { normalHours + overtimeHours }
}

public nonisolated struct LedgerProjectStat: Sendable, Identifiable, Equatable {
    public let projectName: String
    public let hours: Double
    public let share: Double
    public let entryCount: Int

    public var id: String { projectName }
}

public nonisolated struct WorkLedgerSummary: Sendable, Equatable {
    public let totalHours: Double
    public let normalHours: Double
    public let overtimeHours: Double
    public let overtimeDaysCount: Int
    public let loggedDaysCount: Int
    public let expectedWorkdaysCount: Int
    public let clockInDaysCount: Int
    public let averageClockInMinutes: Int?
    public let earliestClockInText: String?
    public let latestOffWorkText: String?
    public let dailyCells: [LedgerDayStat]
    public let monthlyBuckets: [LedgerMonthStat]
    public let projectBreakdown: [LedgerProjectStat]

    public var averageClockInText: String? {
        guard let m = averageClockInMinutes else { return nil }
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    public static let empty = WorkLedgerSummary(
        totalHours: 0,
        normalHours: 0,
        overtimeHours: 0,
        overtimeDaysCount: 0,
        loggedDaysCount: 0,
        expectedWorkdaysCount: 0,
        clockInDaysCount: 0,
        averageClockInMinutes: nil,
        earliestClockInText: nil,
        latestOffWorkText: nil,
        dailyCells: [],
        monthlyBuckets: [],
        projectBreakdown: []
    )

    public static func computeSummary(
        year: Int,
        dates: [Date],
        workdayFlags: [String: Bool],
        itemsByDate: [String: [DailyLogItem]],
        clockInsByDate: [String: Date],
        plannedOvertimeByDate: [String: Double],
        offWorkTextByDate: [String: String] = [:]
    ) -> WorkLedgerSummary {
        let cal = Calendar(identifier: .gregorian)
        let timeFmt = DateFormatter()
        timeFmt.calendar = cal
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = .current
        timeFmt.dateFormat = "HH:mm"

        var totalNormal = 0.0
        var totalOvertime = 0.0
        var overtimeDays = 0
        var loggedDays = 0
        var expectedWorkdays = 0
        var clockInMinutesList: [Int] = []
        var earliestClockIn: (minuteOfDay: Int, label: String)?
        var latestOffWork: (secondsFromStart: TimeInterval, label: String)?

        var dailyCells: [LedgerDayStat] = []
        var monthNormal: [Int: Double] = [:]
        var monthOvertime: [Int: Double] = [:]
        var monthLoggedDays: [Int: Int] = [:]
        var monthWorkdays: [Int: Int] = [:]
        var projectHours: [String: Double] = [:]
        var projectCounts: [String: Int] = [:]

        for date in dates {
            let ds = WorkCalendar.dayString(date)
            let isWorkday = workdayFlags[ds] ?? false
            let m = cal.component(.month, from: date)
            let dNum = cal.component(.day, from: date)
            if isWorkday {
                expectedWorkdays += 1
                monthWorkdays[m, default: 0] += 1
            }

            let items = itemsByDate[ds] ?? []
            let dayNormal = items.filter { !$0.isOvertime }.reduce(0) { $0 + $1.hours }
            let loggedOT = items.filter(\.isOvertime).reduce(0) { $0 + $1.hours }
            let plannedOT = plannedOvertimeByDate[ds] ?? 0
            let dayOT = max(loggedOT, plannedOT)

            if !items.isEmpty || plannedOT > 0 {
                if !items.isEmpty {
                    loggedDays += 1
                    monthLoggedDays[m, default: 0] += 1
                }
            }
            if dayOT > 0 {
                overtimeDays += 1
            }
            totalNormal += dayNormal
            totalOvertime += dayOT
            monthNormal[m, default: 0] += dayNormal
            monthOvertime[m, default: 0] += dayOT

            for item in items {
                let rawProject = item.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let project = rawProject.isEmpty ? "其他工作" : rawProject
                projectHours[project, default: 0] += item.hours
                projectCounts[project, default: 0] += 1
            }

            var clockInStr: String?
            if let ci = clockInsByDate[ds] {
                let comps = cal.dateComponents([.hour, .minute], from: ci)
                let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                clockInMinutesList.append(mins)
                let hhmm = timeFmt.string(from: ci)
                clockInStr = hhmm
                let label = "\(CN.monthDay(date)) \(hhmm)"
                if earliestClockIn == nil || mins < earliestClockIn!.minuteOfDay {
                    earliestClockIn = (mins, label)
                }
            }

            let offText = offWorkTextByDate[ds]
            if let offText, !offText.isEmpty, isWorkday || dayOT > 0 {
                let isNextDay = offText.hasPrefix("次日 ")
                let cleanHHMM = offText.replacingOccurrences(of: "次日 ", with: "")
                let parts = cleanHHMM.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 {
                    let secs = TimeInterval((isNextDay ? 24 * 60 : 0) + parts[0] * 60 + parts[1]) * 60
                    let label = "\(CN.monthDay(date)) \(offText)"
                    if latestOffWork == nil || secs > latestOffWork!.secondsFromStart {
                        latestOffWork = (secs, label)
                    }
                }
            }

            dailyCells.append(LedgerDayStat(
                date: date,
                dateString: ds,
                dayNumber: dNum,
                isWorkday: isWorkday,
                normalHours: dayNormal,
                overtimeHours: dayOT,
                clockInText: clockInStr,
                offWorkText: offText
            ))
        }

        let avgMinute: Int? = clockInMinutesList.isEmpty
            ? nil
            : Int((Double(clockInMinutesList.reduce(0, +)) / Double(clockInMinutesList.count)).rounded())

        let monthlyBuckets: [LedgerMonthStat] = (1...12).map { m in
            LedgerMonthStat(
                month: m,
                monthKey: String(format: "%04d-%02d", year, m),
                title: "\(m)月",
                normalHours: monthNormal[m] ?? 0,
                overtimeHours: monthOvertime[m] ?? 0,
                loggedDaysCount: monthLoggedDays[m] ?? 0,
                expectedWorkdaysCount: monthWorkdays[m] ?? 0
            )
        }

        let totalProjectHours = projectHours.values.reduce(0, +)
        let projectBreakdown: [LedgerProjectStat] = projectHours.keys
            .sorted { (projectHours[$0] ?? 0) > (projectHours[$1] ?? 0) }
            .map { name in
                let h = projectHours[name] ?? 0
                return LedgerProjectStat(
                    projectName: name,
                    hours: h,
                    share: totalProjectHours > 0 ? h / totalProjectHours : 0,
                    entryCount: projectCounts[name] ?? 0
                )
            }

        return WorkLedgerSummary(
            totalHours: totalNormal + totalOvertime,
            normalHours: totalNormal,
            overtimeHours: totalOvertime,
            overtimeDaysCount: overtimeDays,
            loggedDaysCount: loggedDays,
            expectedWorkdaysCount: expectedWorkdays,
            clockInDaysCount: clockInMinutesList.count,
            averageClockInMinutes: avgMinute,
            earliestClockInText: earliestClockIn?.label,
            latestOffWorkText: latestOffWork?.label,
            dailyCells: dailyCells,
            monthlyBuckets: monthlyBuckets,
            projectBreakdown: projectBreakdown
        )
    }
}

@Observable
final class WorkLedgerModel {
    let context: PluginContext
    let dailyLogService: ZentaoDailyLogService

    var mode: LedgerPeriodMode = .monthly {
        didSet {
            if oldValue != mode {
                syncedFromZentao = false
                loadLocal()
            }
        }
    }
    var month: MonthRange = MonthRange.containing(Date())
    var year: Int = Calendar(identifier: .gregorian).component(.year, from: Date())
    var includeDrafts: Bool = true {
        didSet {
            if oldValue != includeDrafts {
                loadLocal()
            }
        }
    }

    var summary: WorkLedgerSummary = .empty
    var isLoading = false
    var syncedFromZentao = false
    var remoteError: String?

    @ObservationIgnored private var rawItemsByDate: [String: [DailyLogItem]] = [:]

    init(context: PluginContext) {
        self.context = context
        self.dailyLogService = ZentaoDailyLogService(database: context.database, settings: context.settings)
        loadLocal()
    }

    var isZentaoConfigured: Bool { dailyLogService.isZentaoConfigured }

    var periodTitle: String {
        switch mode {
        case .monthly: month.title
        case .yearly: "\(year)年"
        }
    }

    var isCurrentPeriod: Bool {
        let now = Date()
        switch mode {
        case .monthly:
            return month.monthKey == MonthRange.containing(now).monthKey
        case .yearly:
            return year == Calendar(identifier: .gregorian).component(.year, from: now)
        }
    }

    func shiftPeriod(_ delta: Int) {
        switch mode {
        case .monthly:
            month = month.shifted(byMonths: delta)
        case .yearly:
            year = max(2000, min(2099, year + delta))
        }
        syncedFromZentao = false
        loadLocal()
    }

    func goToCurrentPeriod() {
        let now = Date()
        month = MonthRange.containing(now)
        year = Calendar(identifier: .gregorian).component(.year, from: now)
        syncedFromZentao = false
        loadLocal()
    }

    private func activeDates() -> [Date] {
        switch mode {
        case .monthly:
            return month.days
        case .yearly:
            let cal = Calendar(identifier: .gregorian)
            return (1...12).flatMap { m -> [Date] in
                guard let first = cal.date(from: DateComponents(year: year, month: m, day: 1)),
                      let count = cal.range(of: .day, in: .month, for: first)?.count else { return [] }
                return (1...count).compactMap { cal.date(from: DateComponents(year: year, month: m, day: $0)) }
            }
        }
    }

    private func activeRangeStrings() -> (start: String, end: String) {
        switch mode {
        case .monthly:
            return (month.startDateString, month.endDateString)
        case .yearly:
            return (String(format: "%04d-01-01", year), String(format: "%04d-12-31", year))
        }
    }

    func loadLocal() {
        let (start, end) = activeRangeStrings()
        let items = dailyLogService.loadLocal(from: start, to: end, includeDrafts: includeDrafts)
        rawItemsByDate = items
        recomputeSummary(with: items)
    }

    func refreshFromZentao() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let (start, end) = activeRangeStrings()
        let result = await dailyLogService.fetch(from: start, to: end, includeDrafts: includeDrafts)
        rawItemsByDate = result.itemsByDate
        syncedFromZentao = result.syncedFromZentao
        remoteError = result.remoteError
        recomputeSummary(with: result.itemsByDate)
    }

    private func recomputeSummary(with itemsByDate: [String: [DailyLogItem]]) {
        let dates = activeDates()
        let cal = context.workCalendar
        var workdayFlags: [String: Bool] = [:]
        var clockIns: [String: Date] = [:]
        var plannedOT: [String: Double] = [:]
        var offTexts: [String: String] = [:]

        for d in dates {
            let ds = WorkCalendar.dayString(d)
            workdayFlags[ds] = cal.isWorkday(d)
            if let ci = cal.clockIn(on: d) {
                clockIns[ds] = ci
            }
            let ot = cal.overtimeHours(on: d)
            if ot > 0 {
                plannedOT[ds] = ot
            }
            if let off = cal.offWorkTimeText(on: d) {
                offTexts[ds] = off
            }
        }

        let targetYear = mode == .monthly ? month.year : year
        summary = WorkLedgerSummary.computeSummary(
            year: targetYear,
            dates: dates,
            workdayFlags: workdayFlags,
            itemsByDate: itemsByDate,
            clockInsByDate: clockIns,
            plannedOvertimeByDate: plannedOT,
            offWorkTextByDate: offTexts
        )
    }
}
