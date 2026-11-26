import Foundation
import IronBowlKit
import SwiftUI

/// 周报插件：查询本周每日日报并生成周报。
public final class ReportPlugin: IronBowlPlugin {
    public static let pluginID = "report"
    public static let settingsGenerateID = "report.generate"
    public static let settingsTitaID = "report.tita"

    public let id = ReportPlugin.pluginID
    public let title = "周报"
    public let sidebarSection: String? = "汇报"
    public let systemImage = "doc.text"
    public var migrations: [DatabaseMigration] { [ReportMigrations.weekly] }

    var model: WeeklyReportModel?
    private var context: PluginContext?

    public init() {}

    public func start(context: PluginContext) {
        self.context = context
        self.model = WeeklyReportModel(context: context, lockedPeriodKind: .weekly)
    }

    public func stop() {
        model = nil
        context = nil
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(ReportView(model: model))
    }

    public var settingsPages: [SettingsPage] {
        guard let model else { return [] }
        return [
            SettingsPage(id: Self.settingsGenerateID, title: "周报生成", systemImage: "doc.text") {
                AnyView(ReportSettingsView(model: model, periodKind: .weekly))
            },
            SettingsPage(id: Self.settingsTitaID, title: "Tita 对接", systemImage: "paperplane") {
                AnyView(TitaAccountSettings(model: model))
            },
        ]
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "report.weekly", title: "生成本周周报", systemImage: "doc.text") {
                model.context.openPlugin(Self.pluginID)
                Task {
                    await model.goToCurrentWeek()
                    await model.generate()
                }
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(
                id: "report.weekly",
                label: "本周周报",
                value: {
                    model.hasCurrentWeekReport ? "已生成" : "未生成"
                },
                detail: {
                    let currentWeek = WeekRange.containing(Date())
                    if let hours = model.currentWeekSavedHours, model.hasCurrentWeekReport {
                        return hours > 0 ? "累计 \(WorkCalendar.hoursText(hours))h · \(currentWeek.shortRangeText)" : currentWeek.shortRangeText
                    }
                    return currentWeek.title
                },
                action: {
                    model.context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}

/// 月报插件：独立侧边栏菜单，查询本月每日日报并生成月报。
public final class MonthlyReportPlugin: IronBowlPlugin {
    public static let pluginID = "report.monthly"
    public static let settingsGenerateID = "report.monthly.generate"

    public let id = MonthlyReportPlugin.pluginID
    public let title = "月报"
    public let sidebarSection: String? = "汇报"
    public let systemImage = "doc.richtext"
    public var migrations: [DatabaseMigration] { [ReportMigrations.monthly] }

    var model: WeeklyReportModel?
    private var context: PluginContext?

    public init() {}

    public func start(context: PluginContext) {
        self.context = context
        self.model = WeeklyReportModel(context: context, lockedPeriodKind: .monthly)
    }

    public func stop() {
        model = nil
        context = nil
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(ReportView(model: model))
    }

    public var settingsPages: [SettingsPage] {
        guard let model else { return [] }
        return [
            SettingsPage(id: Self.settingsGenerateID, title: "月报生成", systemImage: "doc.richtext") {
                AnyView(ReportSettingsView(model: model, periodKind: .monthly))
            },
        ]
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "report.monthly", title: "生成本月月报", systemImage: "doc.richtext") {
                model.context.openPlugin(Self.pluginID)
                Task {
                    await model.goToCurrentMonth()
                    await model.generate()
                }
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(
                id: "report.monthly",
                label: "本月月报",
                value: {
                    model.hasCurrentMonthReport ? "已生成" : "未生成"
                },
                detail: {
                    let currentMonth = MonthRange.containing(Date())
                    if let hours = model.currentMonthSavedHours, model.hasCurrentMonthReport {
                        return hours > 0 ? "累计 \(WorkCalendar.hoursText(hours))h · \(currentMonth.title)" : currentMonth.title
                    }
                    return currentMonth.title
                },
                action: {
                    model.context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}
