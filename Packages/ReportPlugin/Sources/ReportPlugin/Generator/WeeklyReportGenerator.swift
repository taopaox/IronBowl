import Foundation
import IronBowlKit
import ZentaoLogPlugin

/// 周报视图中按天聚合后的日报数据。
public nonisolated struct DailyReportDay: Sendable, Identifiable, Hashable {
    public var id: String { dateString }
    public let date: Date
    public let dateString: String
    public let weekdayText: String
    public let isWorkday: Bool
    public let holidayName: String?
    public let items: [DailyLogItem]

    public init(
        date: Date,
        dateString: String,
        weekdayText: String,
        isWorkday: Bool,
        holidayName: String?,
        items: [DailyLogItem]
    ) {
        self.date = date
        self.dateString = dateString
        self.weekdayText = weekdayText
        self.isWorkday = isWorkday
        self.holidayName = holidayName
        self.items = items
    }

    public var totalHours: Double {
        items.reduce(0) { $0 + $1.hours }
    }

    public var normalHours: Double {
        items.filter { !$0.isOvertime }.reduce(0) { $0 + $1.hours }
    }

    public var overtimeHours: Double {
        items.filter(\.isOvertime).reduce(0) { $0 + $1.hours }
    }

    public var hasDrafts: Bool {
        items.contains(where: \.isDraft)
    }

    public var isEmpty: Bool {
        items.isEmpty
    }
}

nonisolated struct WeeklyReportInput: Sendable {
    var week: WeekRange
    var days: [DailyReportDay]
    var extraNotes: String
    var style: WeeklyReportStyle
    var includeHours: Bool
    var promptTemplate: String
}

nonisolated struct MonthlyReportInput: Sendable {
    var month: MonthRange
    var days: [DailyReportDay]
    var weeklySummaries: [WeeklyReportRecord]
    var extraNotes: String
    var style: WeeklyReportStyle
    var includeHours: Bool
    var promptTemplate: String
}

nonisolated struct WeeklyReportOutput: Sendable {
    var title: String
    var content: String
    var usedAI: Bool
    var aiError: String?
    var aiSeconds: Double?
}

nonisolated enum WeeklyReportGenerator {
    static let defaultPrompt = """
    你是我的工作周报助手。请根据我 {{weekRange}} 的每日工作日报与补充说明，整理出一份结构清晰、语言专业、可直接用于汇报的中文工作周报。

    要求：
    1. {{styleInstruction}}
    2. 对多天持续推进的同一功能或问题进行合并去重，提炼业务结果与价值，不要机械复制流水账。
    3. 严格依据下方提供的每日日报与补充说明整理，不要编造未提及的工作内容或数据。
    4. 工时要求：{{totalHours}}
    5. 正文使用干净的 Markdown 格式（二级标题 `##` / 三级标题 `###` 与列表），无需在正文顶部重复大标题。

    ## 周期
    {{weekRange}}

    ## 本周每日日报
    {{dailyLogs}}

    ## 补充说明
    {{extraNotes}}

    只输出符合 JSON Schema 的结果。
    """

    static let defaultMonthlyPrompt = """
    你是我的工作月报助手。请根据我 {{monthRange}} 的每日工作日报、本月已有周报参考以及补充说明，整理出一份结构清晰、语言精炼、突出阶段性成果的中文工作月报。

    要求：
    1. {{styleInstruction}}
    2. 对跨周持续推进的同一项目或功能进行聚合归纳，提炼关键成果、交付价值与里程碑，避免逐日流水账堆砌。
    3. 仅基于下方提供的每日日报、已有周报与补充说明整理，不要编造未发生的工作内容或指标。
    4. 工时要求：{{totalHours}}
    5. 正文使用干净的 Markdown 格式（二级标题 `##` / 三级标题 `###` 与列表），无需在正文顶部重复大标题。

    ## 周期
    {{monthRange}}

    ## 本月每日日报
    {{dailyLogs}}

    ## 本月已有周报参考
    {{weeklyReports}}

    ## 补充说明
    {{extraNotes}}

    只输出符合 JSON Schema 的结果。
    """

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["title","content"],"properties":{"title":{"type":"string"},"content":{"type":"string"}}}
    """

    private struct AIResult: Decodable {
        let title: String
        let content: String
    }

    static func defaultTitle(for week: WeekRange) -> String {
        "\(week.title)工作周报（\(week.shortRangeText)）"
    }

    static func defaultTitle(for month: MonthRange) -> String {
        "\(month.title)工作月报"
    }

    private static func formatHoursSummary(days: [DailyReportDay], includeHours: Bool, periodNoun: String) -> String {
        let totalHours = days.reduce(0.0) { $0 + $1.totalHours }
        let normalHours = days.reduce(0.0) { $0 + $1.normalHours }
        let overtimeHours = days.reduce(0.0) { $0 + $1.overtimeHours }
        let loggedDays = days.filter { !$0.isEmpty }.count

        if includeHours {
            let otText = overtimeHours > 0 ? "，含加班 \(WorkCalendar.hoursText(overtimeHours))h" : ""
            return "\(periodNoun)累计 \(WorkCalendar.hoursText(totalHours))h（正常 \(WorkCalendar.hoursText(normalHours))h\(otText)，覆盖 \(loggedDays) 天），请在\(periodNoun == "本月" ? "月报" : "周报")中自然体现工时统计。"
        }
        return "本次\(periodNoun == "本月" ? "月报" : "周报")不展示具体工时数字。"
    }

    private static func formatDailyLogs(days: [DailyReportDay], includeHours: Bool, emptyMessage: String) -> String {
        var dailyLines: [String] = []
        for day in days where !day.items.isEmpty {
            let dayTotal = WorkCalendar.hoursText(day.totalHours)
            dailyLines.append("### \(day.dateString)（\(day.weekdayText)，合计 \(dayTotal)h）")
            for item in day.items {
                var tags: [String] = []
                if let pname = item.projectName, !pname.isEmpty {
                    tags.append(pname)
                }
                if let ttitle = item.taskTitle, !ttitle.isEmpty {
                    tags.append(ttitle)
                } else if let tid = item.taskID {
                    tags.append("任务 #\(tid)")
                }
                if item.isOvertime {
                    tags.append("加班")
                }
                if item.isDraft {
                    tags.append("草稿")
                }
                let headerPrefix = tags.isEmpty ? "" : "[\(tags.joined(separator: " / "))] "
                let hoursPart = includeHours ? "（\(WorkCalendar.hoursText(item.hours))h）" : ""
                let workBody = item.work.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "；")
                dailyLines.append("- \(headerPrefix)\(workBody)\(hoursPart)")
            }
            dailyLines.append("")
        }
        return dailyLines.isEmpty ? emptyMessage : dailyLines.joined(separator: "\n")
    }

    static func prompt(_ input: WeeklyReportInput) -> String {
        let weekRangeText = "\(input.week.title)（\(input.week.rangeText)）"
        let totalHoursText = formatHoursSummary(days: input.days, includeHours: input.includeHours, periodNoun: "本周")
        let dailyLogsText = formatDailyLogs(days: input.days, includeHours: input.includeHours, emptyMessage: "本周暂无已记录的每日日报。")
        let trimmedNotes = input.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraNotesText = trimmedNotes.isEmpty ? "无" : trimmedNotes

        return input.promptTemplate
            .replacingOccurrences(of: "{{weekRange}}", with: weekRangeText)
            .replacingOccurrences(of: "{{totalHours}}", with: totalHoursText)
            .replacingOccurrences(of: "{{styleInstruction}}", with: input.style.promptInstruction)
            .replacingOccurrences(of: "{{dailyLogs}}", with: dailyLogsText)
            .replacingOccurrences(of: "{{extraNotes}}", with: extraNotesText)
    }

    static func prompt(_ input: MonthlyReportInput) -> String {
        let monthRangeText = "\(input.month.title)（\(input.month.rangeText)）"
        let totalHoursText = formatHoursSummary(days: input.days, includeHours: input.includeHours, periodNoun: "本月")

        var monthlyLogsLines: [String] = []
        let daysByString = Dictionary(uniqueKeysWithValues: input.days.map { ($0.dateString, $0) })
        for slice in input.month.weeks {
            let sliceDays = slice.dayStrings.compactMap { daysByString[$0] }.filter { !$0.items.isEmpty }
            guard !sliceDays.isEmpty else { continue }
            let sliceHours = sliceDays.reduce(0.0) { $0 + $1.totalHours }
            let sliceHeader = input.includeHours
                ? "### \(slice.label)（\(slice.shortRangeText)，合计 \(WorkCalendar.hoursText(sliceHours))h）"
                : "### \(slice.label)（\(slice.shortRangeText)）"
            monthlyLogsLines.append(sliceHeader)
            for day in sliceDays {
                for item in day.items {
                    var tags: [String] = [day.dateString]
                    if let pname = item.projectName, !pname.isEmpty {
                        tags.append(pname)
                    }
                    if let ttitle = item.taskTitle, !ttitle.isEmpty {
                        tags.append(ttitle)
                    } else if let tid = item.taskID {
                        tags.append("任务 #\(tid)")
                    }
                    if item.isOvertime { tags.append("加班") }
                    if item.isDraft { tags.append("草稿") }
                    let hoursPart = input.includeHours ? "（\(WorkCalendar.hoursText(item.hours))h）" : ""
                    let workBody = item.work.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: "；")
                    monthlyLogsLines.append("- [\(tags.joined(separator: " / "))] \(workBody)\(hoursPart)")
                }
            }
            monthlyLogsLines.append("")
        }
        let dailyLogsText = monthlyLogsLines.isEmpty ? "本月暂无已记录的每日日报。" : monthlyLogsLines.joined(separator: "\n")

        let weeklyReportsText: String
        let nonEmptyWeeklies = input.weeklySummaries.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if nonEmptyWeeklies.isEmpty {
            weeklyReportsText = "无"
        } else {
            weeklyReportsText = nonEmptyWeeklies.map { record in
                "### \(record.title)（\(record.weekStart) ~ \(record.weekEnd)）\n\(record.content.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n\n")
        }

        let trimmedNotes = input.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraNotesText = trimmedNotes.isEmpty ? "无" : trimmedNotes

        return input.promptTemplate
            .replacingOccurrences(of: "{{monthRange}}", with: monthRangeText)
            .replacingOccurrences(of: "{{totalHours}}", with: totalHoursText)
            .replacingOccurrences(of: "{{styleInstruction}}", with: input.style.monthlyPromptInstruction)
            .replacingOccurrences(of: "{{dailyLogs}}", with: dailyLogsText)
            .replacingOccurrences(of: "{{weeklyReports}}", with: weeklyReportsText)
            .replacingOccurrences(of: "{{extraNotes}}", with: extraNotesText)
    }

    static func generate(_ input: WeeklyReportInput, provider: AIProviderConfig?) async -> WeeklyReportOutput {
        let fallback = fallbackReport(input)
        return await runGenerate(
            promptText: prompt(input),
            fallbackTitle: fallback.title,
            fallbackContent: fallback.content,
            emptyErrorText: "AI 返回周报正文为空",
            provider: provider
        )
    }

    static func generate(_ input: MonthlyReportInput, provider: AIProviderConfig?) async -> WeeklyReportOutput {
        let fallback = fallbackReport(input)
        return await runGenerate(
            promptText: prompt(input),
            fallbackTitle: fallback.title,
            fallbackContent: fallback.content,
            emptyErrorText: "AI 返回月报正文为空",
            provider: provider
        )
    }

    private static func runGenerate(
        promptText: String,
        fallbackTitle: String,
        fallbackContent: String,
        emptyErrorText: String,
        provider: AIProviderConfig?
    ) async -> WeeklyReportOutput {
        guard let provider, !provider.executablePath.isEmpty else {
            return WeeklyReportOutput(
                title: fallbackTitle,
                content: fallbackContent,
                usedAI: false,
                aiError: nil,
                aiSeconds: nil
            )
        }

        do {
            let result = try await AIRunner.run(
                config: provider,
                prompt: promptText,
                schema: schema
            )
            let decoded = try JSONDecoder().decode(AIResult.self, from: result.json)
            let cleanTitle = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanContent = decoded.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanContent.isEmpty else {
                return WeeklyReportOutput(
                    title: fallbackTitle,
                    content: fallbackContent,
                    usedAI: false,
                    aiError: emptyErrorText,
                    aiSeconds: result.duration
                )
            }
            return WeeklyReportOutput(
                title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                content: cleanContent,
                usedAI: true,
                aiError: nil,
                aiSeconds: result.duration
            )
        } catch {
            return WeeklyReportOutput(
                title: fallbackTitle,
                content: fallbackContent,
                usedAI: false,
                aiError: error.localizedDescription,
                aiSeconds: nil
            )
        }
    }

    static func fallbackReport(_ input: WeeklyReportInput) -> (title: String, content: String) {
        buildFallbackReport(
            title: defaultTitle(for: input.week),
            days: input.days,
            extraNotes: input.extraNotes,
            style: input.style,
            includeHours: input.includeHours,
            isMonthly: false
        )
    }

    static func fallbackReport(_ input: MonthlyReportInput) -> (title: String, content: String) {
        buildFallbackReport(
            title: defaultTitle(for: input.month),
            days: input.days,
            extraNotes: input.extraNotes,
            style: input.style,
            includeHours: input.includeHours,
            isMonthly: true
        )
    }

    private static func buildFallbackReport(
        title: String,
        days: [DailyReportDay],
        extraNotes: String,
        style: WeeklyReportStyle,
        includeHours: Bool,
        isMonthly: Bool
    ) -> (title: String, content: String) {
        let periodLabel = isMonthly ? "本月" : "本周"
        let nextPeriodLabel = isMonthly ? "下月" : "下周"

        struct ProjectBucket {
            let name: String
            var hours: Double = 0
            var points: [String] = []
        }

        var bucketIndex: [String: Int] = [:]
        var buckets: [ProjectBucket] = []

        for day in days {
            for item in day.items {
                let rawProject = item.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let projectName = rawProject.isEmpty ? "其他工作" : rawProject
                let idx: Int
                if let existing = bucketIndex[projectName] {
                    idx = existing
                } else {
                    idx = buckets.count
                    bucketIndex[projectName] = idx
                    buckets.append(ProjectBucket(name: projectName))
                }
                buckets[idx].hours += item.hours
                let points = extractWorkPoints(from: item.work)
                if points.isEmpty, let taskTitle = item.taskTitle, !taskTitle.isEmpty {
                    buckets[idx].points.append(taskTitle)
                } else {
                    buckets[idx].points.append(contentsOf: points)
                }
            }
        }

        for i in buckets.indices {
            buckets[i].points = deduplicatePoints(buckets[i].points)
        }

        let totalHours = days.reduce(0.0) { $0 + $1.totalHours }
        let normalHours = days.reduce(0.0) { $0 + $1.normalHours }
        let overtimeHours = days.reduce(0.0) { $0 + $1.overtimeHours }
        let loggedDays = days.filter { !$0.isEmpty }.count
        let trimmedNotes = extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []

        switch style {
        case .standard:
            let workHeading = isMonthly ? "## 本月重点成果" : "## 本周完成工作"
            var workLines: [String] = [workHeading, ""]
            if buckets.isEmpty {
                workLines.append("- \(periodLabel)暂无已记录的每日日报")
            } else {
                for bucket in buckets {
                    if buckets.count > 1 || bucket.name != "其他工作" {
                        let hoursSuffix = includeHours ? "（\(WorkCalendar.hoursText(bucket.hours))h）" : ""
                        workLines.append("### \(bucket.name)\(hoursSuffix)")
                    }
                    for (idx, point) in bucket.points.enumerated() {
                        workLines.append("\(idx + 1). \(point)")
                    }
                    workLines.append("")
                }
            }
            sections.append(workLines.joined(separator: "\n").trimmingCharacters(in: .newlines))

            if !trimmedNotes.isEmpty {
                sections.append("## 补充说明\n\n\(trimmedNotes)")
            }

            if includeHours {
                let hoursHeading = isMonthly ? "## 本月工时统计" : "## 工时统计"
                var hoursLines: [String] = [
                    hoursHeading,
                    "",
                    "- **总工时**：\(WorkCalendar.hoursText(totalHours)) h（覆盖 \(loggedDays) 天）",
                    "- **正常工时**：\(WorkCalendar.hoursText(normalHours)) h",
                ]
                if overtimeHours > 0 {
                    hoursLines.append("- **加班工时**：\(WorkCalendar.hoursText(overtimeHours)) h")
                }
                if !buckets.isEmpty {
                    let projectSummary = buckets.map { "\($0.name) \(WorkCalendar.hoursText($0.hours))h" }.joined(separator: "、")
                    hoursLines.append("- **项目分布**：\(projectSummary)")
                }
                sections.append(hoursLines.joined(separator: "\n"))
            }

            sections.append("## 问题与风险\n\n- 暂无")
            sections.append("## \(nextPeriodLabel)工作计划\n\n1. 待补充")

        case .byProject:
            if buckets.isEmpty {
                sections.append("## \(periodLabel)工作\n\n- \(periodLabel)暂无已记录的每日日报")
            } else {
                for bucket in buckets {
                    let hoursSuffix = includeHours ? "（\(WorkCalendar.hoursText(bucket.hours))h）" : ""
                    var lines: [String] = ["## \(bucket.name)\(hoursSuffix)", ""]
                    for (idx, point) in bucket.points.enumerated() {
                        lines.append("\(idx + 1). \(point)")
                    }
                    sections.append(lines.joined(separator: "\n"))
                }
            }
            if !trimmedNotes.isEmpty {
                sections.append("## 补充说明\n\n\(trimmedNotes)")
            }
            if includeHours {
                let otText = overtimeHours > 0 ? "，加班 \(WorkCalendar.hoursText(overtimeHours))h" : ""
                let summaryHeading = isMonthly ? "## 月度工时汇总" : "## 工时汇总"
                sections.append("\(summaryHeading)\n\n- 共投入 \(WorkCalendar.hoursText(totalHours))h（正常 \(WorkCalendar.hoursText(normalHours))h\(otText)，记录 \(loggedDays) 天）")
            }

        case .concise:
            var flatPoints: [String] = []
            let multiProject = buckets.count > 1
            for bucket in buckets {
                for point in bucket.points {
                    if multiProject {
                        flatPoints.append("[\(bucket.name)] \(point)")
                    } else {
                        flatPoints.append(point)
                    }
                }
            }
            flatPoints = deduplicatePoints(flatPoints)

            var lines: [String] = ["## \(periodLabel)工作要点", ""]
            if flatPoints.isEmpty {
                lines.append("- \(periodLabel)暂无已记录的每日日报")
            } else {
                for (idx, point) in flatPoints.enumerated() {
                    lines.append("\(idx + 1). \(point)")
                }
            }
            sections.append(lines.joined(separator: "\n"))

            if !trimmedNotes.isEmpty {
                sections.append("## 补充说明\n\n\(trimmedNotes)")
            }
            if includeHours {
                let otText = overtimeHours > 0 ? "，加班 \(WorkCalendar.hoursText(overtimeHours))h" : ""
                sections.append("**\(periodLabel)工时**：共 \(WorkCalendar.hoursText(totalHours))h（正常 \(WorkCalendar.hoursText(normalHours))h\(otText)，记录 \(loggedDays) 天）")
            }
        }

        return (title, sections.joined(separator: "\n\n"))
    }

    static func extractWorkPoints(from work: String) -> [String] {
        work.split(whereSeparator: \.isNewline)
            .map { line in
                String(line)
                    .replacingOccurrences(of: #"^\s*\d+[.、)）]\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s*[-*•]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    static func deduplicatePoints(_ points: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for point in points {
            let key = point.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !key.isEmpty && seen.insert(key).inserted {
                result.append(point)
            }
        }
        return result
    }
}
