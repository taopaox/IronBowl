import Foundation
import IronBowlKit
import SwiftUI

/// 禅道日志插件。
public final class ZentaoLogPlugin: IronBowlPlugin {
    public static let pluginID = "zentao.log"
    public let id = ZentaoLogPlugin.pluginID
    public let title = "禅道日志"
    public let systemImage = "square.and.pencil"
    public var migrations: [DatabaseMigration] { LogMigrations.all }

    var model: LogModel?
    var scheduler: LogReminderScheduler?

    public init() {}

    public func start(context: PluginContext) {
        let model = LogModel(context: context)
        self.model = model
        let scheduler = LogReminderScheduler(model: model)
        self.scheduler = scheduler
        scheduler.start()
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

    public var sidebarRecents: [SidebarRecent] {
        guard let model else { return [] }
        let _ = model.todaySubmitted
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return model.recentDays.prefix(5).map { day in
            let subs = model.store.submissions(on: WorkCalendar.dayString(day))
            let info = model.context.workCalendar.dayInfo(day)
            let status = subs.isEmpty ? (info.isWorkday ? "待提交" : "休息") : "\(hoursText(subs.reduce(0) { $0 + $1.hours }))h"
            let trailing = Calendar.current.isDateInToday(day) ? "今天" : day.formatted(.dateTime.weekday(.abbreviated))
            return SidebarRecent(id: "zentao.day.\(WorkCalendar.dayString(day))", title: "\(f.string(from: day)) \(status)", trailing: trailing) {
                model.context.openPlugin(ZentaoLogPlugin.pluginID)
                Task { await model.select(date: day) }
            }
        }
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
                     value: { model.todaySubmitted ? "已提交" : "未提交" },
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
            MenuBarItem(id: "zentao.status", title: "今天的日志状态（✓ 已提交 / ● 未提交）") {
                model.todaySubmitted ? "✓" : (model.context.workCalendar.isWorkday(Date()) ? "●" : nil)
            },
            MenuBarItem(id: "zentao.commits", title: "今天的提交数") {
                model.todayCommitCount.map { "\($0)次" }
            },
            MenuBarItem(id: "zentao.hours", title: "今天的预计工时") {
                let subs = model.store.submissions(on: WorkCalendar.dayString(Date()))
                let h = subs.isEmpty ? model.defaultHours : subs.reduce(0) { $0 + $1.hours }
                return "\(hoursText(h))h"
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

    /// 设置页的「测试」按钮：只预览样式，按钮不产生任何效果。
    func preview(style: ReminderStyle) {
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
        model.context.reminders.show(content, style: style)
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
