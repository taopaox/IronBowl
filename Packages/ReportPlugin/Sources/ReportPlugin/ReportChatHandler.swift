import Foundation
import IronBowlKit

public nonisolated enum ReportChatIntent: Equatable, Sendable {
    case generate(previousPeriod: Bool)
    case show(previousPeriod: Bool)
}

/// 识别首页「今天」对话里的周报/月报业务指令。
public nonisolated enum ReportChatHandler {
    public static let weeklyCardPrefix = "report.weekly.interactive:"
    public static let monthlyCardPrefix = "report.monthly.interactive:"

    public static func cardID(periodKind: ReportPeriodKind, periodKey: String) -> String {
        switch periodKind {
        case .weekly: weeklyCardPrefix + periodKey
        case .monthly: monthlyCardPrefix + periodKey
        }
    }

    public static func periodKey(fromCardID cardID: String, periodKind: ReportPeriodKind) -> String? {
        let prefix = periodKind == .weekly ? weeklyCardPrefix : monthlyCardPrefix
        guard cardID.hasPrefix(prefix) else { return nil }
        let suffix = String(cardID.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    public static func match(_ rawText: String, periodKind: ReportPeriodKind) -> ReportChatIntent? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        let lower = trimmed.lowercased()

        let codeSignals = [
            ".swift", "代码", "源码", "bug", "报错", "修复", "重构",
            "为什么", "怎么实现", "原理", "函数", "方法", "变量",
            "测试", "reportplugin", "weeklyreport", "文件",
        ]
        if codeSignals.contains(where: { lower.contains($0) }) {
            return nil
        }

        let noun = periodKind == .weekly ? "周报" : "月报"
        guard lower.contains(noun) else { return nil }

        let previousPeriod: Bool = switch periodKind {
        case .weekly: lower.contains("上周")
        case .monthly: lower.contains("上月") || lower.contains("上个月")
        }

        let generateVerbs = ["生成", "写", "整理", "汇总", "重新生成", "出", "做", "补"]
        if generateVerbs.contains(where: { lower.contains($0) }) {
            return .generate(previousPeriod: previousPeriod)
        }

        let viewVerbs = ["看", "查", "打开", "展示", "状态", "预览"]
        if viewVerbs.contains(where: { lower.contains($0) }) {
            return .show(previousPeriod: previousPeriod)
        }

        if trimmed.count <= 10 {
            return .generate(previousPeriod: previousPeriod)
        }

        return nil
    }
}
