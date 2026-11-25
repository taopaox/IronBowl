import Foundation
import Testing
@testable import IronBowlKit

@Test func taskScheduleWorkdaysSkipsWeekendsAndRespectsTodayCutoff() {
    let cal = Calendar(identifier: .gregorian)
    // 2026-11-25 是周三
    let wedBefore5 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 16, minute: 30))!
    let wedAfter5 = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 5))!
    // 2026-11-27 是周五
    let friAfter5 = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 17, minute: 1))!

    let schedule = TaskSchedule(kind: .workdays, hour: 17, minute: 0)
    let isWeekday: (Date) -> Bool = { date in
        let wd = cal.component(.weekday, from: date)
        return (2...6).contains(wd)
    }

    let next1 = schedule.nextRun(after: wedBefore5, isWorkday: isWeekday, calendar: cal)
    #expect(next1 == cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 0)))

    let next2 = schedule.nextRun(after: wedAfter5, isWorkday: isWeekday, calendar: cal)
    #expect(next2 == cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 17, minute: 0)))

    let next3 = schedule.nextRun(after: friAfter5, isWorkday: isWeekday, calendar: cal)
    // 跳过周六周日，推到下周一 2026-11-30 17:00
    #expect(next3 == cal.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 17, minute: 0)))
}

@MainActor @Test func taskScheduleWorkdaysUsesWorkCalendarOverrides() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "scheduler-cal-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    let workCal = WorkCalendar(database: db, settings: settings)

    let cal = Calendar.current
    let thu = cal.date(from: DateComponents(year: 2026, month: 11, day: 26))!
    let fri = cal.date(from: DateComponents(year: 2026, month: 11, day: 27))!
    let sat = cal.date(from: DateComponents(year: 2026, month: 11, day: 28))!

    // 周五设为放假，周六设为补班
    workCal.setOverride(fri, isOffDay: true, note: "调休")
    workCal.setOverride(sat, isOffDay: false, note: "补班")

    let schedule = TaskSchedule(kind: .workdays, hour: 17, minute: 0)
    let thuEvening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: thu)!
    let next = schedule.nextRun(after: thuEvening, workCalendar: workCal, calendar: cal)
    #expect(next == cal.date(bySettingHour: 17, minute: 0, second: 0, of: sat))
}

@Test func taskScheduleDailyWeeklyAndIntervalCalculations() {
    let cal = Calendar(identifier: .gregorian)
    let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 18, minute: 0))!

    let daily = TaskSchedule(kind: .daily, hour: 17, minute: 30)
    #expect(daily.nextRun(after: wed, isWorkday: { _ in true }, calendar: cal)
        == cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 17, minute: 30)))

    // 每周仅周一(2)和周五(6) 09:30
    let weekly = TaskSchedule(kind: .weekly, hour: 9, minute: 30, weekdays: [2, 6])
    #expect(weekly.nextRun(after: wed, isWorkday: { _ in true }, calendar: cal)
        == cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 9, minute: 30)))

    let interval = TaskSchedule(kind: .interval, intervalMinutes: 30)
    #expect(interval.nextRun(after: wed, isWorkday: { _ in true }, calendar: cal)
        == wed.addingTimeInterval(30 * 60))
}

@Test func evaluateDueHandlesGraceWindowMisfireAndDeduplication() {
    let cal = Calendar(identifier: .gregorian)
    let scheduledFor = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 0))!
    let schedule = TaskSchedule(kind: .workdays, hour: 17, minute: 0)
    let slot = schedule.slotKey(for: scheduledFor, calendar: cal)

    var task = ScheduledTask(
        id: "t1",
        name: "自动提交",
        actionID: "a1",
        isEnabled: true,
        schedule: schedule,
        misfirePolicy: .runIfMissedToday,
        nextRunAt: scheduledFor
    )

    // 到点前不触发
    let before = scheduledFor.addingTimeInterval(-10)
    #expect(TaskScheduler.evaluateDue(task: task, now: before, isWorkday: { _ in true }, calendar: cal) == .notDue)

    // 宽限期内（+30s）准点触发
    let onTime = scheduledFor.addingTimeInterval(30)
    if case .fire(let trigger, let fireAt, let fireSlot, _) =
        TaskScheduler.evaluateDue(task: task, now: onTime, isWorkday: { _ in true }, calendar: cal) {
        #expect(trigger == .scheduled)
        #expect(fireAt == scheduledFor)
        #expect(fireSlot == slot)
    } else {
        Issue.record("预期准点触发")
    }

    // 同槽位已触发过，不再重复触发，只推进下次时间
    task.lastFiredSlot = slot
    if case .advanceOnly(let next) = TaskScheduler.evaluateDue(task: task, now: onTime, isWorkday: { _ in true }, calendar: cal) {
        #expect(next > onTime)
    } else {
        Issue.record("预期同槽位仅推进时间")
    }

    // 超出宽限期但在同一天（17:45），开启补执行时触发 misfireCatchUp
    task.lastFiredSlot = nil
    let sameDayLate = cal.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 17, minute: 45))!
    if case .fire(let trigger, _, _, _) =
        TaskScheduler.evaluateDue(task: task, now: sameDayLate, isWorkday: { _ in true }, calendar: cal) {
        #expect(trigger == .misfireCatchUp)
    } else {
        Issue.record("预期同日补执行")
    }

    // 策略为 skip 时同日迟到只推进不触发
    task.misfirePolicy = .skip
    if case .advanceOnly = TaskScheduler.evaluateDue(task: task, now: sameDayLate, isWorkday: { _ in true }, calendar: cal) {
    } else {
        Issue.record("预期 skip 策略不补跑")
    }

    // 跨天错过即使开启 runIfMissedToday 也不补跑昨天
    task.misfirePolicy = .runIfMissedToday
    let nextDay = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 0))!
    if case .advanceOnly = TaskScheduler.evaluateDue(task: task, now: nextDay, isWorkday: { _ in true }, calendar: cal) {
    } else {
        Issue.record("预期跨天不补跑")
    }
}

@MainActor @Test func taskSchedulerSeedsOncePersistsAndExecutesManualRun() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "scheduler-run-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    let workCal = WorkCalendar(database: db, settings: settings)
    let scheduler = TaskScheduler(
        database: db,
        settings: settings,
        workCalendar: workCal,
        reminders: ReminderCenter()
    )

    var executedCount = 0
    scheduler.register(action: ScheduledTaskAction(
        id: "test.echo",
        title: "测试动作",
        subtitle: "用于单测",
        systemImage: "bolt",
        defaultName: "测试任务"
    ) { ctx in
        executedCount += 1
        return .succeeded(summary: "参数=\(ctx.string("k"))", detail: "ok")
    })

    // Seed 一次；删除后再次 seed 不会复活
    let seedID = "seed.test.1"
    scheduler.seedDefaultTaskIfNeeded({
        ScheduledTask(
            id: seedID,
            name: "默认测试任务",
            actionID: "test.echo",
            schedule: TaskSchedule(kind: .daily, hour: 17, minute: 0),
            notifyPolicy: .never,
            parameters: ["k": "v1"]
        )
    }, seedID: seedID)
    #expect(scheduler.tasks.count == 1)
    #expect(scheduler.tasks[0].nextRunAt != nil)

    await scheduler.runNow(taskID: seedID)
    #expect(executedCount == 1)
    #expect(scheduler.recentRuns.count == 1)
    #expect(scheduler.recentRuns[0].status == .succeeded)
    #expect(scheduler.recentRuns[0].trigger == .manual)
    #expect(scheduler.recentRuns[0].summary == "参数=v1")

    scheduler.deleteTask(id: seedID)
    #expect(scheduler.tasks.isEmpty)

    scheduler.seedDefaultTaskIfNeeded({
        ScheduledTask(id: seedID, name: "不应复活", actionID: "test.echo")
    }, seedID: seedID)
    #expect(scheduler.tasks.isEmpty)

    // 验证 core.shell 动作可执行
    let shellTask = ScheduledTask(
        id: "shell.1",
        name: "Echo 命令",
        actionID: TaskScheduler.coreShellActionID,
        isEnabled: false,
        notifyPolicy: .never,
        parameters: ["command": "printf 'ironbowl-ok'"]
    )
    scheduler.saveTask(shellTask)
    await scheduler.runNow(taskID: "shell.1")
    let shellRun = scheduler.recentRuns.first(where: { $0.taskID == "shell.1" })
    #expect(shellRun?.status == .succeeded)
    #expect(shellRun?.detail.contains("ironbowl-ok") == true)
}
