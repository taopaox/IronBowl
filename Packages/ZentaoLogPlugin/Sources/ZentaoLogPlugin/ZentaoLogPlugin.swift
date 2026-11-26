import Foundation
import IronBowlKit
import SwiftUI

/// 禅道日志插件。
public final class ZentaoLogPlugin: IronBowlPlugin {
    public static let pluginID = "zentao.log"
    public static let autoSubmitActionID = "zentao.autoSubmitLog"
    public static let defaultAutoSubmitTaskID = "builtin.zentao.dailyAutoSubmit"
    public let id = ZentaoLogPlugin.pluginID
    public let title = "禅道日志"
    public let sidebarTitle = "日报"
    public let sidebarSection: String? = "汇报"
    public let systemImage = "square.and.pencil"
    public var migrations: [DatabaseMigration] { LogMigrations.all }

    public var sidebarBadge: SidebarBadge? {
        guard let model, model.isConfigured else { return nil }
        let today = Date()
        guard model.context.workCalendar.isWorkday(today), !model.todaySubmitted else { return nil }
        if model.pendingHours(on: today) > 0 {
            return SidebarBadge("草稿", color: DS.warning)
        }
        return SidebarBadge("今日未写", color: DS.danger)
    }

    var model: LogModel?
    var scheduler: LogReminderScheduler?
    private var pluginContext: PluginContext?

    public init() {}

    public func start(context: PluginContext) {
        self.pluginContext = context
        let model = LogModel(context: context)
        self.model = model
        let scheduler = LogReminderScheduler(model: model)
        self.scheduler = scheduler
        scheduler.start()
        registerScheduledActions(context: context, model: model)
    }

    public func stop() {
        pluginContext?.scheduler.unregister(actionID: Self.autoSubmitActionID)
        pluginContext = nil
        scheduler?.stop()
        scheduler = nil
        model = nil
    }

    private func registerScheduledActions(context: PluginContext, model: LogModel) {
        context.scheduler.register(action: ScheduledTaskAction(
            id: Self.autoSubmitActionID,
            title: "自动生成并提交今日禅道日志",
            subtitle: "检查今日是否已提交；未提交时自动扫描 Git、生成草稿并写入禅道。",
            pluginID: Self.pluginID,
            systemImage: "square.and.pencil",
            defaultName: "每日自动生成并提交禅道日志",
            parameterSpecs: [
                ScheduledActionParameterSpec(
                    key: "draftStrategy",
                    title: "已有未提交草稿时",
                    description: "触发时如果今天已经存在尚未提交的草稿，如何处理。",
                    kind: .choice([
                        .init(value: AutoLogDraftStrategy.regenerate.rawValue, title: "重新扫描并生成覆盖后提交", subtitle: "拉取最新 Git 提交重新生成草稿并提交（推荐）。"),
                        .init(value: AutoLogDraftStrategy.submitExisting.rawValue, title: "直接提交已有草稿", subtitle: "不再重新扫描和调用 AI，直接提交现有草稿。"),
                        .init(value: AutoLogDraftStrategy.skip.rawValue, title: "保留草稿并跳过", subtitle: "不覆盖手动编辑中的草稿，等手动确认提交。"),
                    ]),
                    defaultValue: AutoLogDraftStrategy.regenerate.rawValue
                ),
                ScheduledActionParameterSpec(
                    key: "allowFallbackOnAIFailure",
                    title: "AI 失败时使用回退文本自动提交",
                    description: "关闭后，若 AI 调用失败则只保存草稿并弹窗提醒，不自动提交。",
                    kind: .bool,
                    defaultValue: "true"
                ),
                ScheduledActionParameterSpec(
                    key: "requireMappedTask",
                    title: "命中兜底任务时暂停自动提交",
                    description: "开启后，如果存在未关联项目的仓库落到兜底任务，仅保存草稿并提醒人工确认。",
                    kind: .bool,
                    defaultValue: "false"
                ),
            ]
        ) { [weak model] ctx in
            guard let model else {
                return .failed(summary: "禅道日志插件未就绪", detail: "请先在设置中启用「禅道日志」插件。")
            }
            let strategy = AutoLogDraftStrategy(rawValue: ctx.string("draftStrategy", default: AutoLogDraftStrategy.regenerate.rawValue)) ?? .regenerate
            let options = AutoSubmitLogOptions(
                draftStrategy: strategy,
                allowFallbackOnAIFailure: ctx.bool("allowFallbackOnAIFailure", default: true),
                requireMappedTask: ctx.bool("requireMappedTask", default: false)
            )
            return await model.autoGenerateAndSubmitToday(options: options, now: ctx.now)
        })

        context.scheduler.seedDefaultTaskIfNeeded({
            ScheduledTask(
                id: Self.defaultAutoSubmitTaskID,
                name: "每日自动生成并提交禅道日志",
                actionID: Self.autoSubmitActionID,
                isEnabled: true,
                schedule: TaskSchedule(kind: .workdays, hour: 17, minute: 0),
                misfirePolicy: .runIfMissedToday,
                notifyPolicy: .onSuccessAndFailure,
                notifyStyle: context.settings[LogKeys.reminderStyle],
                parameters: [
                    "draftStrategy": AutoLogDraftStrategy.regenerate.rawValue,
                    "allowFallbackOnAIFailure": "true",
                    "requireMappedTask": "false",
                ]
            )
        }, seedID: Self.defaultAutoSubmitTaskID)
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(LogView(model: model))
    }

    public static let settingsAccountID = "zentao.account"
    public static let settingsReposID = "zentao.repos"

    public var settingsPages: [SettingsPage] {
        guard let model, let scheduler else { return [] }
        return [
            SettingsPage(id: Self.settingsAccountID, title: "禅道账号", systemImage: "person.crop.circle") { AnyView(ZentaoAccountSettings(model: model)) },
            SettingsPage(id: Self.settingsReposID, title: "仓库与映射", systemImage: "folder") { AnyView(RepoSettings(model: model)) },
            SettingsPage(id: "zentao.generate", title: "日志生成", systemImage: "sparkles") { AnyView(GenerateSettings(model: model)) },
            SettingsPage(id: "zentao.reminder", title: "日志提醒", systemImage: "bell") { AnyView(ReminderSettings(model: model, scheduler: scheduler)) },
        ]
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "zentao.generate", title: "生成今日日志", systemImage: "sparkles") {
                model.context.openPlugin(ZentaoLogPlugin.pluginID)
                Task {
                    await model.select(date: Date())
                    await model.loadTasks()
                    await model.generate()
                }
            },
            QuickAction(id: "zentao.open", title: "看今天的提交", systemImage: "arrow.triangle.branch") {
                model.context.openPlugin(ZentaoLogPlugin.pluginID)
            },
            QuickAction(id: "zentao.settings", title: "仓库映射", systemImage: "folder") {
                model.context.openSettings(Self.settingsReposID)
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(id: "zentao.today", label: "今日日志",
                     value: {
                         let h = model.recordedHours(on: Date())
                         return h > 0 ? "已写 \(hoursText(h))h" : (model.todaySubmitted ? "已提交" : "未写")
                     },
                     detail: { model.todayCommitCount.map { "今天 \($0) 次提交" } },
                     action: { model.context.openPlugin(ZentaoLogPlugin.pluginID) }),
        ]
    }

    public func handleHomeInput(_ text: String) async -> String? {
        guard let model else { return nil }
        return await model.addFromSentence(text)
    }

    public var menuBarItems: [MenuBarItem] {
        guard let model, let scheduler else { return [] }
        return [
            MenuBarItem(id: "zentao.status", title: "今天的日志状态（✓ 已写 / ● 未写）") {
                model.todaySubmitted ? "✓" : (model.context.workCalendar.isWorkday(Date()) ? "●" : nil)
            },
            MenuBarItem(id: "zentao.commits", title: "今天的提交数") {
                model.todayCommitCount.map { "\($0)次" }
            },
            MenuBarItem(id: "zentao.hours", title: "今天的工时") {
                let recorded = model.recordedHours(on: Date())
                let target = model.targetHours(on: Date())
                if recorded > 0 {
                    return target > recorded
                        ? "已写 \(hoursText(recorded))/\(hoursText(target))h"
                        : "已写 \(hoursText(recorded))h"
                }
                return "需填 \(hoursText(target))h"
            },
            MenuBarItem(id: "zentao.nextReminder", title: "离下次提醒还有多久") {
                scheduler.nextReminder().map { "提醒 " + countdown(to: $0) }
            },
        ]
    }
}

/// 日志提醒调度：每 20 秒检查一次是否到点。
final class LogReminderScheduler {
    let model: LogModel
    private var timer: Timer?
    private var scanTimer: Timer?
    private var fired = Set<String>()
    private var snoozeUntil: Date?
    private static let reminderID = "zentao.log.reminder"

    init(model: LogModel) { self.model = model }

    var settings: SettingsStore { model.settings }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 5
        configureScanTimer()
        if settings[LogKeys.scanMode] != .manualOnly {
            Task { await model.scanTodayCount() }
        }
        if model.isConfigured {
            Task { await model.loadRecentRecorded() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scanTimer?.invalidate()
        scanTimer = nil
        snoozeUntil = nil
        model.context.reminders.dismiss(id: Self.reminderID)
    }

    /// 定时扫描（只在"按需 + 定时"模式下）。
    func configureScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
        guard settings[LogKeys.scanMode] == .onDemandPlusInterval else { return }
        let interval = TimeInterval(max(5, settings[LogKeys.scanInterval]) * 60)
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.model.scanTodayCount() }
            }
        }
    }

    private var lastScanConfig = ""

    func tick(now: Date = Date()) {
        // 设置变了就重新配置定时扫描。
        let config = "\(settings[LogKeys.scanMode].rawValue)-\(settings[LogKeys.scanInterval])"
        if config != lastScanConfig {
            lastScanConfig = config
            configureScanTimer()
        }

        let today = WorkCalendar.dayString(now)
        model.refreshTodaySubmitted()
        guard shouldRemind(today: today, now: now) else { return }

        if let s = snoozeUntil {
            if now >= s {
                snoozeUntil = nil
                show(style: settings[LogKeys.reminderStyle])
            }
            return
        }
        for time in settings[LogKeys.reminderTimes].sorted() {
            let key = "\(today) \(time)"
            guard !fired.contains(key), let at = Self.time(time, on: now), now >= at else { continue }
            // 同一天之前的时间点一起标记，避免启动时连弹多次。
            for t in settings[LogKeys.reminderTimes] where (Self.time(t, on: now) ?? .distantFuture) <= now {
                fired.insert("\(today) \(t)")
            }
            show(style: settings[LogKeys.reminderStyle])
            break
        }
    }

    func shouldRemind(today: String, now: Date) -> Bool {
        if settings[LogKeys.skipDate] == today || model.todaySubmitted { return false }
        return model.context.workCalendar.isWorkday(now) || settings[LogKeys.remindOnOffDays]
    }

    /// 下一个会弹出的提醒时间。
    func nextReminder(now: Date = Date()) -> Date? {
        let today = WorkCalendar.dayString(now)
        guard shouldRemind(today: today, now: now) else { return nil }
        if let s = snoozeUntil { return s }
        return settings[LogKeys.reminderTimes].compactMap { Self.time($0, on: now) }
            .filter { $0 > now && !fired.contains("\(today) \(Self.hhmm($0))") }
            .min()
    }

    func show(style: ReminderStyle) {
        if settings[LogKeys.scanMode] != .manualOnly {
            Task { await model.scanTodayCount() }
        }
        let count = model.todayCommitCount.map { "今天有 \($0) 次提交，" } ?? ""
        let snooze = settings[LogKeys.snoozeMinutes]
        let content = ReminderContent(
            id: Self.reminderID,
            title: "今天的禅道日志还没写",
            message: "\(count)点一下就能生成草稿，确认后提交。",
            systemImage: "square.and.pencil",
            actions: [
                ReminderAction(id: "later", title: "\(snooze) 分钟后") { [weak self] in
                    self?.snoozeUntil = Date().addingTimeInterval(TimeInterval(snooze * 60))
                },
                ReminderAction(id: "skip", title: "今天不写") { [weak self] in
                    guard let self else { return }
                    settings[LogKeys.skipDate] = WorkCalendar.dayString(Date())
                },
                ReminderAction(id: "write", title: "去写日志", isPrimary: true) { [weak self] in
                    guard let self else { return }
                    model.context.openPlugin(ZentaoLogPlugin.pluginID)
                    Task {
                        await self.model.select(date: Date())
                        await self.model.loadTasks()
                        await self.model.generate()
                    }
                },
            ]
        )
        model.context.reminders.show(content, style: style)
    }

    /// 设置页的「预览」按钮：只预览样式，按钮不产生任何效果，并返回投递结果。
    @discardableResult
    func preview(style: ReminderStyle) async -> ReminderDeliveryResult {
        let id = "zentao.log.preview.\(style.rawValue)"
        let content = ReminderContent(
            id: id,
            title: "今天的禅道日志还没写（预览）",
            message: "这是「\(style.shortName)」样式的预览，点任意按钮关闭。",
            systemImage: "square.and.pencil",
            actions: [
                ReminderAction(id: "later", title: "\(settings[LogKeys.snoozeMinutes]) 分钟后") {},
                ReminderAction(id: "skip", title: "今天不写") {},
                ReminderAction(id: "write", title: "去写日志", isPrimary: true) {},
            ]
        )
        return await model.context.reminders.showAndReport(content, style: style)
    }

    static func time(_ hhmm: String, on day: Date) -> Date? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: day)
    }

    static func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
