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

    public var sidebarBadge: SidebarBadge? {
        guard let model else { return nil }
        if !model.hasCurrentWeekReport {
            return SidebarBadge("本周未写", color: DS.danger)
        }
        if model.isTitaConfigured,
           model.periodKind == .weekly,
           model.isCurrentPeriod,
           model.titaStatus?.state.isSubmitted == false {
            return SidebarBadge("待推Tita", color: DS.warning)
        }
        return nil
    }

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

    public func canHandleChatIntent(_ text: String) -> Bool {
        ReportChatHandler.match(text, periodKind: .weekly) != nil
    }

    public func handleChatIntent(
        _ text: String,
        onProgress: @escaping @MainActor (ChatActivityItem) -> Void
    ) async -> ChatPluginExecutionResult? {
        guard let model, let intent = ReportChatHandler.match(text, periodKind: .weekly) else { return nil }
        return await executeReportChatIntent(model: model, periodKind: .weekly, intent: intent, onProgress: onProgress)
    }

    public func makeInteractiveChatCard(for attachment: ChatCardAttachment) -> AnyView? {
        guard let model, let key = ReportChatHandler.periodKey(fromCardID: attachment.cardID, periodKind: .weekly) else {
            return nil
        }
        return AnyView(ReportChatCard(model: model, periodKind: .weekly, periodKey: key))
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

    public var sidebarBadge: SidebarBadge? {
        guard let model else { return nil }
        if !model.hasCurrentMonthReport {
            return SidebarBadge("本月未写", color: DS.danger)
        }
        if model.isTitaConfigured,
           model.periodKind == .monthly,
           model.isCurrentPeriod,
           model.titaStatus?.state.isSubmitted == false {
            return SidebarBadge("待推Tita", color: DS.warning)
        }
        return nil
    }

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

    public func canHandleChatIntent(_ text: String) -> Bool {
        ReportChatHandler.match(text, periodKind: .monthly) != nil
    }

    public func handleChatIntent(
        _ text: String,
        onProgress: @escaping @MainActor (ChatActivityItem) -> Void
    ) async -> ChatPluginExecutionResult? {
        guard let model, let intent = ReportChatHandler.match(text, periodKind: .monthly) else { return nil }
        return await executeReportChatIntent(model: model, periodKind: .monthly, intent: intent, onProgress: onProgress)
    }

    public func makeInteractiveChatCard(for attachment: ChatCardAttachment) -> AnyView? {
        guard let model, let key = ReportChatHandler.periodKey(fromCardID: attachment.cardID, periodKind: .monthly) else {
            return nil
        }
        return AnyView(ReportChatCard(model: model, periodKind: .monthly, periodKey: key))
    }
}

/// 牛马账本插件：按月/年统计工时、加班、打卡作息与各项目投入占比。
public final class WorkLedgerPlugin: IronBowlPlugin {
    public static let pluginID = "report.stats"

    public let id = WorkLedgerPlugin.pluginID
    public let title = "牛马账本"
    public let sidebarSection: String? = "汇报"
    public let systemImage = "chart.bar.xaxis"

    var model: WorkLedgerModel?

    public init() {}

    public func start(context: PluginContext) {
        self.model = WorkLedgerModel(context: context)
    }

    public func stop() {
        model = nil
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(WorkLedgerView(model: model))
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "report.stats", title: "看工时统计", systemImage: "chart.bar.xaxis") {
                model.context.openPlugin(Self.pluginID)
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(
                id: "report.stats",
                label: "本月账本",
                value: {
                    let h = model.summary.totalHours
                    return h > 0 ? "\(WorkCalendar.hoursText(h))h" : "0h"
                },
                detail: {
                    let ot = model.summary.overtimeHours
                    if ot > 0 {
                        return "含加班 \(WorkCalendar.hoursText(ot))h · \(model.summary.loggedDaysCount) 天记录"
                    }
                    return "\(model.summary.loggedDaysCount)/\(model.summary.expectedWorkdaysCount) 天已记"
                },
                action: {
                    model.context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}

@MainActor
private func executeReportChatIntent(
    model: WeeklyReportModel,
    periodKind: ReportPeriodKind,
    intent: ReportChatIntent,
    onProgress: @escaping @MainActor (ChatActivityItem) -> Void
) async -> ChatPluginExecutionResult {
    let noun = periodKind.displayName
    let previous: Bool
    let shouldGenerate: Bool
    switch intent {
    case .generate(let prev):
        previous = prev
        shouldGenerate = true
    case .show(let prev):
        previous = prev
        shouldGenerate = false
    }

    onProgress(ChatActivityItem(
        id: "report-logs",
        kind: .tool,
        title: "查询\(noun)关联的每日日报",
        status: .running
    ))
    switch periodKind {
    case .weekly:
        let week = WeekRange.containing(Date()).shifted(byWeeks: previous ? -1 : 0)
        await model.selectWeek(week)
    case .monthly:
        let month = MonthRange.containing(Date()).shifted(byMonths: previous ? -1 : 0)
        await model.selectMonth(month)
    }
    onProgress(ChatActivityItem(
        id: "report-logs",
        kind: .tool,
        title: "查询\(noun)关联的每日日报",
        subtitle: "\(model.loggedDaysCount) 天有记录 · \(WorkCalendar.hoursText(model.totalHours))h",
        status: .completed,
        finishedAt: Date()
    ))

    if shouldGenerate {
        onProgress(ChatActivityItem(
            id: "report-generate",
            kind: .tool,
            title: "按项目模板汇总生成\(noun)",
            subtitle: model.activePeriodTitle,
            status: .running
        ))
        await model.generate()
        let err = model.errorMessage
        onProgress(ChatActivityItem(
            id: "report-generate",
            kind: .tool,
            title: "按项目模板汇总生成\(noun)",
            subtitle: err ?? (model.message ?? "已完成"),
            outputText: err ?? model.message,
            status: err == nil ? .completed : .failed,
            finishedAt: Date()
        ))
    }

    let card = ChatCardAttachment(
        cardID: ReportChatHandler.cardID(periodKind: periodKind, periodKey: model.activePeriodKey),
        label: model.activePeriodTitle + noun,
        valueSnapshot: model.hasReportContent ? "已生成" : "未生成",
        detailSnapshot: model.activePeriodShortRangeText
    )

    let reply: String
    if let err = model.errorMessage {
        reply = "### \(model.activePeriodTitle)\(noun)\n\n> ⚠️ \(err)"
    } else if model.hasReportContent {
        reply = "已为你准备好 **\(model.activePeriodTitle)\(noun)**（共 \(model.loggedDaysCount) 天 · \(WorkCalendar.hoursText(model.totalHours))h），可直接在下方卡片预览、复制或前往\(noun)页推送 Tita。"
    } else {
        reply = "当前周期暂无\(noun)内容，可点击下方卡片「立即生成」。"
    }

    return ChatPluginExecutionResult(replyText: reply, cards: [card])
}
