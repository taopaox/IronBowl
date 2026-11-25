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

    static func prompt(_ input: WeeklyReportInput) -> String {
        let weekRangeText = "\(input.week.title)（\(input.week.rangeText)）"
        let totalHours = input.days.reduce(0.0) { $0 + $1.totalHours }
        let normalHours = input.days.reduce(0.0) { $0 + $1.normalHours }
        let overtimeHours = input.days.reduce(0.0) { $0 + $1.overtimeHours }
        let loggedDays = input.days.filter { !$0.isEmpty }.count

        let totalHoursText: String
        if input.includeHours {
            let otText = overtimeHours > 0 ? "，含加班 \(WorkCalendar.hoursText(overtimeHours))h" : ""
            totalHoursText = "本周累计 \(WorkCalendar.hoursText(totalHours))h（正常 \(WorkCalendar.hoursText(normalHours))h\(otText)，覆盖 \(loggedDays) 天），请在周报中自然体现工时统计。"
        } else {
            totalHoursText = "本次周报不展示具体工时数字。"
        }

        var dailyLines: [String] = []
        for day in input.days where !day.items.isEmpty {
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
                let hoursPart = input.includeHours ? "（\(WorkCalendar.hoursText(item.hours))h）" : ""
                let workBody = item.work.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "；")
                dailyLines.append("- \(headerPrefix)\(workBody)\(hoursPart)")
            }
            dailyLines.append("")
        }
        let dailyLogsText = dailyLines.isEmpty ? "本周暂无已记录的每日日报。" : dailyLines.joined(separator: "\n")

        let trimmedNotes = input.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraNotesText = trimmedNotes.isEmpty ? "无" : trimmedNotes

        return input.promptTemplate
            .replacingOccurrences(of: "{{weekRange}}", with: weekRangeText)
            .replacingOccurrences(of: "{{totalHours}}", with: totalHoursText)
            .replacingOccurrences(of: "{{styleInstruction}}", with: input.style.promptInstruction)
            .replacingOccurrences(of: "{{dailyLogs}}", with: dailyLogsText)
            .replacingOccurrences(of: "{{extraNotes}}", with: extraNotesText)
    }

    static func generate(_ input: WeeklyReportInput, provider: AIProviderConfig?) async -> WeeklyReportOutput {
        let fallback = fallbackReport(input)
        guard let provider, !provider.executablePath.isEmpty else {
            return WeeklyReportOutput(
                title: fallback.title,
                content: fallback.content,
                usedAI: false,
                aiError: nil,
                aiSeconds: nil
            )
        }

        do {
            let result = try await AIRunner.run(
                config: provider,
                prompt: prompt(input),
                schema: schema
            )
            let decoded = try JSONDecoder().decode(AIResult.self, from: result.json)
            let cleanTitle = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanContent = decoded.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanContent.isEmpty else {
                return WeeklyReportOutput(
                    title: fallback.title,
                    content: fallback.content,
                    usedAI: false,
                    aiError: "AI 返回周报正文为空",
                    aiSeconds: result.duration
                )
            }
            return WeeklyReportOutput(
                title: cleanTitle.isEmpty ? fallback.title : cleanTitle,
                content: cleanContent,
                usedAI: true,
                aiError: nil,
                aiSeconds: result.duration
            )
        } catch {
            return WeeklyReportOutput(
                title: fallback.title,
                content: fallback.content,
                usedAI: false,
                aiError: error.localizedDescription,
                aiSeconds: nil
            )
        }
    }

    static func fallbackReport(_ input: WeeklyReportInput) -> (title: String, content: String) {
        let title = defaultTitle(for: input.week)

        struct ProjectBucket {
            let name: String
            var hours: Double = 0
            var points: [String] = []
        }

        var bucketIndex: [String: Int] = [:]
        var buckets: [ProjectBucket] = []

        for day in input.days {
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

        let totalHours = input.days.reduce(0.0) { $0 + $1.totalHours }
        let normalHours = input.days.reduce(0.0) { $0 + $1.normalHours }
        let overtimeHours = input.days.reduce(0.0) { $0 + $1.overtimeHours }
        let loggedDays = input.days.filter { !$0.isEmpty }.count
        let trimmedNotes = input.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []

        switch input.style {
        case .standard:
            var workLines: [String] = ["## 本周完成工作", ""]
            if buckets.isEmpty {
                workLines.append("- 本周暂无已记录的每日日报")
            } else {
                for bucket in buckets {
                    if buckets.count > 1 || bucket.name != "其他工作" {
                        let hoursSuffix = input.includeHours ? "（\(WorkCalendar.hoursText(bucket.hours))h）" : ""
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

            if input.includeHours {
                var hoursLines: [String] = [
                    "## 工时统计",
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
            sections.append("## 下周工作计划\n\n1. 待补充")

        case .byProject:
            if buckets.isEmpty {
                sections.append("## 本周工作\n\n- 本周暂无已记录的每日日报")
            } else {
                for bucket in buckets {
                    let hoursSuffix = input.includeHours ? "（\(WorkCalendar.hoursText(bucket.hours))h）" : ""
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
            if input.includeHours {
                let otText = overtimeHours > 0 ? "，加班 \(WorkCalendar.hoursText(overtimeHours))h" : ""
                sections.append("## 工时汇总\n\n- 共投入 \(WorkCalendar.hoursText(totalHours))h（正常 \(WorkCalendar.hoursText(normalHours))h\(otText)，记录 \(loggedDays) 天）")
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

            var lines: [String] = ["## 本周工作要点", ""]
            if flatPoints.isEmpty {
                lines.append("- 本周暂无已记录的每日日报")
            } else {
                for (idx, point) in flatPoints.enumerated() {
                    lines.append("\(idx + 1). \(point)")
                }
            }
            sections.append(lines.joined(separator: "\n"))

            if !trimmedNotes.isEmpty {
                sections.append("## 补充说明\n\n\(trimmedNotes)")
            }
            if input.includeHours {
                let otText = overtimeHours > 0 ? "，加班 \(WorkCalendar.hoursText(overtimeHours))h" : ""
                sections.append("**本周工时**：共 \(WorkCalendar.hoursText(totalHours))h（正常 \(WorkCalendar.hoursText(normalHours))h\(otText)，记录 \(loggedDays) 天）")
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
