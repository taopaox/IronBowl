import Foundation
import GRDB
import Testing
@testable import IronBowlKit

private func time(_ day: String, _ hhmm: String, second: Int = 0) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: "\(day) \(hhmm):\(String(format: "%02d", second))")!
}

@Test func parsesDwsAuthStatusUserID() throws {
    let out = #"{"version_check":{"current":"v1.0.69"},"success":true,"authenticated":true,"user_id":"1923436165883676","user_name":"沈昆"}"#
    #expect(try DingTalkAttendance.parseUserID(out) == "1923436165883676")
    #expect(throws: DingTalkAttendanceError.notLoggedIn) {
        try DingTalkAttendance.parseUserID(#"{"success":true,"authenticated":false}"#)
    }
}

@Test func parsesEarliestOnDutyClockInFromCheckResult() throws {
    // 截取自 dws attendance +check-result 的真实输出结构（毫秒时间戳）。
    let out = """
    {"ok":true,"outcome":"success","data":{"count":3,"records":[
      {"checkType":"OffDuty","timeResult":"Normal","userCheckTime":1795521942000,"planCheckTime":1795512600000},
      {"checkType":"OnDuty","timeResult":"Normal","userCheckTime":1795566558000,"planCheckTime":1795566600000},
      {"checkType":"OnDuty","timeResult":"Normal","userCheckTime":1795566600000}
    ]},"meta":{"count":3}}
    """
    let clockIn = try DingTalkAttendance.parseOnDutyClockIn(out)
    #expect(clockIn == Date(timeIntervalSince1970: 1795566558))
}

@Test func checkResultWithoutClockInReturnsNil() throws {
    let notSigned = #"{"ok":true,"data":{"records":[{"checkType":"OnDuty","timeResult":"NotSigned"}]}}"#
    #expect(try DingTalkAttendance.parseOnDutyClockIn(notSigned) == nil)
    #expect(try DingTalkAttendance.parseOnDutyClockIn(#"{"ok":true,"data":{"count":0,"records":[]}}"#) == nil)
    #expect(throws: DingTalkAttendanceError.self) {
        try DingTalkAttendance.parseOnDutyClockIn("not json")
    }
}

@Test func flexOffsetFollowsClockInWithinLimit() {
    let day = "2026-11-25"
    let start = time(day, "08:30")
    func offset(_ hhmm: String, second: Int = 0) -> TimeInterval {
        WorkCalendar.flexOffset(clockIn: time(day, hhmm, second: second), plannedStart: start, flexMinutes: 30)
    }
    #expect(offset("08:00") == -1800)          // 8 点到 → 17:00 走
    #expect(offset("09:00") == 1800)           // 9 点到 → 18:00 走
    #expect(offset("08:57") == 27 * 60)        // 8:57 到 → 17:57 走
    #expect(offset("08:29", second: 18) == -60) // 按分钟计，忽略秒
    #expect(offset("07:40") == -1800)          // 早于弹性范围按最早算
    #expect(offset("09:20") == 1800)           // 晚于弹性范围按最晚算
    #expect(WorkCalendar.flexOffset(clockIn: time(day, "09:00"), plannedStart: start, flexMinutes: 0) == 0)
}

@MainActor @Test func workEndUsesStoredClockIn() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ironbowl-attendance-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    settings[WorkCalendar.startKey] = "08:30"
    settings[WorkCalendar.endKey] = "17:30"
    settings[WorkCalendar.flexMinutesKey] = 30
    let cal = WorkCalendar(database: db, settings: settings)
    let day = time("2026-11-25", "12:00")

    #expect(cal.workEnd(on: day) == time("2026-11-25", "17:30"))
    #expect(cal.onWorkTimeText(on: day) == "08:30")
    #expect(cal.scheduleText(on: day) == "08:30–17:30")

    cal.setClockIn(time("2026-11-25", "08:12", second: 40), on: day)
    #expect(cal.workEnd(on: day) == time("2026-11-25", "17:12"))
    #expect(cal.workStart(on: day) == time("2026-11-25", "08:12"))
    #expect(cal.onWorkTimeText(on: day) == "08:12")
    #expect(cal.scheduleText(on: day) == "打卡 08:12 · 17:12 下班")

    // 打卡早于弹性下限时，onWorkTimeText 仍展示实际打卡时间。
    cal.setClockIn(time("2026-11-25", "07:45"), on: day)
    #expect(cal.onWorkTimeText(on: day) == "07:45")
    #expect(cal.workEnd(on: day) == time("2026-11-25", "17:00"))

    // 重新打开数据库后仍然生效。
    let reopened = WorkCalendar(database: db, settings: settings)
    #expect(reopened.workEnd(on: day) == time("2026-11-25", "17:00"))
    #expect(reopened.onWorkTimeText(on: day) == "07:45")
    // 别的日期不受影响。
    #expect(reopened.workEnd(on: time("2026-11-26", "12:00")) == time("2026-11-26", "17:30"))
    #expect(reopened.onWorkTimeText(on: time("2026-11-26", "12:00")) == "08:30")

    cal.setClockIn(nil, on: day)
    #expect(cal.workEnd(on: day) == time("2026-11-25", "17:30"))
    #expect(cal.onWorkTimeText(on: day) == "08:30")
}

@Test func remainingTimeTextFormatsHumanReadableDurations() {
    let base = time("2026-11-26", "09:00")
    #expect(remainingTimeText(to: time("2026-11-26", "17:25"), from: base) == "8小时25分")
    #expect(remainingTimeText(to: time("2026-11-26", "11:00"), from: base) == "2小时")
    #expect(remainingTimeText(to: time("2026-11-26", "09:23"), from: base) == "23分钟")
    #expect(remainingTimeText(to: time("2026-11-26", "09:00", second: 30), from: base) == "不到1分钟")
    #expect(remainingTimeText(to: base, from: base) == "0分钟")
    #expect(remainingTimeText(to: time("2026-11-26", "08:50"), from: base) == "0分钟")
}

@Test func countdownFormatsCompactDurations() {
    let base = time("2026-11-26", "09:00")
    let samples = [
        (time("2026-11-26", "14:44"), "5小时44分"),
        (time("2026-11-26", "10:05"), "1小时5分"),
        (time("2026-11-26", "11:00"), "2小时"),
        (time("2026-11-26", "09:23"), "23分"),
        (time("2026-11-26", "09:00", second: 30), "不到1分"),
        (base, "0分"),
        (time("2026-11-26", "08:50"), "0分"),
    ]
    for (target, expected) in samples {
        let text = countdown(to: target, from: base)
        #expect(text == expected)
        #expect(!text.contains(":"))
    }
}

// MARK: 容错

@Test func classifiesDwsFailures() {
    // 真实输出：未登录时调用考勤命令（退出码 5，错误 JSON 在 stdout）。
    let notLoggedIn = #"{"ok":false,"outcome":"failure","error":{"type":"internal","exit_code":5,"upstream_code":"UNCLASSIFIED","message":"[UNCLASSIFIED] resolve access token: [REDACTED] access token: [REDACTED] secure data file: open /tmp/.dws/.data: no such file or directory"}}"#
    #expect(DingTalkAttendance.classifyFailure(status: 5, stdout: notLoggedIn, stderr: "") == .notLoggedIn)
    #expect(DingTalkAttendance.classifyFailure(status: 2, stdout: "", stderr: #"{"ok":false,"error":{"category":"auth","message":"token expired"}}"#) == .notLoggedIn)
    // npm 版找不到 node。
    #expect(DingTalkAttendance.classifyFailure(status: 127, stdout: "", stderr: "env: node: No such file or directory") == .nodeMissing)
    #expect(DingTalkAttendance.classifyFailure(status: 1, stdout: #"{"ok":false,"error":{"category":"api","message":"权限不足，需要考勤管理员"}}"#, stderr: "")
        == .noPermission("权限不足，需要考勤管理员"))
    #expect(DingTalkAttendance.classifyFailure(status: 1, stdout: "", stderr: "dial tcp: lookup mcp-gw.dingtalk.com: no such host")
        == .network("dial tcp: lookup mcp-gw.dingtalk.com: no such host"))
    #expect(DingTalkAttendance.classifyFailure(status: 1, stdout: "boom", stderr: "") == .cliFailed("boom"))
    #expect(DingTalkAttendanceError.notLoggedIn.needsUserAction)
    #expect(!DingTalkAttendanceError.timedOut.needsUserAction)
}

/// 写一个假的 dws 脚本，按子命令输出固定内容。
private func fakeDws(auth: String, attendance: String = #"{"ok":true,"data":{"records":[]}}"#, exitCode: Int = 0) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "fake-dws-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    if [ "$1" = "auth" ]; then cat <<'JSON'
    \(auth)
    JSON
    exit \(exitCode); fi
    cat <<'JSON'
    \(attendance)
    JSON
    exit \(exitCode)
    """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@MainActor private func makeCalendar(dws: URL) throws -> (WorkCalendar, URL) {
    let url = FileManager.default.temporaryDirectory.appending(path: "ironbowl-attendance-\(UUID().uuidString).sqlite")
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    settings[WorkCalendar.startKey] = "08:30"
    settings[WorkCalendar.endKey] = "17:30"
    settings[WorkCalendar.dingtalkPathKey] = dws.path
    return (WorkCalendar(database: db, settings: settings), url)
}

@MainActor @Test func syncFallsBackWhenNotLoggedIn() async throws {
    let dws = try fakeDws(auth: #"{"success":true,"authenticated":false,"message":"未登录"}"#)
    let (cal, db) = try makeCalendar(dws: dws)
    defer { try? FileManager.default.removeItem(at: dws); try? FileManager.default.removeItem(at: db) }
    let today = Date()
    await cal.syncAttendance(for: today)
    #expect(cal.attendanceIssue == .notLoggedIn)
    #expect(cal.clockIn(on: today) == nil)
    #expect(cal.workEnd(on: today) == cal.time("17:30", on: today))
}

@MainActor @Test func syncReportsMissingNode() async throws {
    let dws = try fakeDws(auth: "env: node: No such file or directory", exitCode: 127)
    let (cal, db) = try makeCalendar(dws: dws)
    defer { try? FileManager.default.removeItem(at: dws); try? FileManager.default.removeItem(at: db) }
    await cal.syncAttendance()
    #expect(cal.attendanceIssue == .nodeMissing)
}

@MainActor @Test func syncStoresClockInAndClearsIssue() async throws {
    let day = time("2026-11-25", "12:00")
    let ms = Int64(time("2026-11-25", "08:47").timeIntervalSince1970 * 1000)
    let dws = try fakeDws(auth: #"{"authenticated":true,"user_id":"u1"}"#,
                          attendance: #"{"ok":true,"data":{"records":[{"checkType":"OnDuty","timeResult":"Normal","userCheckTime":\#(ms)}]}}"#)
    let (cal, db) = try makeCalendar(dws: dws)
    defer { try? FileManager.default.removeItem(at: dws); try? FileManager.default.removeItem(at: db) }
    await cal.syncAttendance(for: day)
    #expect(cal.attendanceIssue == nil)
    #expect(cal.workEnd(on: day) == time("2026-11-25", "17:47"))
}

// MARK: 加班与实际下班时间

@MainActor @Test func effectiveWorkEndDelaysByOvertimeWhileKeepingSplitBoundary() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ironbowl-overtime-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    settings[WorkCalendar.startKey] = "08:30"
    settings[WorkCalendar.endKey] = "17:30"
    settings[WorkCalendar.flexMinutesKey] = 30
    let cal = WorkCalendar(database: db, settings: settings)
    let day = time("2026-11-25", "12:00")
    let otherDay = time("2026-11-26", "12:00")

    // 1. 无打卡 + 加班 2h
    cal.setOvertimeHours(2, on: day)
    #expect(cal.overtimeHours(on: day) == 2)
    #expect(cal.workEnd(on: day) == time("2026-11-25", "17:30"))
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "19:30"))
    #expect(cal.offWorkTimeText(on: day) == "19:30")
    #expect(cal.scheduleText(on: day) == "08:30–19:30（加班 2h）")

    // 2. 有打卡（08:12）+ 加班 2h
    cal.setClockIn(time("2026-11-25", "08:12"), on: day)
    #expect(cal.workEnd(on: day) == time("2026-11-25", "17:12"))
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "19:12"))
    #expect(cal.offWorkTimeText(on: day) == "19:12")
    #expect(cal.scheduleText(on: day) == "打卡 08:12 · 19:12 下班（加班 2h）")

    // 3. 小数加班与跨零点
    cal.setClockIn(nil, on: day)
    cal.setOvertimeHours(1.5, on: day)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "19:00"))
    #expect(cal.scheduleText(on: day) == "08:30–19:00（加班 1.5h）")

    cal.setOvertimeHours(7, on: day)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-26", "00:30"))
    #expect(cal.offWorkTimeText(on: day) == "次日 00:30")

    // 4. 持久化与日期隔离
    let reopened = WorkCalendar(database: db, settings: settings)
    #expect(reopened.overtimeHours(on: day) == 7)
    #expect(reopened.effectiveWorkEnd(on: day) == time("2026-11-26", "00:30"))
    #expect(reopened.overtimeHours(on: otherDay) == 0)
    #expect(reopened.effectiveWorkEnd(on: otherDay) == time("2026-11-26", "17:30"))

    // 5. 清零后恢复正常下班时间
    cal.setOvertimeHours(0, on: day)
    #expect(cal.overtimeHours(on: day) == 0)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "17:30"))
    #expect(cal.offWorkTimeText(on: day) == "17:30")
    #expect(cal.scheduleText(on: day) == "08:30–17:30")
}

@MainActor @Test func overtimeToggleAndAdjustFollowStepAndBounds() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ironbowl-overtime-toggle-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    settings[WorkCalendar.startKey] = "08:30"
    settings[WorkCalendar.endKey] = "17:30"
    let cal = WorkCalendar(database: db, settings: settings)
    let day = time("2026-11-25", "12:00")

    // toggle 选中、再点清零、切到其他预设
    cal.toggleOvertimeHours(2, on: day)
    #expect(cal.overtimeHours(on: day) == 2)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "19:30"))

    cal.toggleOvertimeHours(2, on: day)
    #expect(cal.overtimeHours(on: day) == 0)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "17:30"))

    cal.toggleOvertimeHours(3, on: day)
    #expect(cal.overtimeHours(on: day) == 3)
    cal.toggleOvertimeHours(1, on: day)
    #expect(cal.overtimeHours(on: day) == 1)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "18:30"))

    // 步进增减与上下限钳制
    cal.adjustOvertimeHours(by: WorkCalendar.overtimeStepHours, on: day)
    #expect(cal.overtimeHours(on: day) == 1.5)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "19:00"))

    cal.adjustOvertimeHours(by: -WorkCalendar.overtimeStepHours, on: day)
    #expect(cal.overtimeHours(on: day) == 1)
    cal.adjustOvertimeHours(by: -2, on: day)
    #expect(cal.overtimeHours(on: day) == 0)

    cal.setOvertimeHours(WorkCalendar.maxOvertimeHours, on: day)
    cal.adjustOvertimeHours(by: WorkCalendar.overtimeStepHours, on: day)
    #expect(cal.overtimeHours(on: day) == WorkCalendar.maxOvertimeHours)
}

@MainActor @Test func workProgressComputesRatioAcrossWorkday() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ironbowl-progress-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    settings[WorkCalendar.startKey] = "08:30"
    settings[WorkCalendar.endKey] = "17:30"
    settings[WorkCalendar.flexMinutesKey] = 30
    let cal = WorkCalendar(database: db, settings: settings)

    // 上班前为 0，工作时段中点（13:00）为 0.5，下班后为 1
    #expect(cal.workProgress(on: time("2026-11-25", "08:00")) == 0)
    let midpoint = cal.workProgress(on: time("2026-11-25", "13:00"))
    #expect(midpoint != nil && abs((midpoint ?? 0) - 0.5) < 0.001)
    #expect(cal.workProgress(on: time("2026-11-25", "18:00")) == 1)

    // 设置当日加班 3h 后，实际下班顺延至 20:30（总跨度 12h），14:30 为 0.5、17:30 为 0.75
    let day = time("2026-11-25", "12:00")
    cal.setOvertimeHours(3, on: day)
    let otMid = cal.workProgress(on: time("2026-11-25", "14:30"))
    #expect(otMid != nil && abs((otMid ?? 0) - 0.5) < 0.001)
    let otThreeQuarter = cal.workProgress(on: time("2026-11-25", "17:30"))
    #expect(otThreeQuarter != nil && abs((otThreeQuarter ?? 0) - 0.75) < 0.001)
}

@MainActor @Test func coreV4MigratesZentaoDailyOvertime() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ironbowl-v4-migrate-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    // 模拟已跑过 core.v1~core.v3 与旧版 zentao.v3（存在 zentaoDailyOvertime 表）的数据库
    let oldPool = try DatabasePool(path: url.path)
    var oldMigrator = DatabaseMigrator()
    for m in AppDatabase.coreMigrations.filter({ $0.identifier != "core.v4" }) {
        oldMigrator.registerMigration(m.identifier, migrate: m.migrate)
    }
    oldMigrator.registerMigration("zentao.v3") { db in
        try db.create(table: "zentaoDailyOvertime") { t in
            t.primaryKey("date", .text)
            t.column("hours", .double).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }
    try oldMigrator.migrate(oldPool)
    try oldPool.write { db in
        try db.execute(
            sql: "INSERT INTO zentaoDailyOvertime(date, hours, updatedAt) VALUES (?, ?, ?)",
            arguments: ["2026-11-25", 2.5, Date()]
        )
    }

    // 用 AppDatabase 打开，自动执行 core.v4 迁移
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    settings[WorkCalendar.endKey] = "18:00"
    let cal = WorkCalendar(database: db, settings: settings)
    let day = time("2026-11-25", "12:00")
    #expect(cal.overtimeHours(on: day) == 2.5)
    #expect(cal.effectiveWorkEnd(on: day) == time("2026-11-25", "20:30"))
}
