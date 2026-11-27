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
        case .holidayCNjsDelivr: "holiday-cn（推荐）"
        case .holidayCNGitHub: "holiday-cn（GitHub）"
        case .timor: "timor.tech"
        case .manual: "仅手动标记"
        }
    }
    public var detail: String {
        switch self {
        case .holidayCNjsDelivr: "通过 jsDelivr CDN 同步国务院放假与调休安排，国内访问稳定。"
        case .holidayCNGitHub: "直接从 GitHub 仓库拉取 holiday-cn 年度节假日数据。"
        case .timor: "使用第三方 timor.tech 接口获取年度节假日信息。"
        case .manual: "不联网更新节假日，仅使用本地手动标记。"
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
        case .manualOnly: "仅手动更新"
        }
    }
    public var detail: String {
        switch self {
        case .yearly: "每年自动拉取一次当年及下年节假日安排。"
        case .monthly: "每月检查一次，及时同步临时调整。"
        case .manualOnly: "关闭自动更新，仅在点击「立即更新」时拉取。"
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

/// 持久化在本地的每日上下班打卡记录。
public nonisolated struct AttendanceRecord: Sendable, Equatable {
    public let date: String
    public let clockIn: Date?
    public let clockOut: Date?
    public let onDutyResult: String
    public let offDutyResult: String
    public let source: String
    public let fetchedAt: Date

    public init(
        date: String,
        clockIn: Date? = nil,
        clockOut: Date? = nil,
        onDutyResult: String = "",
        offDutyResult: String = "",
        source: String = "dingtalk",
        fetchedAt: Date = Date()
    ) {
        self.date = date
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.onDutyResult = onDutyResult
        self.offDutyResult = offDutyResult
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

/// 每日考勤异常类型。
public nonisolated enum AttendanceAnomaly: String, Sendable, Equatable, CaseIterable {
    case missingClockIn
    case missingClockOut
    case late
    case earlyLeave

    public var displayName: String {
        switch self {
        case .missingClockIn: "缺上班卡"
        case .missingClockOut: "缺下班卡"
        case .late: "上班迟到"
        case .earlyLeave: "提前早退"
        }
    }
}

/// 工作日、上下班时间、节假日。
@Observable
public final class WorkCalendar {
    private static let changeNotification = Notification.Name("com.taopaox.ironbowl.holidaysDidChange")

    public static let weekdaysKey = SettingKey<[Int]>("work.weekdays", default: [2, 3, 4, 5, 6]) // Calendar.weekday：1=周日
    public static let startKey = SettingKey<String>("work.start", default: "09:00")
    public static let endKey = SettingKey<String>("work.end", default: "18:00")
    public static let lunchMinutesKey = SettingKey<Int>("work.lunchMinutes", default: 60)
    public static let sourceKey = SettingKey<HolidaySource>("holiday.source", default: .holidayCNjsDelivr)
    public static let frequencyKey = SettingKey<HolidayUpdateFrequency>("holiday.frequency", default: .yearly)
    public static let lastFetchKey = SettingKey<Date?>("holiday.lastFetch", default: nil)
    /// 弹性时间（分钟）：上班早到/晚到几分钟，下班就提前/推后几分钟，最多这么多。
    public static let flexMinutesKey = SettingKey<Int>("work.flexMinutes", default: 30)
    /// 是否通过钉钉 CLI（dws）自动同步每天的上班打卡时间。
    public static let dingtalkEnabledKey = SettingKey<Bool>("attendance.dingtalk.enabled", default: false)
    /// dws 程序路径，留空自动查找。
    public static let dingtalkPathKey = SettingKey<String>("attendance.dingtalk.path", default: "")

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    @ObservationIgnored public var onChange: (() -> Void)?
    private var holidays: [String: (isOffDay: Bool, name: String)] = [:]
    private var overrides: [String: (isOffDay: Bool, note: String)] = [:]
    /// 每天的上班打卡时间（yyyy-MM-dd → 打卡时刻），来自 `attendanceClockIn` / `attendanceDailyRecord` 表。
    private var clockIns: [String: Date] = [:]
    /// 每天的完整上下班考勤记录（yyyy-MM-dd → AttendanceRecord），来自 `attendanceDailyRecord` 表。
    private var dailyAttendances: [String: AttendanceRecord] = [:]
    /// 每天的计划加班时长（yyyy-MM-dd → 小时），来自 `dailyOvertime` 表。
    private var dailyOvertimes: [String: Double] = [:]
    public private(set) var isUpdating = false
    public private(set) var lastError: String?
    public private(set) var isSyncingAttendance = false
    /// 最近一次同步失败的原因；成功后清空。
    public private(set) var attendanceIssue: DingTalkAttendanceError?
    public var attendanceError: String? { attendanceIssue?.localizedDescription }
    public private(set) var attendanceLastSync: Date?
    /// 自动同步遇到需要用户处理的问题时回调（同一天同类问题只回调一次），主工作台用来弹提醒。
    @ObservationIgnored public var onAttendanceIssue: ((DingTalkAttendanceError) -> Void)?
    /// 同步到某天新的下班打卡时回调（主工作台用来自动消掉桌面常驻打卡提醒）。
    @ObservationIgnored public var onClockOutSynced: ((Date, Date) -> Void)?
    @ObservationIgnored private var notifiedAttendanceIssue: String?
    @ObservationIgnored private var attendanceLastAttempt: Date?
    @ObservationIgnored private var dingtalkUserID: String?

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
        let myPID = ProcessInfo.processInfo.processIdentifier
        let dbPath = database.path
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.changeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let payload = note.object as? String
            Task { @MainActor [weak self] in
                guard let self, let payload else { return }
                let parts = payload.split(separator: "|", maxSplits: 1)
                guard parts.count == 2,
                      Int32(parts[0]) != myPID,
                      String(parts[1]) == dbPath else { return }
                self.reload()
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func notifyExternalChange() {
        let payload = "\(ProcessInfo.processInfo.processIdentifier)|\(database.path)"
        DistributedNotificationCenter.default().postNotificationName(
            Self.changeNotification,
            object: payload,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public func reload() {
        let (h, o, c, d, ot): ([Row], [Row], [Row], [Row], [Row]) = (try? database.pool.read { db -> ([Row], [Row], [Row], [Row], [Row]) in
            let dailyRows: [Row] = (try? db.tableExists("attendanceDailyRecord")) == true
                ? (try Row.fetchAll(db, sql: "SELECT date, clockIn, clockOut, onDutyResult, offDutyResult, source, fetchedAt FROM attendanceDailyRecord"))
                : []
            return (
                try Row.fetchAll(db, sql: "SELECT date, isOffDay, name FROM holiday"),
                try Row.fetchAll(db, sql: "SELECT date, isOffDay, note FROM holidayOverride"),
                try Row.fetchAll(db, sql: "SELECT date, clockIn FROM attendanceClockIn"),
                dailyRows,
                try Row.fetchAll(db, sql: "SELECT date, hours FROM dailyOvertime WHERE hours > 0")
            )
        }) ?? ([], [], [], [], [])
        holidays = Dictionary(uniqueKeysWithValues: h.map { ($0["date"] as String, (isOffDay: $0["isOffDay"] as Bool, name: $0["name"] as String)) })
        overrides = Dictionary(uniqueKeysWithValues: o.map { ($0["date"] as String, (isOffDay: $0["isOffDay"] as Bool, note: $0["note"] as String)) })
        var nextClockIns = Dictionary(c.map { ($0["date"] as String, $0["clockIn"] as Date) }, uniquingKeysWith: { a, _ in a })
        var nextDaily: [String: AttendanceRecord] = [:]
        for row in d {
            let ds: String = row["date"]
            let ci: Date? = row["clockIn"]
            let co: Date? = row["clockOut"]
            let rec = AttendanceRecord(
                date: ds,
                clockIn: ci,
                clockOut: co,
                onDutyResult: row["onDutyResult"] ?? "",
                offDutyResult: row["offDutyResult"] ?? "",
                source: row["source"] ?? "dingtalk",
                fetchedAt: row["fetchedAt"] ?? Date()
            )
            nextDaily[ds] = rec
            if let ci {
                nextClockIns[ds] = ci
            }
        }
        clockIns = nextClockIns
        dailyAttendances = nextDaily
        dailyOvertimes = Dictionary(ot.map { ($0["date"] as String, $0["hours"] as Double) }, uniquingKeysWith: { a, _ in a })
        onChange?()
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

    /// 某天的正常下班时刻（仅含弹性规则顺延，不含加班，供禅道日志拆分正常/加班提交分界线使用）。
    public func workEnd(on date: Date = Date()) -> Date? {
        time(settings[Self.endKey], on: date).map { $0.addingTimeInterval(flexOffset(on: date)) }
    }

    public static let maxOvertimeHours: Double = 12
    public static let overtimeStepHours: Double = 0.5

    /// 某天计划加班的小时数。
    public func overtimeHours(on date: Date = Date()) -> Double {
        dailyOvertimes[Self.dayString(date)] ?? 0
    }

    /// 设置某天的计划加班小时数（按 0.5h 步进限制在 0...12）；<= 0 时清除。
    public func setOvertimeHours(_ hours: Double, on date: Date = Date()) {
        let rounded = (hours * 2).rounded() / 2
        let clamped = min(Self.maxOvertimeHours, max(0, rounded))
        let key = Self.dayString(date)
        let current = dailyOvertimes[key] ?? 0
        guard abs(current - clamped) > 0.001 else { return }
        try? database.pool.write { db in
            if clamped <= 0 {
                try db.execute(sql: "DELETE FROM dailyOvertime WHERE date = ?", arguments: [key])
            } else {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO dailyOvertime(date, hours, updatedAt) VALUES (?, ?, ?)",
                    arguments: [key, clamped, Date()]
                )
            }
        }
        reload()
        notifyExternalChange()
    }

    /// 切换某天的计划加班时长：若当前已等于目标值则清零，否则设为目标值。
    public func toggleOvertimeHours(_ hours: Double, on date: Date = Date()) {
        if abs(overtimeHours(on: date) - hours) < 0.01 {
            setOvertimeHours(0, on: date)
        } else {
            setOvertimeHours(hours, on: date)
        }
    }

    /// 按指定增量微调某天的计划加班时长（受 0.5h 步进与 0...12h 上下限约束）。
    public func adjustOvertimeHours(by delta: Double, on date: Date = Date()) {
        setOvertimeHours(overtimeHours(on: date) + delta, on: date)
    }

    /// 某天的实际下班时刻（正常下班时刻 + 计划加班时长）。供界面展示、倒计时与进度条使用。
    public func effectiveWorkEnd(on date: Date = Date()) -> Date? {
        guard let baseEnd = workEnd(on: date) else { return nil }
        let ot = overtimeHours(on: date)
        return ot > 0 ? baseEnd.addingTimeInterval(ot * 3600) : baseEnd
    }

    public nonisolated static func hoursText(_ hours: Double) -> String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
    }

    /// 某天的实际下班时间文字，比如「18:00」或跨零点时的「次日 00:30」。
    public func offWorkTimeText(on date: Date = Date()) -> String? {
        guard let end = effectiveWorkEnd(on: date) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let hhmm = f.string(from: end)
        return Calendar.current.isDate(end, inSameDayAs: date) ? hhmm : "次日 \(hhmm)"
    }

    /// 某天的上班时间文字：当天有打卡记录时显示实际打卡时间（HH:mm），否则显示配置的固定上班时间（work.start）。
    public func onWorkTimeText(on date: Date = Date()) -> String {
        if let clockIn = clockIn(on: date) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: clockIn)
        }
        return settings[Self.startKey]
    }

    /// 某天按弹性规则折算后的上班时刻（下班倒计时进度条的起点）。
    public func workStart(on date: Date = Date()) -> Date? {
        time(settings[Self.startKey], on: date).map { $0.addingTimeInterval(flexOffset(on: date)) }
    }

    /// 某天当前时刻在上班到实际下班之间的进度（0...1）；无有效下班时刻时返回 nil。
    public func workProgress(on now: Date = Date()) -> Double? {
        guard let end = effectiveWorkEnd(on: now) else { return nil }
        let start = workStart(on: now)
            ?? end.addingTimeInterval(-(defaultWorkHours * 3600 + Double(settings[Self.lunchMinutesKey]) * 60))
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// 弹性偏移（秒）：当天打卡时间相对规定上班时间的差值，限制在 ±弹性时长内；没打卡记录时为 0。
    public func flexOffset(on date: Date) -> TimeInterval {
        guard let clockIn = clockIns[Self.dayString(date)],
              let start = time(settings[Self.startKey], on: date) else { return 0 }
        return Self.flexOffset(clockIn: clockIn, plannedStart: start, flexMinutes: settings[Self.flexMinutesKey])
    }

    /// 打卡按分钟计（忽略秒），比规定上班早/晚的分钟数限制在 ±flexMinutes。
    public nonisolated static func flexOffset(clockIn: Date, plannedStart: Date, flexMinutes: Int) -> TimeInterval {
        let flex = TimeInterval(max(0, flexMinutes) * 60)
        let minute = (clockIn.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        return min(flex, max(-flex, minute - plannedStart.timeIntervalSinceReferenceDate))
    }

    /// 某天的上下班说明，比如「打卡 08:29 · 17:29 下班」、「打卡 08:55–18:06（已下班打卡）」、「打卡 08:29 · 19:29 下班（加班 2h）」或「08:30–17:30」。
    public func scheduleText(on date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let ot = overtimeHours(on: date)
        let otSuffix = ot > 0 ? "（加班 \(Self.hoursText(ot))h）" : ""
        if let ci = self.clockIn(on: date), let co = self.clockOut(on: date) {
            return "打卡 \(f.string(from: ci))–\(f.string(from: co))（已下班打卡）"
        }
        if let clockIn = self.clockIn(on: date), let endText = offWorkTimeText(on: date) {
            return "打卡 \(f.string(from: clockIn)) · \(endText) 下班\(otSuffix)"
        }
        if ot > 0, let endText = offWorkTimeText(on: date) {
            return "\(settings[Self.startKey])–\(endText)\(otSuffix)"
        }
        return "\(settings[Self.startKey])–\(settings[Self.endKey])"
    }

    func time(_ hhmm: String, on date: Date) -> Date? {
        guard let m = minutes(hhmm) else { return nil }
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
        notifyExternalChange()
    }

    // MARK: 上下班打卡（钉钉考勤）

    /// 某天的完整上下班打卡记录。
    public func attendance(on date: Date) -> AttendanceRecord? { dailyAttendances[Self.dayString(date)] }

    /// 某天的上班打卡时刻。
    public func clockIn(on date: Date) -> Date? { clockIns[Self.dayString(date)] }

    /// 某天的下班打卡时刻。
    public func clockOut(on date: Date) -> Date? { dailyAttendances[Self.dayString(date)]?.clockOut }

    /// 某天的真实在岗时长（小时）：基于上班打卡与下班打卡计算，跨度超过午休分钟数时扣除午休，否则不倒扣。
    public func actualStayHours(on date: Date) -> Double? {
        guard let ci = clockIn(on: date), let co = clockOut(on: date), co > ci else { return nil }
        let spanSeconds = co.timeIntervalSince(ci)
        let lunchSeconds = Double(max(0, settings[Self.lunchMinutesKey])) * 60
        let netSeconds = spanSeconds > lunchSeconds ? (spanSeconds - lunchSeconds) : spanSeconds
        return netSeconds / 3600
    }

    /// 某天的考勤异常（缺上班卡 / 缺下班卡 / 迟到 / 早退）。
    /// 仅在已同步到考勤记录时判定；若是今天且尚未到预计下班时刻，不误报缺下班卡。
    public func attendanceAnomalies(on date: Date, now: Date = Date()) -> [AttendanceAnomaly] {
        guard isWorkday(date), let rec = attendance(on: date) else { return [] }
        var issues: [AttendanceAnomaly] = []
        let cal = Calendar.current
        let isToday = cal.isDate(date, inSameDayAs: now)

        if rec.clockIn == nil || rec.onDutyResult.caseInsensitiveCompare("NotSigned") == .orderedSame {
            let pastStart = !isToday || (workStart(on: date).map { now > $0 } ?? true)
            if pastStart {
                issues.append(.missingClockIn)
            }
        } else if ["Late", "SeriousLate", "Absenteeism"].contains(where: { rec.onDutyResult.caseInsensitiveCompare($0) == .orderedSame }) {
            issues.append(.late)
        }

        let pastEnd: Bool = isToday
            ? (effectiveWorkEnd(on: date).map { now >= $0 } ?? false)
            : (cal.startOfDay(for: date) < cal.startOfDay(for: now))
        if rec.clockOut == nil || rec.offDutyResult.caseInsensitiveCompare("NotSigned") == .orderedSame {
            if pastEnd {
                issues.append(.missingClockOut)
            }
        } else if rec.offDutyResult.caseInsensitiveCompare("Early") == .orderedSame {
            issues.append(.earlyLeave)
        }
        return issues
    }

    /// 记录某天的上班打卡；nil 表示清除。
    public func setClockIn(_ time: Date?, on date: Date, source: String = "dingtalk") {
        let key = Self.dayString(date)
        let current = dailyAttendances[key]
        guard clockIns[key] != time || (time != nil && current?.clockIn != time) else { return }
        try? database.pool.write { db in
            if let time {
                try db.execute(sql: "INSERT OR REPLACE INTO attendanceClockIn(date, clockIn, source, fetchedAt) VALUES (?, ?, ?, ?)",
                               arguments: [key, time, source, Date()])
                if try db.tableExists("attendanceDailyRecord") {
                    try db.execute(
                        sql: """
                        INSERT INTO attendanceDailyRecord(date, clockIn, clockOut, onDutyResult, offDutyResult, source, fetchedAt)
                        VALUES (?, ?, ?, 'Normal', '', ?, ?)
                        ON CONFLICT(date) DO UPDATE SET
                            clockIn = excluded.clockIn,
                            onDutyResult = CASE WHEN attendanceDailyRecord.onDutyResult = '' THEN 'Normal' ELSE attendanceDailyRecord.onDutyResult END,
                            source = excluded.source,
                            fetchedAt = excluded.fetchedAt
                        """,
                        arguments: [key, time, current?.clockOut, source, Date()]
                    )
                }
            } else {
                try db.execute(sql: "DELETE FROM attendanceClockIn WHERE date = ?", arguments: [key])
                if try db.tableExists("attendanceDailyRecord") {
                    if let co = current?.clockOut {
                        try db.execute(
                            sql: "UPDATE attendanceDailyRecord SET clockIn = NULL, onDutyResult = '' WHERE date = ?",
                            arguments: [key]
                        )
                        _ = co
                    } else {
                        try db.execute(sql: "DELETE FROM attendanceDailyRecord WHERE date = ?", arguments: [key])
                    }
                }
            }
        }
        reload()
        notifyExternalChange()
    }

    /// 写入某天完整上下班考勤记录（保留已有非空字段避免覆盖手动或旧记录）。
    public func saveAttendance(_ record: AttendanceRecord, notifyExternal: Bool = true) {
        try? database.pool.write { db in
            try Self.persistAttendance(record, in: db)
        }
        reload()
        if notifyExternal {
            notifyExternalChange()
        }
    }

    private nonisolated static func persistAttendance(_ record: AttendanceRecord, in db: Database) throws {
        if try db.tableExists("attendanceDailyRecord") {
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO attendanceDailyRecord(date, clockIn, clockOut, onDutyResult, offDutyResult, source, fetchedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.date,
                    record.clockIn,
                    record.clockOut,
                    record.onDutyResult,
                    record.offDutyResult,
                    record.source,
                    record.fetchedAt,
                ]
            )
        }
        if let ci = record.clockIn {
            try db.execute(
                sql: "INSERT OR REPLACE INTO attendanceClockIn(date, clockIn, source, fetchedAt) VALUES (?, ?, ?, ?)",
                arguments: [record.date, ci, record.source, record.fetchedAt]
            )
        }
    }

    /// 立即通过 dws 拉取某天的上下班打卡。任何失败都只记录在 `attendanceIssue`，下班时间回落到固定的 `work.end`。
    public func syncAttendance(for date: Date = Date()) async {
        guard !isSyncingAttendance else { return }
        isSyncingAttendance = true
        attendanceLastAttempt = Date()
        defer { isSyncingAttendance = false }
        do {
            let path = try await resolveDwsPath()
            let userID = try await resolveDingtalkUserID(executable: path)
            let ds = Self.dayString(date)
            if let fetched = try await DingTalkAttendance.fetchDayAttendance(executable: path, userID: userID, day: ds) {
                let prevClockOut = dailyAttendances[ds]?.clockOut
                let resolvedIn = fetched.clockIn ?? dailyAttendances[ds]?.clockIn
                let resolvedOut = fetched.clockOut ?? dailyAttendances[ds]?.clockOut
                let record = AttendanceRecord(
                    date: ds,
                    clockIn: resolvedIn,
                    clockOut: resolvedOut,
                    onDutyResult: fetched.onDutyResult.isEmpty ? (dailyAttendances[ds]?.onDutyResult ?? "") : fetched.onDutyResult,
                    offDutyResult: fetched.offDutyResult.isEmpty ? (dailyAttendances[ds]?.offDutyResult ?? "") : fetched.offDutyResult,
                    source: "dingtalk",
                    fetchedAt: Date()
                )
                saveAttendance(record)
                if prevClockOut == nil, let newOut = resolvedOut {
                    onClockOutSynced?(date, newOut)
                }
            }
            attendanceIssue = nil
            attendanceLastSync = Date()
        } catch {
            // 出错后下次重新确认登录账号（可能已退出或换了账号）。
            dingtalkUserID = nil
            attendanceIssue = error as? DingTalkAttendanceError ?? .cliFailed(error.localizedDescription)
        }
    }

    /// 批量通过 dws 同步区间 `[startDate, endDate]` 内的全部考勤打卡记录，返回同步天数。
    @discardableResult
    public func syncAttendanceRange(from startDate: Date, to endDate: Date) async throws -> Int {
        guard !isSyncingAttendance else { return 0 }
        isSyncingAttendance = true
        attendanceLastAttempt = Date()
        defer { isSyncingAttendance = false }
        do {
            let path = try await resolveDwsPath()
            let userID = try await resolveDingtalkUserID(executable: path)
            let startStr = Self.dayString(startDate)
            let endStr = Self.dayString(endDate)
            let fetchedMap = try await DingTalkAttendance.fetchRangeAttendance(
                executable: path,
                userID: userID,
                startDay: startStr,
                endDay: endStr
            )
            let now = Date()
            try await database.pool.write { [existing = self.dailyAttendances] db in
                for (ds, item) in fetchedMap {
                    let prev = existing[ds]
                    let rec = AttendanceRecord(
                        date: ds,
                        clockIn: item.clockIn ?? prev?.clockIn,
                        clockOut: item.clockOut ?? prev?.clockOut,
                        onDutyResult: item.onDutyResult.isEmpty ? (prev?.onDutyResult ?? "") : item.onDutyResult,
                        offDutyResult: item.offDutyResult.isEmpty ? (prev?.offDutyResult ?? "") : item.offDutyResult,
                        source: "dingtalk",
                        fetchedAt: now
                    )
                    try Self.persistAttendance(rec, in: db)
                }
            }
            reload()
            notifyExternalChange()
            attendanceIssue = nil
            attendanceLastSync = now
            return fetchedMap.count
        } catch {
            dingtalkUserID = nil
            let err = error as? DingTalkAttendanceError ?? .cliFailed(error.localizedDescription)
            attendanceIssue = err
            throw err
        }
    }

    private func resolveDingtalkUserID(executable: String) async throws -> String {
        if let cached = dingtalkUserID { return cached }
        let id = try await DingTalkAttendance.currentUserID(executable: executable)
        dingtalkUserID = id
        return id
    }

    /// 配置的路径失效（卸载、换了 node 版本）时自动重新查找；找不到就清空配置。
    private func resolveDwsPath() async throws -> String {
        let configured = settings[Self.dingtalkPathKey]
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) { return configured }
        guard let found = await DingTalkAttendance.locateExecutable() else {
            if !configured.isEmpty { settings[Self.dingtalkPathKey] = "" }
            throw DingTalkAttendanceError.missingExecutable
        }
        settings[Self.dingtalkPathKey] = found
        return found
    }

    /// 定时调用：开启了钉钉同步、今天上班、且需要拉取上班卡或下班卡时执行同步。
    /// 重试间隔：一般失败 5 分钟；没安装 / 没登录 / 没权限这类要用户处理的问题 30 分钟，并且同一天同类问题只回调一次 `onAttendanceIssue`。
    public func syncAttendanceIfNeeded(now: Date = Date()) async {
        guard settings[Self.dingtalkEnabledKey], isWorkday(now),
              let start = time(settings[Self.startKey], on: now),
              let end = time(settings[Self.endKey], on: now) else { return }
        let flex = TimeInterval(max(0, settings[Self.flexMinutesKey]) * 60)
        let upperEnd = effectiveWorkEnd(on: now) ?? end
        let needsClockIn = clockIn(on: now) == nil
            && now >= start.addingTimeInterval(-flex)
            && now <= upperEnd.addingTimeInterval(flex)
        let needsClockOut = clockOut(on: now) == nil
            && now >= upperEnd.addingTimeInterval(-10 * 60)
            && now <= upperEnd.addingTimeInterval(4 * 3600)
        guard needsClockIn || needsClockOut else { return }

        let interval: TimeInterval = attendanceIssue?.needsUserAction == true ? 1800 : 300
        if let last = attendanceLastAttempt, now.timeIntervalSince(last) < interval { return }
        await syncAttendance(for: now)
        if let issue = attendanceIssue, issue.needsUserAction {
            let key = "\(Self.dayString(now))|\(issue.kind)"
            if notifiedAttendanceIssue != key {
                notifiedAttendanceIssue = key
                onAttendanceIssue?(issue)
            }
        }
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
        notifyExternalChange()
    }

    /// 下一个法定节假日（第一天）。
    public func nextHoliday(after date: Date = Date()) -> (name: String, date: Date)? {
        let today = Self.dayString(date)
        var seen = Set<String>()
        let firsts = holidays.filter { $0.value.isOffDay && $0.key > today }
            .sorted { $0.key < $1.key }
            .filter { seen.insert($0.value.name).inserted }
        guard let first = firsts.first, let d = Self.dayFormatter.date(from: first.key) else { return nil }
        return (first.value.name, d)
    }

    /// 某年的法定节假日（每个假期取第一天），给万年历的「假期」下拉用。
    public func holidays(inYear year: Int) -> [(name: String, date: Date)] {
        var seen = Set<String>()
        return holidays.filter { $0.value.isOffDay && $0.key.hasPrefix("\(year)-") }
            .sorted { $0.key < $1.key }
            .filter { seen.insert($0.value.name).inserted }
            .compactMap { kv in Self.dayFormatter.date(from: kv.key).map { (kv.value.name, $0) } }
    }

    /// 农历日期，比如"十月十七"。
    public nonisolated static func lunarString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .chinese)
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MMMd"
        return f.string(from: date)
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
