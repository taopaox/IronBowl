import AppKit
import Foundation
import Observation

public enum SchedulerKeys {
    public static let seededIDs = SettingKey<[String]>("scheduler.seededIDs", default: [])
}

/// 定时任务调度判定结果。
public nonisolated enum DueDecision: Sendable, Equatable {
    case notDue
    case advanceOnly(nextRunAt: Date)
    case fire(trigger: TaskTrigger, scheduledFor: Date, slotKey: String, nextRunAt: Date?)
}

/// 通用定时任务调度引擎（仅主工作台启动，独立版应用不启动定时器）。
@Observable
public final class TaskScheduler {
    public nonisolated static let coreReminderActionID = "core.reminder"
    public nonisolated static let coreClockOutReminderActionID = "core.clockOutReminder"
    public nonisolated static let coreShellActionID = "core.shell"
    public nonisolated static let defaultClockOutReminderTaskID = "builtin.core.clockOutReminder"
    public nonisolated static let schedulerPluginID = "scheduler"

    /// 勾选「常驻不消失」时，若原本设为系统通知，强制改用右上角浮动卡片以确保不点不消失。
    public nonisolated static func resolveClockOutStyle(configured: ReminderStyle, keepVisible: Bool) -> ReminderStyle {
        (keepVisible && configured == .system) ? .cornerCard : configured
    }

    @ObservationIgnored private let store: TaskSchedulerStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let workCalendar: WorkCalendar
    @ObservationIgnored private let reminders: ReminderCenter
    @ObservationIgnored private let openPlugin: (String) -> Void
    @ObservationIgnored private let openSettings: (String?) -> Void

    @ObservationIgnored nonisolated(unsafe) private var timer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var snoozeTimers: [String: Timer] = [:]
    @ObservationIgnored private var actionsByID: [String: ScheduledTaskAction] = [:]

    public private(set) var tasks: [ScheduledTask] = []
    public private(set) var recentRuns: [ScheduledTaskRun] = []
    public private(set) var runningTaskIDs: Set<String> = []
    public private(set) var registeredActions: [ScheduledTaskAction] = []
    public private(set) var isStarted = false

    /// 到点后在此宽限秒数内视为正常准点触发，超出则按 misfirePolicy 判断是否补执行。
    public nonisolated static let onTimeGraceSeconds: TimeInterval = 120

    public init(
        database: AppDatabase,
        settings: SettingsStore,
        workCalendar: WorkCalendar,
        reminders: ReminderCenter,
        openPlugin: @escaping (String) -> Void = { _ in },
        openSettings: @escaping (String?) -> Void = { _ in }
    ) {
        self.store = TaskSchedulerStore(db: database)
        self.settings = settings
        self.workCalendar = workCalendar
        self.reminders = reminders
        self.openPlugin = openPlugin
        self.openSettings = openSettings

        store.markInterruptedRunsFailed(at: Date())
        tasks = store.allTasks()
        recentRuns = store.recentRuns(limit: 200)
        registerBuiltInActions()
    }

    deinit {
        timer?.invalidate()
        for snoozeTimer in snoozeTimers.values {
            snoozeTimer.invalidate()
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - 生命周期

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let now = Date()
        ensureNextRunsInitialized(now: now)

        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 3

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        Task { @MainActor [weak self] in
            self?.tick()
        }
    }

    public func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
        for snoozeTimer in snoozeTimers.values {
            snoozeTimer.invalidate()
        }
        snoozeTimers.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - 动作注册与内置默认任务

    public func register(action: ScheduledTaskAction) {
        actionsByID[action.id] = action
        rebuildRegisteredActionsList()
    }

    public func unregister(actionID: String) {
        actionsByID.removeValue(forKey: actionID)
        rebuildRegisteredActionsList()
    }

    public func action(id: String) -> ScheduledTaskAction? {
        actionsByID[id]
    }

    /// 首次安装或升级引入某内置默认任务时写入数据库；若用户之后手动删除，不会再自动重建。
    public func seedDefaultTaskIfNeeded(
        _ makeTask: () -> ScheduledTask,
        seedID: String,
        now: Date = Date()
    ) {
        var seeded = settings[SchedulerKeys.seededIDs]
        guard !seeded.contains(seedID) else { return }

        var task = makeTask()
        if !tasks.contains(where: { $0.id == task.id }) && store.task(id: task.id) == nil {
            if task.isEnabled {
                task.nextRunAt = task.schedule.nextRun(after: now, workCalendar: workCalendar)
            } else {
                task.nextRunAt = nil
            }
            task.createdAt = now
            task.updatedAt = now
            store.saveTask(task)
            tasks = store.allTasks()
        }

        seeded.append(seedID)
        settings[SchedulerKeys.seededIDs] = seeded
    }

    private func rebuildRegisteredActionsList() {
        registeredActions = actionsByID.values.sorted { lhs, rhs in
            let lIsCore = lhs.id.hasPrefix("core.")
            let rIsCore = rhs.id.hasPrefix("core.")
            if lIsCore != rIsCore { return !lIsCore }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func registerBuiltInActions() {
        register(action: ScheduledTaskAction(
            id: Self.coreReminderActionID,
            title: "定时桌面提醒",
            subtitle: "到点弹出自定义标题与内容的桌面提醒卡片或系统通知。",
            pluginID: nil,
            systemImage: "bell.badge",
            defaultName: "定时提醒",
            parameterSpecs: [
                ScheduledActionParameterSpec(
                    key: "title",
                    title: "提醒标题",
                    description: nil,
                    kind: .text(placeholder: "例如：站起来喝水休息一下"),
                    defaultValue: "定时提醒"
                ),
                ScheduledActionParameterSpec(
                    key: "message",
                    title: "提醒内容",
                    description: nil,
                    kind: .multiline(placeholder: "输入提醒正文内容"),
                    defaultValue: "到点啦，别忘了处理计划事项。"
                ),
            ]
        ) { [weak self] ctx in
            let title = ctx.string("title", default: ctx.task.name).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = ctx.string("message", default: "到点啦").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.isEmpty ? ctx.task.name : title
            let fallbackMessage = ctx.task.schedule.kind == .beforeWorkEnd
                ? "已到达\(ctx.task.schedule.summaryText)"
                : "已到达计划时间 \(ctx.task.schedule.timeText)"
            let resolvedMessage = message.isEmpty ? fallbackMessage : message
            let content = ReminderContent(
                id: "scheduler.task.\(ctx.task.id)",
                title: resolvedTitle,
                message: resolvedMessage,
                systemImage: "bell.badge",
                source: .scheduler,
                targetPluginID: Self.schedulerPluginID,
                isPersistent: ctx.task.notifyStyle != .system,
                actions: [
                    ReminderAction(id: "ok", title: "知道了", isPrimary: true) {},
                ]
            )
            self?.reminders.show(content, style: ctx.task.notifyStyle)
            return .succeeded(
                summary: "已发送桌面提醒：\(resolvedTitle)",
                detail: resolvedMessage,
                shouldNotifyOverride: false
            )
        })

        register(action: ScheduledTaskAction(
            id: Self.coreClockOutReminderActionID,
            title: "下班打卡提醒",
            subtitle: "到点弹出常驻桌面的下班打卡提醒卡片，点「已打卡」或「稍后提醒」前不会自动消失。",
            pluginID: nil,
            systemImage: "clock.badge.exclamationmark",
            defaultName: "打卡提醒",
            parameterSpecs: [
                ScheduledActionParameterSpec(
                    key: "title",
                    title: "提醒标题",
                    description: nil,
                    kind: .text(placeholder: "例如：下班打卡提醒"),
                    defaultValue: "下班打卡提醒"
                ),
                ScheduledActionParameterSpec(
                    key: "message",
                    title: "自定义提醒内容",
                    description: "留空时自动显示今日实际下班时间与剩余分钟。",
                    kind: .multiline(placeholder: "留空自动计算，例如：快到下班时间了，记得打卡。"),
                    defaultValue: ""
                ),
                ScheduledActionParameterSpec(
                    key: "keepVisible",
                    title: "常驻不消失",
                    description: "开启后强制使用桌面浮动卡片或中央弹框，点击按钮前不会自动消失。",
                    kind: .bool,
                    defaultValue: "true"
                ),
                ScheduledActionParameterSpec(
                    key: "snoozeMinutes",
                    title: "稍后提醒间隔",
                    description: "点击「稍后提醒」后再次弹窗等待的分钟数。",
                    kind: .int(min: 1, max: 30, step: 1, unit: "分钟"),
                    defaultValue: "5"
                ),
            ]
        ) { [weak self] ctx in
            guard let self else {
                return .failed(summary: "调度器不可用", detail: "TaskScheduler 已释放。")
            }
            let rawTitle = ctx.string("title", default: ctx.task.name).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = rawTitle.isEmpty ? ctx.task.name : rawTitle
            let customMessage = ctx.string("message")
            let keepVisible = ctx.bool("keepVisible", default: true)
            let snoozeMinutes = min(30, max(1, ctx.int("snoozeMinutes", default: 5)))

            self.cancelSnoozeReminder(taskID: ctx.task.id)
            let resolvedMessage = self.presentClockOutReminder(
                taskID: ctx.task.id,
                title: resolvedTitle,
                customMessage: customMessage,
                keepVisible: keepVisible,
                snoozeMinutes: snoozeMinutes,
                configuredStyle: ctx.task.notifyStyle,
                now: ctx.now
            )
            return .succeeded(
                summary: "已弹出打卡提醒：\(resolvedTitle)",
                detail: resolvedMessage,
                shouldNotifyOverride: false
            )
        })

        register(action: ScheduledTaskAction(
            id: Self.coreShellActionID,
            title: "执行终端命令",
            subtitle: "通过 zsh 登录环境运行本地脚本或命令，并记录输出与退出码。",
            pluginID: nil,
            systemImage: "terminal",
            defaultName: "定时脚本",
            parameterSpecs: [
                ScheduledActionParameterSpec(
                    key: "command",
                    title: "Shell 命令",
                    description: "使用 /bin/zsh -lc 执行。",
                    kind: .multiline(placeholder: "例如：echo \"hello\" && date"),
                    defaultValue: ""
                ),
                ScheduledActionParameterSpec(
                    key: "workingDirectory",
                    title: "工作目录",
                    description: "留空则使用默认目录。",
                    kind: .text(placeholder: "可选，如 /Users/yxhc/huanwei"),
                    defaultValue: ""
                ),
                ScheduledActionParameterSpec(
                    key: "timeoutSeconds",
                    title: "超时时长",
                    description: nil,
                    kind: .int(min: 5, max: 600, step: 5, unit: "秒"),
                    defaultValue: "60"
                ),
            ]
        ) { ctx in
            let command = ctx.string("command").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                return .failed(summary: "命令为空，无法执行", detail: "请在任务参数中填写需要执行的 Shell 命令。")
            }
            let rawCwd = ctx.string("workingDirectory").trimmingCharacters(in: .whitespacesAndNewlines)
            let cwdURL: URL?
            if !rawCwd.isEmpty {
                let expanded = (rawCwd as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                    return .failed(summary: "工作目录不存在", detail: "找不到目录：\(expanded)")
                }
                cwdURL = URL(fileURLWithPath: expanded)
            } else {
                cwdURL = nil
            }
            let timeout = TimeInterval(min(600, max(5, ctx.int("timeoutSeconds", default: 60))))
            do {
                let result = try await Shell.run("/bin/zsh", ["-lc", command], cwd: cwdURL, timeout: timeout)
                let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                var parts: [String] = ["退出码：\(result.status) · 耗时 \(String(format: "%.1f", result.duration)) 秒"]
                if !stdout.isEmpty { parts.append("标准输出：\n\(stdout.prefix(2000))") }
                if !stderr.isEmpty { parts.append("标准错误：\n\(stderr.prefix(1500))") }
                let detail = parts.joined(separator: "\n\n")
                if result.status == 0 {
                    let firstLine = stdout.split(separator: "\n").first.map(String.init)
                    let summary = firstLine.map { "命令执行成功：\($0.prefix(60))" } ?? "命令执行成功（耗时 \(String(format: "%.1f", result.duration)) 秒）"
                    return .succeeded(summary: summary, detail: detail)
                }
                return .failed(summary: "命令退出码 \(result.status)", detail: detail)
            } catch {
                return .failed(summary: "命令执行出错：\(error.localizedDescription)", detail: error.localizedDescription)
            }
        })
    }

    private func buildClockOutMessage(customMessage: String, now: Date) -> String {
        let trimmed = customMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let end = workCalendar.effectiveWorkEnd(on: now),
           let offWorkText = workCalendar.offWorkTimeText(on: now) {
            let remainingMinutes = Int(ceil(end.timeIntervalSince(now) / 60))
            if remainingMinutes > 0 {
                return "距离今日下班（\(offWorkText)）还有约 \(remainingMinutes) 分钟，请记得下班打卡。"
            }
            return "已到今日下班时间（\(offWorkText)），别忘了下班打卡！"
        }
        return "快到下班时间了，请记得下班打卡。"
    }

    private func presentClockOutReminder(
        taskID: String,
        title: String,
        customMessage: String,
        keepVisible: Bool,
        snoozeMinutes: Int,
        configuredStyle: ReminderStyle,
        now: Date = Date()
    ) -> String {
        let resolvedMessage = buildClockOutMessage(customMessage: customMessage, now: now)
        let resolvedStyle = Self.resolveClockOutStyle(configured: configuredStyle, keepVisible: keepVisible)
        let content = ReminderContent(
            id: "scheduler.clockout.\(taskID)",
            title: title,
            message: resolvedMessage,
            systemImage: "clock.badge.exclamationmark",
            source: .scheduler,
            targetPluginID: Self.schedulerPluginID,
            isPersistent: resolvedStyle != .system,
            actions: [
                ReminderAction(id: "snooze", title: "\(snoozeMinutes) 分钟后再提醒") { [weak self] in
                    self?.scheduleSnoozeReminder(taskID: taskID, minutes: snoozeMinutes) { [weak self] in
                        guard let self else { return }
                        _ = self.presentClockOutReminder(
                            taskID: taskID,
                            title: title,
                            customMessage: customMessage,
                            keepVisible: keepVisible,
                            snoozeMinutes: snoozeMinutes,
                            configuredStyle: configuredStyle
                        )
                    }
                },
                ReminderAction(id: "done", title: "已打卡", isPrimary: true) { [weak self] in
                    self?.cancelSnoozeReminder(taskID: taskID)
                },
            ]
        )
        reminders.show(content, style: resolvedStyle)
        return resolvedMessage
    }

    private func scheduleSnoozeReminder(taskID: String, minutes: Int, show: @escaping @MainActor () -> Void) {
        cancelSnoozeReminder(taskID: taskID)
        let interval = TimeInterval(max(1, minutes) * 60)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.snoozeTimers.removeValue(forKey: taskID)
                show()
            }
        }
        timer.tolerance = min(5, interval * 0.1)
        snoozeTimers[taskID] = timer
    }

    private func cancelSnoozeReminder(taskID: String) {
        snoozeTimers.removeValue(forKey: taskID)?.invalidate()
    }

    // MARK: - 任务管理

    public func saveTask(_ incoming: ScheduledTask, now: Date = Date()) {
        var task = incoming
        task.name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.name.isEmpty {
            task.name = action(id: task.actionID)?.defaultName ?? "未命名定时任务"
        }
        if !task.isEnabled {
            cancelSnoozeReminder(taskID: task.id)
        }
        task.updatedAt = now
        task.nextRunAt = task.isEnabled ? task.schedule.nextRun(after: now, workCalendar: workCalendar) : nil
        store.saveTask(task)
        tasks = store.allTasks()
    }

    public func setEnabled(taskID: String, enabled: Bool, now: Date = Date()) {
        guard var task = tasks.first(where: { $0.id == taskID }) else { return }
        if !enabled {
            cancelSnoozeReminder(taskID: taskID)
        }
        task.isEnabled = enabled
        task.updatedAt = now
        task.nextRunAt = enabled ? task.schedule.nextRun(after: now, workCalendar: workCalendar) : nil
        store.saveTask(task)
        tasks = store.allTasks()
    }

    public func deleteTask(id: String, deleteRuns: Bool = false) {
        cancelSnoozeReminder(taskID: id)
        store.deleteTask(id: id, deleteRuns: deleteRuns)
        tasks = store.allTasks()
        if deleteRuns {
            recentRuns = store.recentRuns(limit: 200)
        }
    }

    public func clearRuns(taskID: String? = nil) {
        store.clearRuns(taskID: taskID)
        recentRuns = store.recentRuns(limit: 200)
    }

    /// 当工作日历规则或节假日发生变动时，重新计算启用任务的下一次触发时间。
    public func recomputeNextRuns(now: Date = Date()) {
        var changed = false
        for var task in tasks where task.isEnabled {
            let next = task.schedule.nextRun(after: now, workCalendar: workCalendar)
            if task.nextRunAt != next {
                task.nextRunAt = next
                task.updatedAt = now
                store.saveTask(task)
                changed = true
            }
        }
        if changed {
            tasks = store.allTasks()
        }
    }

    private func ensureNextRunsInitialized(now: Date) {
        var changed = false
        for var task in tasks where task.isEnabled && task.nextRunAt == nil {
            task.nextRunAt = task.schedule.nextRun(after: now, workCalendar: workCalendar)
            task.updatedAt = now
            store.saveTask(task)
            changed = true
        }
        if changed {
            tasks = store.allTasks()
        }
    }

    // MARK: - 调度判定与执行

    public nonisolated static func evaluateDue(
        task: ScheduledTask,
        now: Date,
        isWorkday: (Date) -> Bool,
        workEndOnDay: ((Date) -> Date?)? = nil,
        calendar: Calendar = .current
    ) -> DueDecision {
        guard task.isEnabled, let scheduledFor = task.nextRunAt else { return .notDue }
        guard now >= scheduledFor else { return .notDue }

        let next = task.schedule.nextRun(
            after: now,
            isWorkday: isWorkday,
            workEndOnDay: workEndOnDay,
            calendar: calendar
        )
        let slotKey = task.schedule.slotKey(for: scheduledFor, calendar: calendar)
        if task.lastFiredSlot == slotKey {
            if let next { return .advanceOnly(nextRunAt: next) }
            return .notDue
        }

        let delay = now.timeIntervalSince(scheduledFor)
        if delay <= onTimeGraceSeconds {
            return .fire(trigger: .scheduled, scheduledFor: scheduledFor, slotKey: slotKey, nextRunAt: next)
        }

        if task.misfirePolicy == .runIfMissedToday,
           task.schedule.kind != .interval,
           calendar.isDate(now, inSameDayAs: scheduledFor) {
            if (task.schedule.kind == .workdays || task.schedule.kind == .beforeWorkEnd) && !isWorkday(now) {
                if let next { return .advanceOnly(nextRunAt: next) }
                return .notDue
            }
            return .fire(trigger: .misfireCatchUp, scheduledFor: scheduledFor, slotKey: slotKey, nextRunAt: next)
        }

        if let next {
            return .advanceOnly(nextRunAt: next)
        }
        return .notDue
    }

    public func tick(now: Date = Date()) {
        let currentTasks = tasks
        var updatedAny = false

        for task in currentTasks {
            guard !runningTaskIDs.contains(task.id) else { continue }
            let decision = Self.evaluateDue(
                task: task,
                now: now,
                isWorkday: { self.workCalendar.isWorkday($0) },
                workEndOnDay: { self.workCalendar.effectiveWorkEnd(on: $0) }
            )
            switch decision {
            case .notDue:
                continue
            case .advanceOnly(let nextRunAt):
                var mutable = task
                mutable.nextRunAt = nextRunAt
                mutable.updatedAt = now
                store.saveTask(mutable)
                updatedAny = true
            case .fire(let trigger, let scheduledFor, let slotKey, let nextRunAt):
                var mutable = task
                mutable.lastFiredSlot = slotKey
                mutable.nextRunAt = nextRunAt
                mutable.updatedAt = now
                store.saveTask(mutable)
                runningTaskIDs.insert(task.id)
                updatedAny = true
                Task { @MainActor [weak self] in
                    await self?.execute(task: mutable, trigger: trigger, scheduledFor: scheduledFor)
                }
            }
        }

        if updatedAny {
            tasks = store.allTasks()
        }
    }

    public func runNow(taskID: String, now: Date = Date()) async {
        guard let task = tasks.first(where: { $0.id == taskID }),
              !runningTaskIDs.contains(taskID) else {
            return
        }
        runningTaskIDs.insert(taskID)
        await execute(task: task, trigger: .manual, scheduledFor: now)
    }

    private func execute(task: ScheduledTask, trigger: TaskTrigger, scheduledFor: Date) async {
        defer {
            runningTaskIDs.remove(task.id)
        }

        let startedAt = Date()
        let runRecord = ScheduledTaskRun(
            taskID: task.id,
            taskName: task.name,
            actionID: task.actionID,
            trigger: trigger,
            status: .running,
            startedAt: startedAt,
            summary: "正在执行…"
        )
        let runID = store.insertRun(runRecord)
        recentRuns = store.recentRuns(limit: 200)

        let outcome: ScheduledTaskOutcome
        if let action = actionsByID[task.actionID] {
            var mergedParams = action.defaultParameters
            for (k, v) in task.parameters {
                mergedParams[k] = v
            }
            let ctx = ScheduledTaskExecutionContext(
                task: task,
                trigger: trigger,
                scheduledFor: scheduledFor,
                now: startedAt,
                parameters: mergedParams
            )
            outcome = await action.execute(ctx)
        } else {
            outcome = .failed(
                summary: "未找到执行动作（\(task.actionID)），对应插件可能已停用",
                detail: "请先在「设置 → 通用 → 功能插件」启用对应的插件后重试。",
                actionTitle: "打开设置",
                actionSettingsPageID: "general"
            )
        }

        let finishedAt = Date()
        if let runID {
            store.updateRun(
                id: runID,
                status: outcome.status,
                finishedAt: finishedAt,
                summary: outcome.summary,
                detail: outcome.detail
            )
        }
        store.pruneRuns(keepingLatest: 200)

        var latestTask = store.task(id: task.id) ?? task
        latestTask.lastRunAt = finishedAt
        latestTask.lastStatus = outcome.status
        latestTask.lastSummary = outcome.summary
        latestTask.updatedAt = finishedAt
        store.saveTask(latestTask)

        tasks = store.allTasks()
        recentRuns = store.recentRuns(limit: 200)

        notifyIfNeeded(task: latestTask, outcome: outcome)
    }

    private func notifyIfNeeded(task: ScheduledTask, outcome: ScheduledTaskOutcome) {
        let shouldNotify: Bool
        if let override = outcome.shouldNotifyOverride {
            shouldNotify = override
        } else {
            switch task.notifyPolicy {
            case .onSuccessAndFailure:
                shouldNotify = outcome.status == .succeeded || outcome.status == .failed
            case .onFailureOnly:
                shouldNotify = outcome.status == .failed
            case .always:
                shouldNotify = true
            case .never:
                shouldNotify = false
            }
        }
        guard shouldNotify else { return }

        let titlePrefix: String
        let icon: String
        switch outcome.status {
        case .succeeded:
            titlePrefix = "定时任务已完成"
            icon = "checkmark.circle.fill"
        case .skipped:
            titlePrefix = "定时任务提醒"
            icon = "exclamationmark.circle.fill"
        case .failed:
            titlePrefix = "定时任务执行失败"
            icon = "xmark.octagon.fill"
        case .running:
            return
        }

        let primaryAction: ReminderAction
        if let settingsPageID = outcome.actionSettingsPageID {
            let label = outcome.actionTitle ?? "去设置"
            primaryAction = ReminderAction(id: "open", title: label, isPrimary: true) { [weak self] in
                self?.openSettings(settingsPageID)
            }
        } else if let pluginID = outcome.actionPluginID {
            let label = outcome.actionTitle ?? "查看详情"
            primaryAction = ReminderAction(id: "open", title: label, isPrimary: true) { [weak self] in
                self?.openPlugin(pluginID)
            }
        } else {
            let label = outcome.actionTitle ?? "查看定时任务"
            primaryAction = ReminderAction(id: "open", title: label, isPrimary: true) { [weak self] in
                self?.openPlugin(Self.schedulerPluginID)
            }
        }

        let content = ReminderContent(
            id: "scheduler.result.\(task.id)",
            title: "\(titlePrefix)：\(task.name)",
            message: outcome.summary,
            systemImage: icon,
            source: .scheduler,
            targetPluginID: outcome.actionSettingsPageID == nil ? (outcome.actionPluginID ?? Self.schedulerPluginID) : nil,
            targetSettingsPage: outcome.actionSettingsPageID,
            actions: [
                ReminderAction(id: "close", title: "知道了") {},
                primaryAction,
            ]
        )
        reminders.show(content, style: task.notifyStyle)
    }

    // MARK: - 统计与展示辅助

    public var enabledTaskCount: Int {
        tasks.filter(\.isEnabled).count
    }

    public func nextUpcomingTask(now: Date = Date()) -> (task: ScheduledTask, fireAt: Date)? {
        tasks
            .compactMap { task -> (ScheduledTask, Date)? in
                guard task.isEnabled, let fireAt = task.nextRunAt, fireAt > now else { return nil }
                return (task, fireAt)
            }
            .min { $0.1 < $1.1 }
    }

    public func todayRunCounts(now: Date = Date()) -> (succeeded: Int, skipped: Int, failed: Int) {
        let cal = Calendar.current
        var s = 0, k = 0, f = 0
        for run in recentRuns where cal.isDate(run.startedAt, inSameDayAs: now) {
            switch run.status {
            case .succeeded: s += 1
            case .skipped: k += 1
            case .failed: f += 1
            case .running: break
            }
        }
        return (s, k, f)
    }
}
