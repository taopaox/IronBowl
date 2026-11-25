import Foundation
import IronBowlKit
import SwiftUI

/// 周报插件：查询本周每日日报并生成周报。
public final class ReportPlugin: IronBowlPlugin {
    public static let pluginID = "report"
    public static let settingsGenerateID = "report.generate"

    public let id = ReportPlugin.pluginID
    public let title = "周报"
    public let systemImage = "doc.text"
    public var migrations: [DatabaseMigration] { ReportMigrations.all }

    var model: WeeklyReportModel?
    private var context: PluginContext?

    public init() {}

    public func start(context: PluginContext) {
        self.context = context
        self.model = WeeklyReportModel(context: context)
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
                AnyView(ReportSettingsView(model: model))
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
                    if let hours = model.currentWeekSavedHours, model.hasCurrentWeekReport {
                        return hours > 0 ? "累计 \(WorkCalendar.hoursText(hours))h · \(WeekRange.containing(Date()).shortRangeText)" : WeekRange.containing(Date()).shortRangeText
                    }
                    return WeekRange.containing(Date()).title
                },
                action: {
                    model.context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}
