import Foundation
import IronBowlKit
import SwiftUI
import ZentaoLogPlugin

/// 待办与备忘插件：与万年历日期格、禅道日报草稿、提醒中心打通。
public final class TodoPlugin: IronBowlPlugin {
    public static let pluginID = "todo"
    public static let settingsReminderID = "todo.reminder"
    public static let reminderStyleKey = SettingKey<ReminderStyle>("todo.reminderStyle", default: .cornerCard)

    public let id = TodoPlugin.pluginID
    public let title = "待办"
    public let systemImage = "checklist"

    private var context: PluginContext?
    private var timer: Timer?

    public init() {}

    public func start(context: PluginContext) {
        self.context = context
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkDueReminders()
            }
        }
        timer?.tolerance = 5
        checkDueReminders()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        context = nil
    }

    public var sidebarBadge: SidebarBadge? {
        guard let todos = context?.todos else { return nil }
        let overdue = todos.overdueCount()
        if overdue > 0 {
            return SidebarBadge("\(overdue) 逾期", color: DS.danger)
        }
        let today = todos.todayIncompleteCount()
        if today > 0 {
            return SidebarBadge("今日 \(today)", color: DS.warning)
        }
        return nil
    }

    public var menuBarItems: [MenuBarItem] {
        guard let todos = context?.todos else { return [] }
        return [
            MenuBarItem(id: "todo.today", title: "今日待办数") {
                let count = todos.todayIncompleteCount()
                return count > 0 ? "待办 \(count)" : nil
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let context else { return [] }
        let todos = context.todos
        return [
            HomeCard(
                id: "todo.today",
                label: "今日待办",
                value: {
                    let count = todos.todayIncompleteCount()
                    return count > 0 ? "\(count) 项未完" : "已清空"
                },
                detail: {
                    let overdue = todos.overdueCount()
                    if overdue > 0 { return "含 \(overdue) 项逾期待处理" }
                    let pending = todos.items.filter { !$0.isCompleted }.count
                    return "共 \(pending) 项进行中"
                },
                action: {
                    context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }

    public var quickActions: [QuickAction] {
        guard let context else { return [] }
        return [
            QuickAction(id: "todo.open", title: "记待办", systemImage: "checklist") {
                context.openPlugin(Self.pluginID)
            },
        ]
    }

    public var settingsPages: [SettingsPage] {
        guard let context else { return [] }
        return [
            SettingsPage(id: Self.settingsReminderID, title: "待办提醒", systemImage: "bell") {
                AnyView(TodoReminderSettings(settings: context.settings))
            },
        ]
    }

    public func makeMainView() -> AnyView {
        guard let context else { return AnyView(ProgressView()) }
        return AnyView(TodoMainView(context: context))
    }

    // MARK: - 联动辅助

    @discardableResult
    public static func sendToDailyDraft(item: TodoItem, context: PluginContext, date: Date = Date()) -> Bool {
        let targetDate: Date = {
            if let ds = item.dueDate, let parsed = Self.parseDay(ds) {
                return parsed
            }
            return date
        }()
        let trimmedNotes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let work = trimmedNotes.isEmpty ? "1. \(item.title)" : "1. \(item.title)（\(trimmedNotes)）"
        let taskID = item.zentaoObjectType == "task" ? item.zentaoObjectID : nil
        guard ZentaoLogPlugin.appendExternalDraft(
            work: work,
            hours: item.estimatedHours,
            taskID: taskID,
            on: targetDate,
            database: context.database,
            settings: context.settings
        ) else {
            return false
        }
        context.todos.markLogged(id: item.id, dateString: WorkCalendar.dayString(targetDate))
        return true
    }

    private func checkDueReminders(now: Date = Date()) {
        guard let context else { return }
        let due = context.todos.dueReminderItems(at: now)
        guard !due.isEmpty else { return }
        let style = context.settings[Self.reminderStyleKey]
        for item in due {
            context.todos.markReminded(id: item.id, at: now)
            let dueSuffix = item.dueDate.map { "截止 \($0)" } ?? "定时备忘"
            let detail = item.notes.isEmpty ? dueSuffix : "\(dueSuffix) · \(item.notes)"
            let content = ReminderContent(
                id: "todo.item.\(item.id)",
                title: "待办提醒：\(item.title)",
                message: detail,
                systemImage: "checklist",
                source: .todo,
                targetPluginID: Self.pluginID,
                actions: [
                    ReminderAction(id: "later", title: "15 分钟后") { [weak context] in
                        context?.todos.snoozeReminder(id: item.id, minutes: 15)
                    },
                    ReminderAction(id: "open", title: "去查看") { [weak context] in
                        context?.openPlugin(Self.pluginID)
                    },
                    ReminderAction(id: "done", title: "标为已完成", isPrimary: true) { [weak context] in
                        context?.todos.toggleCompleted(id: item.id)
                    },
                ]
            )
            context.reminders.show(content, style: style)
        }
    }

    static func parseDay(_ ds: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ds)
    }
}

private struct TodoReminderSettings: View {
    let settings: SettingsStore

    var body: some View {
        DSSection("待办提醒", footer: "为待办事项设置提醒时间后，到点会通过这里选定的样式弹出通知，并沉淀到「消息提醒」中心。") {
            DSRow("提醒样式") {
                DSPicker(
                    selection: settings.binding(TodoPlugin.reminderStyleKey),
                    options: ReminderStyle.allCases.map { DSPickerOption($0, title: $0.displayName) }
                )
            }
        }
    }
}
