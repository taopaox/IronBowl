import Foundation

/// 定时任务调度周期类型。
public nonisolated enum TaskScheduleKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case workdays
    case daily
    case weekly
    case interval

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .workdays: "仅工作日"
        case .daily: "每天"
        case .weekly: "每周指定日期"
        case .interval: "每隔固定分钟"
        }
    }

    public var detail: String {
        switch self {
        case .workdays: "跟随饭碗工作日历，自动跳过周末与法定节假日、包含调休补班。"
        case .daily: "每天固定时间执行，不区分工作日与节假日。"
        case .weekly: "按选中的星期几在固定时间执行。"
        case .interval: "按固定分钟间隔循环执行。"
        }
    }
}

/// 定时任务调度规则。
public nonisolated struct TaskSchedule: Codable, Sendable, Hashable {
    public var kind: TaskScheduleKind
    public var hour: Int
    public var minute: Int
    /// Calendar.weekday（1=周日, 2=周一 ... 7=周六）。
    public var weekdays: [Int]
    public var intervalMinutes: Int

    public init(
        kind: TaskScheduleKind = .workdays,
        hour: Int = 17,
        minute: Int = 0,
        weekdays: [Int] = [2, 3, 4, 5, 6],
        intervalMinutes: Int = 60
    ) {
        self.kind = kind
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        let validWeekdays = weekdays.filter { (1...7).contains($0) }
        self.weekdays = validWeekdays.isEmpty ? [2, 3, 4, 5, 6] : Array(Set(validWeekdays)).sorted()
        self.intervalMinutes = max(1, intervalMinutes)
    }

    public var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public var summaryText: String {
        switch kind {
        case .workdays:
            return "仅工作日 \(timeText)"
        case .daily:
            return "每天 \(timeText)"
        case .weekly:
            let names = [2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六", 1: "日"]
            let order = [2, 3, 4, 5, 6, 7, 1]
            let picked = order.filter { weekdays.contains($0) }.compactMap { names[$0] }
            let dayText = picked.isEmpty ? "一至五" : picked.joined(separator: "、")
            return "每周\(dayText) \(timeText)"
        case .interval:
            if intervalMinutes >= 60, intervalMinutes % 60 == 0 {
                return "每隔 \(intervalMinutes / 60) 小时"
            }
            return "每隔 \(intervalMinutes) 分钟"
        }
    }

    /// 计算严格晚于 `reference` 的下一次计划执行时间。
    public func nextRun(
        after reference: Date,
        isWorkday: (Date) -> Bool,
        calendar: Calendar = .current
    ) -> Date? {
        switch kind {
        case .interval:
            return reference.addingTimeInterval(TimeInterval(max(1, intervalMinutes) * 60))
        case .daily:
            let startDay = calendar.startOfDay(for: reference)
            for offset in 0..<3 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
                else { continue }
                if candidate > reference { return candidate }
            }
            return nil
        case .workdays:
            let startDay = calendar.startOfDay(for: reference)
            for offset in 0..<366 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                      isWorkday(day),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
                else { continue }
                if candidate > reference { return candidate }
            }
            return nil
        case .weekly:
            let valid = weekdays.filter { (1...7).contains($0) }
            let targetWeekdays = Set(valid.isEmpty ? [2, 3, 4, 5, 6] : valid)
            let startDay = calendar.startOfDay(for: reference)
            for offset in 0..<14 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startDay),
                      targetWeekdays.contains(calendar.component(.weekday, from: day)),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
                else { continue }
                if candidate > reference { return candidate }
            }
            return nil
        }
    }

    @MainActor
    public func nextRun(
        after reference: Date,
        workCalendar: WorkCalendar,
        calendar: Calendar = .current
    ) -> Date? {
        nextRun(after: reference, isWorkday: { workCalendar.isWorkday($0) }, calendar: calendar)
    }

    /// 生成时间槽唯一标识，用于防止重启或反复 tick 时重复触发同一槽位。
    public func slotKey(for fireDate: Date, calendar: Calendar = .current) -> String {
        switch kind {
        case .interval:
            return "interval:\(Int(fireDate.timeIntervalSince1970))"
        case .workdays, .daily, .weekly:
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            return String(
                format: "%04d-%02d-%02d %02d:%02d",
                c.year ?? 0,
                c.month ?? 0,
                c.day ?? 0,
                c.hour ?? 0,
                c.minute ?? 0
            )
        }
    }
}

/// 错过预定触发时间（如电脑休眠、应用关闭）时的补执行策略。
public nonisolated enum MisfirePolicy: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case runIfMissedToday
    case skip

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .runIfMissedToday: "当天错过则补执行一次"
        case .skip: "错过则跳过，等下次"
        }
    }

    public var detail: String {
        switch self {
        case .runIfMissedToday: "若唤醒或重启时仍在同一天（工作日任务还需当天仍是工作日），自动补跑一次。"
        case .skip: "超过触发窗口后不再补跑，直接推进到下一次计划时间。"
        }
    }
}

/// 任务执行完成后的桌面提醒策略。
public nonisolated enum TaskNotifyPolicy: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case onSuccessAndFailure
    case onFailureOnly
    case always
    case never

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onSuccessAndFailure: "成功或失败时通知"
        case .onFailureOnly: "仅失败时通知"
        case .always: "每次都通知（含跳过）"
        case .never: "不发送通知"
        }
    }

    public var detail: String {
        switch self {
        case .onSuccessAndFailure: "任务成功执行或失败时弹窗提醒；例如“今日已提交而跳过”则静默记录不打扰。"
        case .onFailureOnly: "平时静默运行，仅在执行失败时弹窗提醒。"
        case .always: "无论成功、跳过还是失败都弹出提醒。"
        case .never: "仅写入执行记录，不弹出任何桌面通知。"
        }
    }
}

/// 任务触发来源。
public nonisolated enum TaskTrigger: String, Codable, Sendable, Hashable {
    case scheduled
    case misfireCatchUp
    case manual

    public var displayName: String {
        switch self {
        case .scheduled: "定时触发"
        case .misfireCatchUp: "错过补执行"
        case .manual: "手动运行"
        }
    }
}

/// 单次执行状态。
public nonisolated enum TaskRunStatus: String, Codable, Sendable, Hashable {
    case running
    case succeeded
    case skipped
    case failed

    public var displayName: String {
        switch self {
        case .running: "运行中"
        case .succeeded: "成功"
        case .skipped: "已跳过"
        case .failed: "失败"
        }
    }
}

/// 持久化的定时任务定义与最近调度状态。
public nonisolated struct ScheduledTask: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var actionID: String
    public var isEnabled: Bool
    public var schedule: TaskSchedule
    public var misfirePolicy: MisfirePolicy
    public var notifyPolicy: TaskNotifyPolicy
    public var notifyStyle: ReminderStyle
    public var parameters: [String: String]
    public var nextRunAt: Date?
    public var lastRunAt: Date?
    public var lastFiredSlot: String?
    public var lastStatus: TaskRunStatus?
    public var lastSummary: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        actionID: String,
        isEnabled: Bool = true,
        schedule: TaskSchedule = TaskSchedule(),
        misfirePolicy: MisfirePolicy = .runIfMissedToday,
        notifyPolicy: TaskNotifyPolicy = .onSuccessAndFailure,
        notifyStyle: ReminderStyle = .cornerCard,
        parameters: [String: String] = [:],
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastFiredSlot: String? = nil,
        lastStatus: TaskRunStatus? = nil,
        lastSummary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.actionID = actionID
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.misfirePolicy = misfirePolicy
        self.notifyPolicy = notifyPolicy
        self.notifyStyle = notifyStyle
        self.parameters = parameters
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastFiredSlot = lastFiredSlot
        self.lastStatus = lastStatus
        self.lastSummary = lastSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 定时任务历史执行记录。
public nonisolated struct ScheduledTaskRun: Codable, Sendable, Identifiable, Hashable {
    public var id: Int64?
    public var taskID: String
    public var taskName: String
    public var actionID: String
    public var trigger: TaskTrigger
    public var status: TaskRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var summary: String
    public var detail: String

    public init(
        id: Int64? = nil,
        taskID: String,
        taskName: String,
        actionID: String,
        trigger: TaskTrigger,
        status: TaskRunStatus,
        startedAt: Date,
        finishedAt: Date? = nil,
        summary: String = "",
        detail: String = ""
    ) {
        self.id = id
        self.taskID = taskID
        self.taskName = taskName
        self.actionID = actionID
        self.trigger = trigger
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.detail = detail
    }
}

/// 动作参数定义，供定时任务编辑器动态渲染表单控件。
public nonisolated struct ScheduledActionParameterSpec: Sendable, Identifiable, Hashable {
    public nonisolated struct Choice: Sendable, Hashable {
        public let value: String
        public let title: String
        public let subtitle: String?

        public init(value: String, title: String, subtitle: String? = nil) {
            self.value = value
            self.title = title
            self.subtitle = subtitle
        }
    }

    public nonisolated enum Kind: Sendable, Hashable {
        case bool
        case text(placeholder: String)
        case multiline(placeholder: String)
        case int(min: Int, max: Int, step: Int, unit: String)
        case choice([Choice])
    }

    public var id: String { key }
    public let key: String
    public let title: String
    public let description: String?
    public let kind: Kind
    public let defaultValue: String

    public init(
        key: String,
        title: String,
        description: String? = nil,
        kind: Kind,
        defaultValue: String
    ) {
        self.key = key
        self.title = title
        self.description = description
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

/// 定时任务单次执行结果。
public nonisolated struct ScheduledTaskOutcome: Sendable, Hashable {
    public var status: TaskRunStatus
    public var summary: String
    public var detail: String
    /// 非 nil 时覆盖任务的 notifyPolicy（例如“无提交跳过时强制弹窗提醒”）。
    public var shouldNotifyOverride: Bool?
    public var actionTitle: String?
    public var actionPluginID: String?
    public var actionSettingsPageID: String?

    public init(
        status: TaskRunStatus,
        summary: String,
        detail: String = "",
        shouldNotifyOverride: Bool? = nil,
        actionTitle: String? = nil,
        actionPluginID: String? = nil,
        actionSettingsPageID: String? = nil
    ) {
        self.status = status
        self.summary = summary
        self.detail = detail
        self.shouldNotifyOverride = shouldNotifyOverride
        self.actionTitle = actionTitle
        self.actionPluginID = actionPluginID
        self.actionSettingsPageID = actionSettingsPageID
    }

    public static func succeeded(
        summary: String,
        detail: String = "",
        shouldNotifyOverride: Bool? = nil,
        actionTitle: String? = nil,
        actionPluginID: String? = nil,
        actionSettingsPageID: String? = nil
    ) -> ScheduledTaskOutcome {
        ScheduledTaskOutcome(
            status: .succeeded,
            summary: summary,
            detail: detail,
            shouldNotifyOverride: shouldNotifyOverride,
            actionTitle: actionTitle,
            actionPluginID: actionPluginID,
            actionSettingsPageID: actionSettingsPageID
        )
    }

    public static func skipped(
        summary: String,
        detail: String = "",
        shouldNotifyOverride: Bool? = nil,
        actionTitle: String? = nil,
        actionPluginID: String? = nil,
        actionSettingsPageID: String? = nil
    ) -> ScheduledTaskOutcome {
        ScheduledTaskOutcome(
            status: .skipped,
            summary: summary,
            detail: detail,
            shouldNotifyOverride: shouldNotifyOverride,
            actionTitle: actionTitle,
            actionPluginID: actionPluginID,
            actionSettingsPageID: actionSettingsPageID
        )
    }

    public static func failed(
        summary: String,
        detail: String = "",
        shouldNotifyOverride: Bool? = nil,
        actionTitle: String? = nil,
        actionPluginID: String? = nil,
        actionSettingsPageID: String? = nil
    ) -> ScheduledTaskOutcome {
        ScheduledTaskOutcome(
            status: .failed,
            summary: summary,
            detail: detail,
            shouldNotifyOverride: shouldNotifyOverride,
            actionTitle: actionTitle,
            actionPluginID: actionPluginID,
            actionSettingsPageID: actionSettingsPageID
        )
    }
}

/// 传入动作执行器的上下文。
public nonisolated struct ScheduledTaskExecutionContext: Sendable {
    public let task: ScheduledTask
    public let trigger: TaskTrigger
    public let scheduledFor: Date
    public let now: Date
    public let parameters: [String: String]

    public init(
        task: ScheduledTask,
        trigger: TaskTrigger,
        scheduledFor: Date,
        now: Date,
        parameters: [String: String]
    ) {
        self.task = task
        self.trigger = trigger
        self.scheduledFor = scheduledFor
        self.now = now
        self.parameters = parameters
    }

    public func string(_ key: String, default fallback: String = "") -> String {
        parameters[key] ?? fallback
    }

    public func bool(_ key: String, default fallback: Bool = false) -> Bool {
        guard let raw = parameters[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return fallback
        }
        switch raw {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return fallback
        }
    }

    public func int(_ key: String, default fallback: Int) -> Int {
        guard let raw = parameters[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw)
        else { return fallback }
        return value
    }
}

/// 可被定时调度器执行的动作描述。
public struct ScheduledTaskAction: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let pluginID: String?
    public let systemImage: String
    public let defaultName: String
    public let parameterSpecs: [ScheduledActionParameterSpec]
    public let execute: @MainActor (ScheduledTaskExecutionContext) async -> ScheduledTaskOutcome

    public init(
        id: String,
        title: String,
        subtitle: String,
        pluginID: String? = nil,
        systemImage: String,
        defaultName: String,
        parameterSpecs: [ScheduledActionParameterSpec] = [],
        execute: @escaping @MainActor (ScheduledTaskExecutionContext) async -> ScheduledTaskOutcome
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.pluginID = pluginID
        self.systemImage = systemImage
        self.defaultName = defaultName
        self.parameterSpecs = parameterSpecs
        self.execute = execute
    }

    public var defaultParameters: [String: String] {
        Dictionary(uniqueKeysWithValues: parameterSpecs.map { ($0.key, $0.defaultValue) })
    }
}
