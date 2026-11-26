import Foundation
import IronBowlKit
import SwiftUI

/// 定时任务管理插件。
public final class SchedulerPlugin: IronBowlPlugin {
    public static let pluginID = TaskScheduler.schedulerPluginID
    public let id = SchedulerPlugin.pluginID
    public let title = "定时任务"
    public let systemImage = "clock.badge.checkmark"

    private var context: PluginContext?

    public init() {}

    public func start(context: PluginContext) {
        self.context = context
        context.scheduler.start()
    }

    public func stop() {
        context?.scheduler.stop()
        context = nil
    }

    public func makeMainView() -> AnyView {
        guard let context else { return AnyView(ProgressView()) }
        return AnyView(
            SchedulerView(
                scheduler: context.scheduler,
                workCalendar: context.workCalendar,
                openPlugin: context.openPlugin,
                openSettings: context.openSettings
            )
        )
    }

    public var homeCards: [HomeCard] {
        guard let context else { return [] }
        let scheduler = context.scheduler
        return [
            HomeCard(
                id: "scheduler.next",
                label: "定时任务",
                value: {
                    if let upcoming = scheduler.nextUpcomingTask() {
                        return CN.time(upcoming.fireAt)
                    }
                    let count = scheduler.enabledTaskCount
                    return count > 0 ? "\(count) 个启用" : "未启用"
                },
                detail: {
                    if let upcoming = scheduler.nextUpcomingTask() {
                        let dayPrefix = Calendar.current.isDateInToday(upcoming.fireAt)
                            ? ""
                            : "\(CN.monthDay(upcoming.fireAt)) "
                        return "\(upcoming.task.name)（\(dayPrefix)\(countdown(to: upcoming.fireAt))后）"
                    }
                    return scheduler.tasks.isEmpty ? "点击添加定时任务" : "共 \(scheduler.tasks.count) 个任务"
                },
                action: { context.openPlugin(Self.pluginID) }
            ),
        ]
    }

    public var menuBarItems: [MenuBarItem] {
        guard let context else { return [] }
        let scheduler = context.scheduler
        return [
            MenuBarItem(id: "scheduler.next", title: "离下次定时任务还有多久") {
                guard let upcoming = scheduler.nextUpcomingTask() else { return nil }
                return "距任务 " + countdown(to: upcoming.fireAt)
            },
        ]
    }
}
