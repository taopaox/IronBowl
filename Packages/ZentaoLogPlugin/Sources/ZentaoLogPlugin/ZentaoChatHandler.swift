import Foundation
import IronBowlKit

public nonisolated enum ZentaoChatIntent: Equatable, Sendable {
    case generateDaily(dayOffset: Int)
    case showDaily(dayOffset: Int)
    case quickLog(sentence: String)
}

/// 识别首页「今天」对话里的禅道日报业务指令，同时避免拦截代码/调试类提问。
public nonisolated enum ZentaoChatHandler {
    public static let interactiveCardPrefix = "zentao.daily.interactive:"

    public static func cardID(forDateString ds: String) -> String {
        interactiveCardPrefix + ds
    }

    public static func dateString(fromCardID cardID: String) -> String? {
        guard cardID.hasPrefix(interactiveCardPrefix) else { return nil }
        let suffix = String(cardID.dropFirst(interactiveCardPrefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    public static func match(_ rawText: String) -> ZentaoChatIntent? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        let lower = trimmed.lowercased()

        // 防误判：代码开发、排错或原理解析提问交给通用编程 AI
        let codeSignals = [
            ".swift", "代码", "源码", "bug", "报错", "修复", "重构",
            "为什么", "怎么实现", "原理", "函数", "方法", "变量",
            "测试", "日志插件", "zentao", "logmodel", "draftgenerator", "文件",
        ]
        if codeSignals.contains(where: { lower.contains($0) }) {
            return nil
        }

        // 显式一句话记日志前缀
        for prefix in ["记日志：", "记日志:", "记一条日志：", "记一条日志:", "记录工时：", "记录工时:"] {
            if trimmed.hasPrefix(prefix) {
                let sentence = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    return .quickLog(sentence: sentence)
                }
            }
        }

        let targetNouns = ["日报", "禅道日志", "今日日志", "今天日志", "昨日日志", "昨天日志", "工时草稿"]
        guard targetNouns.contains(where: { lower.contains($0) }) else { return nil }

        let dayOffset = (lower.contains("昨") || lower.contains("前一天")) ? -1 : 0

        let generateVerbs = ["生成", "写", "整理", "汇总", "重新生成", "重新出", "出", "做", "补"]
        if generateVerbs.contains(where: { lower.contains($0) }) {
            return .generateDaily(dayOffset: dayOffset)
        }

        let viewVerbs = ["看", "查", "打开", "展示", "状态", "预览"]
        if viewVerbs.contains(where: { lower.contains($0) }) {
            return .showDaily(dayOffset: dayOffset)
        }

        // 极简短指令如「今日日报」「禅道日志」
        if trimmed.count <= 10 {
            return .generateDaily(dayOffset: dayOffset)
        }

        return nil
    }

    public static func parseDay(_ ds: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: ds) ?? Calendar.current.startOfDay(for: Date())
    }
}
