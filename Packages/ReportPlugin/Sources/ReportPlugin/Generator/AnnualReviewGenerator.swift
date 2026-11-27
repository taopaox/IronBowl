import Foundation
import IronBowlKit
import ZentaoLogPlugin

/// 季度/年终述职风格。
public nonisolated enum AnnualReviewStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case performanceSTAR
    case okrReview
    case executiveBrief

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .performanceSTAR: "述职晋升 (STAR)"
        case .okrReview: "OKR 复盘"
        case .executiveBrief: "精简量化提纲"
        }
    }

    public var detail: String {
        switch self {
        case .performanceSTAR: "围绕核心目标、关键行动、技术攻坚与量化结果展开，适合年终述职与绩效汇报。"
        case .okrReview: "对照项目投入与月度阶段交付进行 O/KR 式复盘，沉淀经验教训与下阶段规划。"
        case .executiveBrief: "结构紧凑、数据先行，适合直接粘贴到述职 PPT 或大纲。"
        }
    }

    public var promptInstruction: String {
        switch self {
        case .performanceSTAR:
            "采用「述职晋升 STAR 法则」结构，包含 `## 核心业务产出与交付`、`## 重点项目攻坚与技术沉淀`、`## 量化投入与个人成长`、`## 问题复盘与下阶段规划`。"
        case .okrReview:
            "采用「OKR 复盘」结构，包含 `## 核心目标达成回顾`、`## 关键项目交付拆解`、`## 不足与改进动作`、`## 下一周期重点规划`。"
        case .executiveBrief:
            "采用「精简量化提纲」结构，用凝练的小标题与要点直接列举核心项目成果、量化数据与下阶段目标。"
        }
    }
}

nonisolated struct AnnualReviewInput: Sendable {
    var range: ReviewRange
    var style: AnnualReviewStyle
    var ledgerSummary: WorkLedgerSummary
    var monthlyReports: [MonthlyReportRecord]
    var gitStats: GitPeriodStats
    var extraNotes: String
    var promptTemplate: String
}

nonisolated struct AnnualReviewOutput: Sendable {
    var title: String
    var content: String
    var usedAI: Bool
    var aiError: String?
    var aiSeconds: Double?
}

nonisolated enum AnnualReviewGenerator {
    static let defaultPrompt = """
    你是我的职场述职与复盘顾问。请根据我 {{periodTitle}}（{{periodRange}}）的量化工作数据、月报归档内容、代码提交统计以及补充亮点，为我撰写一份专业、扎实、可直接用于述职答辩的中文复盘报告。

    要求：
    1. {{styleInstruction}}
    2. 严格基于下方提供的真实工时、项目、月报和代码统计提炼内容，不得虚构未提及的项目、业绩或数值。
    3. 合并跨月持续推进的重点项目，突出业务价值、架构/效率提升与个人担当。
    4. 正文使用规范 Markdown（二级标题 `##` / 三级标题 `###` 与列表），无需重复顶部大标题。

    ## 周期
    {{periodTitle}}（{{periodRange}}）

    ## 量化工作指标
    {{metricsSummary}}

    ## 项目投入分布
    {{projectBreakdown}}

    ## 代码贡献统计
    {{gitSummary}}

    ## 已归档月报摘要
    {{monthlyReports}}

    ## 个人补充亮点
    {{extraNotes}}

    只输出符合 JSON Schema 的结果。
    """

    static func defaultTitle(for range: ReviewRange) -> String {
        "\(range.title)工作述职与总结"
    }

    private struct AIResult: Decodable, Sendable {
        let title: String?
        let content: String?
    }

    private static let schema = """
    {"type":"object","additionalProperties":false,"required":["title","content"],"properties":{"title":{"type":"string","description":"述职或复盘报告标题"},"content":{"type":"string","description":"Markdown 格式述职报告正文"}}}
    """

    static func prompt(_ input: AnnualReviewInput) -> String {
        let template = input.promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPrompt
            : input.promptTemplate

        return template
            .replacingOccurrences(of: "{{periodTitle}}", with: input.range.title)
            .replacingOccurrences(of: "{{periodRange}}", with: input.range.rangeText)
            .replacingOccurrences(of: "{{styleInstruction}}", with: input.style.promptInstruction)
            .replacingOccurrences(of: "{{metricsSummary}}", with: metricsText(input.ledgerSummary))
            .replacingOccurrences(of: "{{projectBreakdown}}", with: projectBreakdownText(input.ledgerSummary.projectBreakdown))
            .replacingOccurrences(of: "{{gitSummary}}", with: gitStatsText(input.gitStats))
            .replacingOccurrences(of: "{{monthlyReports}}", with: monthlyReportsText(input.monthlyReports))
            .replacingOccurrences(of: "{{extraNotes}}", with: input.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（无）" : input.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func generate(_ input: AnnualReviewInput, provider: AIProviderConfig?) async -> AnnualReviewOutput {
        let fallback = fallbackReview(input)
        guard let provider, !provider.executablePath.isEmpty else {
            return AnnualReviewOutput(title: defaultTitle(for: input.range), content: fallback, usedAI: false, aiError: nil, aiSeconds: nil)
        }
        do {
            let result = try await AIRunner.run(
                config: provider,
                prompt: prompt(input),
                schema: schema
            )
            let decoded = try JSONDecoder().decode(AIResult.self, from: result.json)
            let body = (decoded.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                return AnnualReviewOutput(
                    title: defaultTitle(for: input.range),
                    content: fallback,
                    usedAI: false,
                    aiError: "AI 返回正文为空，已使用本地规则汇总",
                    aiSeconds: result.duration
                )
            }
            let title = (decoded.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return AnnualReviewOutput(
                title: title.isEmpty ? defaultTitle(for: input.range) : title,
                content: body,
                usedAI: true,
                aiError: nil,
                aiSeconds: result.duration
            )
        } catch {
            return AnnualReviewOutput(
                title: defaultTitle(for: input.range),
                content: fallback,
                usedAI: false,
                aiError: error.localizedDescription,
                aiSeconds: nil
            )
        }
    }

    static func fallbackReview(_ input: AnnualReviewInput) -> String {
        let s = input.ledgerSummary
        var sections: [String] = []

        // 1. 量化概览
        var metricLines: [String] = [
            "- **工作周期**：\(input.range.title)（\(input.range.rangeText)）",
            "- **累计工时**：共 \(WorkCalendar.hoursText(s.totalHours))h（正常 \(WorkCalendar.hoursText(s.normalHours))h + 加班 \(WorkCalendar.hoursText(s.overtimeHours))h），记录工作 \(s.loggedDaysCount)/\(s.expectedWorkdaysCount) 天",
        ]
        if s.overtimeDaysCount > 0 {
            metricLines.append("- **加班投入**：累计加班 \(s.overtimeDaysCount) 天")
        }
        if let avg = s.averageClockInText {
            var line = "- **考勤作息**：平均上班打卡 \(avg)"
            if let earliest = s.earliestClockInText { line += "，最早 \(earliest)" }
            if let latest = s.latestOffWorkText { line += "，最晚下班 \(latest)" }
            metricLines.append(line)
        }
        if input.gitStats.commitCount > 0 {
            metricLines.append("- **代码贡献**：覆盖 \(input.gitStats.activeRepoCount) 个仓库，累计提交 \(input.gitStats.commitCount) 次（+\(input.gitStats.addedLines) / -\(input.gitStats.deletedLines) 行）")
        }
        sections.append("## 量化工作概览\n\n" + metricLines.joined(separator: "\n"))

        // 2. 项目投入
        if !s.projectBreakdown.isEmpty {
            let projLines = s.projectBreakdown.map { proj in
                let pct = Int((proj.share * 100).rounded())
                return "- **\(proj.projectName)**：投入 \(WorkCalendar.hoursText(proj.hours))h（占比 \(pct)% · \(proj.entryCount) 条工作记录）"
            }
            sections.append("## 核心项目投入\n\n" + projLines.joined(separator: "\n"))
        }

        // 3. 阶段月报摘录
        if !input.monthlyReports.isEmpty {
            let monthBlocks = input.monthlyReports.map { rec -> String in
                let trimmed = rec.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let preview = trimmed.split(whereSeparator: \.isNewline)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .prefix(6)
                    .joined(separator: "\n")
                return "### \(rec.title)（\(WorkCalendar.hoursText(rec.totalHours))h）\n\n\(preview)"
            }
            sections.append("## 阶段交付回顾\n\n" + monthBlocks.joined(separator: "\n\n"))
        }

        // 4. 补充亮点
        let trimmedNotes = input.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            sections.append("## 重点亮点与思考\n\n\(trimmedNotes)")
        }

        // 5. 下阶段规划占位
        let nextHeader = input.style == .executiveBrief ? "## 下阶段关键目标" : "## 问题复盘与下阶段规划"
        sections.append("\(nextHeader)\n\n- 持续跟进核心项目的稳定性与交付效率。\n- 结合本周期经验优化工程质量与自动化流程。")

        return sections.joined(separator: "\n\n")
    }

    private static func metricsText(_ s: WorkLedgerSummary) -> String {
        var lines: [String] = [
            "- 总工时：\(WorkCalendar.hoursText(s.totalHours))h（正常 \(WorkCalendar.hoursText(s.normalHours))h，加班 \(WorkCalendar.hoursText(s.overtimeHours))h）",
            "- 出勤记录：\(s.loggedDaysCount)/\(s.expectedWorkdaysCount) 个工作日已记录，加班 \(s.overtimeDaysCount) 天",
        ]
        if s.actualStayHours > 0 {
            lines.append("- 考勤在岗时长：\(WorkCalendar.hoursText(s.actualStayHours))h（\(s.clockOutDaysCount) 天含完整上下班卡）")
        }
        if let avg = s.averageClockInText {
            lines.append("- 平均上班时间：\(avg)")
        }
        return lines.joined(separator: "\n")
    }

    private static func projectBreakdownText(_ projects: [LedgerProjectStat]) -> String {
        guard !projects.isEmpty else { return "（暂无项目工时数据）" }
        return projects.map { p in
            "- \(p.projectName)：\(WorkCalendar.hoursText(p.hours))h（\(Int((p.share * 100).rounded()))%，\(p.entryCount) 条记录）"
        }.joined(separator: "\n")
    }

    private static func gitStatsText(_ g: GitPeriodStats) -> String {
        guard g.commitCount > 0 else { return "（暂无本地 Git 提交统计）" }
        var lines = [
            "- 总提交数：\(g.commitCount) 次，涉及 \(g.activeRepoCount) 个仓库",
            "- 代码行数：新增 +\(g.addedLines) 行，删除 -\(g.deletedLines) 行",
        ]
        if let busiest = g.busiestMonth {
            lines.append("- 最活跃月份：\(busiest)")
        }
        if !g.topRepos.isEmpty {
            let top = g.topRepos.prefix(5).map { "\($0.name)(\($0.commits)次)" }.joined(separator: "、")
            lines.append("- 活跃仓库 Top 5：\(top)")
        }
        return lines.joined(separator: "\n")
    }

    private static func monthlyReportsText(_ records: [MonthlyReportRecord]) -> String {
        guard !records.isEmpty else { return "（暂无已归档月报，可结合项目工时与个人亮点撰写）" }
        return records.map { rec in
            let body = rec.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = body.count > 1200 ? String(body.prefix(1200)) + "\n…（已截断）" : body
            return "### \(rec.title)（\(rec.monthKey) · \(WorkCalendar.hoursText(rec.totalHours))h）\n\(clipped)"
        }.joined(separator: "\n\n")
    }
}
