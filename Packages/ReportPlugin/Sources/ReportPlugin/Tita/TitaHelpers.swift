import Foundation

// MARK: - 周期日期编码

/// Tita 周报/月报周期日期编码（`YYYY-MM-WW` / `YYYY-MM-01`）与网页路由构造。
public nonisolated enum TitaPeriodCode {
    private static var gregorianCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    /// Tita 周报日期编码规则：以周一开始日期所在自然月归属，按该月内第几个周一（1-based）编码为 `YYYY-MM-WW`。
    public static func weeklySummaryDate(for week: WeekRange) -> String {
        let cal = gregorianCalendar
        let comps = cal.dateComponents([.year, .month, .day], from: week.startDate)
        let year = comps.year ?? week.isoYear
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let weekIndex = ((day - 1) / 7) + 1
        return String(format: "%04d-%02d-%02d", year, month, weekIndex)
    }

    /// `summary/status` 使用斜杠日期格式 `YYYY/MM/WW`。
    public static func weeklyStatusDate(for week: WeekRange) -> String {
        weeklySummaryDate(for: week).replacingOccurrences(of: "-", with: "/")
    }

    /// 月报编码为 `YYYY-MM-01`。
    public static func monthlySummaryDate(for month: MonthRange) -> String {
        String(format: "%04d-%02d-01", month.year, month.month)
    }

    /// 月报 `summary/status` 使用 `YYYY/MM/01`。
    public static func monthlyStatusDate(for month: MonthRange) -> String {
        String(format: "%04d/%02d/01", month.year, month.month)
    }

    public static func summaryDate(for periodKind: ReportPeriodKind, week: WeekRange, month: MonthRange) -> String {
        switch periodKind {
        case .weekly: weeklySummaryDate(for: week)
        case .monthly: monthlySummaryDate(for: month)
        }
    }

    public static func statusDate(for periodKind: ReportPeriodKind, week: WeekRange, month: MonthRange) -> String {
        switch periodKind {
        case .weekly: weeklyStatusDate(for: week)
        case .monthly: monthlyStatusDate(for: month)
        }
    }

    public static func todayStatusDate(_ date: Date = Date()) -> String {
        let cal = gregorianCalendar
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    /// 构造在浏览器直接打开对应 Tita 写周报/写月报页面的链接。
    public static func webEditorURL(
        baseURL: String,
        userID: String,
        periodKind: ReportPeriodKind,
        summaryDate: String,
        templateID: Int,
        isCreate: Bool
    ) -> URL? {
        var root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        guard !root.isEmpty else { return nil }
        let uid = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return URL(string: root) }
        let summaryType = TitaSummaryType(periodKind: periodKind)
        var query = "isCreate=\(isCreate ? "true" : "false")&hideNavTop=true&reportType=\(summaryType.rawValue)"
        if !isCreate {
            query += "&currentTime=\(summaryDate)"
        }
        query += "&templateId=\(templateID)&activeKey=\(summaryType.activeKey)"
        return URL(string: "\(root)/u/\(uid)/Home/#/summary/template?\(query)")
    }
}

// MARK: - 凭证解析（Cookie / 请求头 / cURL）

/// 解析用户从 Chrome DevTools 复制的 Cookie、原始请求头或 `Copy as cURL`。
public nonisolated enum TitaCredentialParser {
    public struct ParsedCredential: Sendable, Equatable {
        public var cookie: String
        public var tenantID: String?
        public var userID: String?
        public var baseURL: String?

        public init(cookie: String, tenantID: String? = nil, userID: String? = nil, baseURL: String? = nil) {
            self.cookie = cookie
            self.tenantID = tenantID
            self.userID = userID
            self.baseURL = baseURL
        }
    }

    public static func parse(_ raw: String) -> ParsedCredential {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ParsedCredential(cookie: "") }

        var tenantID: String?
        var userID: String?
        var baseURL: String?

        if let apiMatch = firstMatch(pattern: #"(https?://[^/\s'"]+)/api/v\d+/(\d+)/(\d+)/"#, in: trimmed) {
            baseURL = apiMatch[1]
            tenantID = apiMatch[2]
            userID = apiMatch[3]
        } else {
            if let rootMatch = firstMatch(pattern: #"(https?://[^/\s'"]*tita\.net)"#, in: trimmed) {
                baseURL = rootMatch[1]
            }
            if let userMatch = firstMatch(pattern: #"/u/(\d+)/"#, in: trimmed) {
                userID = userMatch[1]
            }
        }

        let normalizedCurl = trimmed
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")

        // 1. cURL `-b '...'` / `--cookie '...'`
        if let extracted = extractCurlQuotedOption(patterns: [
            #"(?:^|\s)(?:-b|--cookie)\s+'([^']+)'"#,
            #"(?:^|\s)(?:-b|--cookie)\s+"((?:\\.|[^"\\])*)""#,
        ], from: normalizedCurl) {
            return ParsedCredential(
                cookie: cleanCookieString(extracted),
                tenantID: tenantID,
                userID: userID,
                baseURL: baseURL
            )
        }

        // 2. cURL `-H 'cookie: ...'` / `--header 'Cookie: ...'`
        if let extracted = extractCurlQuotedOption(patterns: [
            #"(?:^|\s)(?:-H|--header)\s+'[Cc][Oo][Oo][Kk][Ii][Ee]\s*:\s*([^']+)'"#,
            #"(?:^|\s)(?:-H|--header)\s+"[Cc][Oo][Oo][Kk][Ii][Ee]\s*:\s*((?:\\.|[^"\\])*)""#,
        ], from: normalizedCurl) {
            return ParsedCredential(
                cookie: cleanCookieString(extracted),
                tenantID: tenantID,
                userID: userID,
                baseURL: baseURL
            )
        }

        // 3. 多行原始请求头里的 `Cookie: ...`
        for line in trimmed.components(separatedBy: .newlines) {
            let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = cleanLine.range(of: #"^[Cc][Oo][Oo][Kk][Ii][Ee]\s*:\s*"#, options: .regularExpression) {
                let candidate = String(cleanLine[range.upperBound...])
                return ParsedCredential(
                    cookie: cleanCookieString(candidate),
                    tenantID: tenantID,
                    userID: userID,
                    baseURL: baseURL
                )
            }
        }

        // 4. 纯 Cookie 键值对
        return ParsedCredential(
            cookie: cleanCookieString(trimmed),
            tenantID: tenantID,
            userID: userID,
            baseURL: baseURL
        )
    }

    private static func extractCurlQuotedOption(patterns: [String], from text: String) -> String? {
        for pattern in patterns {
            if let groups = firstMatch(pattern: pattern, in: text), groups.count > 1 {
                return groups[1]
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\'", with: "'")
            }
        }
        return nil
    }

    private static func cleanCookieString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            value.removeFirst()
            value.removeLast()
        }
        if let prefixRange = value.range(of: #"^[Cc][Oo][Oo][Kk][Ii][Ee]\s*:\s*"#, options: .regularExpression) {
            value = String(value[prefixRange.upperBound...])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { idx in
            let r = match.range(at: idx)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}

// MARK: - BSGlobal HTML 解析

/// 从 Tita 首页 HTML 的 `window.BSGlobal` 解析 `tenantId`、`userId` 与用户姓名。
public nonisolated enum TitaBSGlobalParser {
    public static func parse(html: String, finalURL: URL?) -> TitaAccountInfo? {
        let tenantID = extractNumberField(section: "tenantInfo", field: "Id", in: html) ?? ""
        var userID = extractNumberField(section: "loginUserInfo", field: "Id", in: html) ?? ""
        let userName = extractStringField(section: "loginUserInfo", field: "Name", in: html) ?? ""

        if userID.isEmpty, let urlText = finalURL?.absoluteString,
           let match = firstGroup(pattern: #"/u/(\d+)/"#, in: urlText) {
            userID = match
        }

        guard !tenantID.isEmpty, !userID.isEmpty else { return nil }
        return TitaAccountInfo(tenantID: tenantID, userID: userID, userName: decodeUnicodeEscapes(userName))
    }

    private static func extractNumberField(section: String, field: String, in html: String) -> String? {
        let pattern = #"(?:"?\#(section)"?\s*[:=]\s*\{[^}]{0,1200}?"?\#(field)"?\s*:\s*)(\d+)"#
        return firstGroup(pattern: pattern, in: html)
    }

    private static func extractStringField(section: String, field: String, in html: String) -> String? {
        let pattern = #"(?:"?\#(section)"?\s*[:=]\s*\{[^}]{0,1200}?"?\#(field)"?\s*:\s*"([^"]*)")"#
        return firstGroup(pattern: pattern, in: html)
    }

    private static func firstGroup(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func decodeUnicodeEscapes(_ text: String) -> String {
        guard text.contains("\\u") else { return text }
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, "Any-Hex/Java" as CFString, true)
        return mutable as String
    }
}

// MARK: - ProseMirror 富文本转换

/// 将 Markdown 报告段落转换为 Tita ProseMirror HTML 与纯文本。
public nonisolated enum TitaRichTextConverter {
    public struct ConvertedContent: Sendable, Equatable {
        public let plainText: String
        public let richText: String

        public init(plainText: String, richText: String) {
            self.plainText = plainText
            self.richText = richText
        }
    }

    public static func convert(markdown: String, maxPlainLength: Int = 10_000) -> ConvertedContent {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var htmlBlocks: [String] = []
        var plainLines: [String] = []

        enum ListKind { case ordered, unordered }
        var activeList: ListKind?
        var listItemsHTML: [String] = []

        func flushList() {
            guard let kind = activeList, !listItemsHTML.isEmpty else {
                activeList = nil
                listItemsHTML.removeAll()
                return
            }
            let tag = kind == .ordered ? "ol" : "ul"
            htmlBlocks.append("<\(tag)>\(listItemsHTML.joined())</\(tag)>")
            activeList = nil
            listItemsHTML.removeAll()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushList()
                if plainLines.last?.isEmpty == false {
                    plainLines.append("")
                }
                continue
            }

            if let headingRange = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushList()
                let body = String(line[headingRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { continue }
                htmlBlocks.append("<p style=\"text-align:left\"><strong>\(renderInlineHTML(stripOuterBold(body)))</strong></p>")
                plainLines.append(stripMarkdownInline(body))
                continue
            }

            if let orderedRange = line.range(of: #"^\d+[.)、]\s*"#, options: .regularExpression) {
                if activeList != .ordered {
                    flushList()
                    activeList = .ordered
                }
                let prefix = String(line[..<orderedRange.upperBound]).trimmingCharacters(in: .whitespaces)
                let body = String(line[orderedRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                listItemsHTML.append("<li class=\"tita-rich-editor-li\"><p style=\"text-align:left\">\(renderInlineHTML(body))</p></li>")
                plainLines.append("\(prefix) \(stripMarkdownInline(body))")
                continue
            }

            if let bulletRange = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                if activeList != .unordered {
                    flushList()
                    activeList = .unordered
                }
                let body = String(line[bulletRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                listItemsHTML.append("<li class=\"tita-rich-editor-li\"><p style=\"text-align:left\">\(renderInlineHTML(body))</p></li>")
                plainLines.append("• \(stripMarkdownInline(body))")
                continue
            }

            flushList()
            htmlBlocks.append("<p style=\"text-align:left\">\(renderInlineHTML(line))</p>")
            plainLines.append(stripMarkdownInline(line))
        }

        flushList()

        while plainLines.last?.isEmpty == true {
            plainLines.removeLast()
        }

        var plainText = plainLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if plainText.count > maxPlainLength {
            plainText = String(plainText.prefix(maxPlainLength))
        }

        let richText = htmlBlocks.isEmpty ? "<p style=\"text-align:left\"></p>" : htmlBlocks.joined()
        return ConvertedContent(plainText: plainText, richText: richText)
    }

    /// 当远端模块仅返回 `richText` 时提取可读纯文本用于展示或回填编辑。
    public static func plainTextFromHTML(_ html: String) -> String {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var text = html
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</p\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</li\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</h[1-6]\s*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        let cleanedLines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in cleanedLines {
            if line.isEmpty {
                if result.last?.isEmpty == false {
                    result.append("")
                }
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripOuterBold(_ text: String) -> String {
        if text.hasPrefix("**"), text.hasSuffix("**"), text.count > 4 {
            return String(text.dropFirst(2).dropLast(2))
        }
        return text
    }

    private static func stripMarkdownInline(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
    }

    private static func renderInlineHTML(_ text: String) -> String {
        var escaped = escapeHTML(text)
        escaped = replaceRegex(escaped, pattern: #"\*\*(.+?)\*\*"#, template: "<strong>$1</strong>")
        escaped = replaceRegex(escaped, pattern: #"`([^`]+)`"#, template: "<code>$1</code>")
        return escaped
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replaceRegex(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

// MARK: - 报告内容到 Tita 模块拆分

/// 将 IronBowl 生成的 Markdown 报告自动拆分映射到 Tita 的多个富文本模块。
public nonisolated enum TitaContentMapper {
    public static let defaultModuleNames: [String] = [
        "工作总结（亮点与成功经验）",
        "工作总结（问题与不足）",
        "工作总结（改进思考与行动）",
        "下一步工作计划",
    ]

    private enum SemanticBucket: Hashable {
        case highlights
        case problems
        case improvement
        case plan
    }

    public static func map(markdown: String, toModules moduleNames: [String]) -> [String] {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !moduleNames.isEmpty else { return [] }
        if moduleNames.count == 1 {
            return [trimmed]
        }
        guard !trimmed.isEmpty else {
            return Array(repeating: "", count: moduleNames.count)
        }

        let sections = splitByLevelTwoHeadings(trimmed)
        var grouped: [SemanticBucket: [String]] = [:]

        for section in sections {
            let bucket = classifyHeading(section.heading)
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            let shouldKeepSubheading: Bool = {
                guard let h = section.heading else { return false }
                switch bucket {
                case .highlights:
                    return !isGenericHighlightsHeading(h) && sections.count > 1
                case .problems, .improvement, .plan:
                    return false
                }
            }()

            if shouldKeepSubheading, let h = section.heading {
                grouped[bucket, default: []].append("### \(h)\n\(body)")
            } else {
                grouped[bucket, default: []].append(body)
            }
        }

        var usedBuckets = Set<SemanticBucket>()
        var outputs = Array(repeating: "", count: moduleNames.count)

        for (index, name) in moduleNames.enumerated() {
            let bucket = classifyModuleName(name)
            usedBuckets.insert(bucket)
            if let parts = grouped[bucket], !parts.isEmpty {
                outputs[index] = parts.joined(separator: "\n\n")
            }
        }

        // 若某些分段未命中目标模块关键词，则兜底合并到第一个“总结/亮点”模块，避免遗漏内容。
        let unmatched = grouped.filter { !usedBuckets.contains($0.key) }.flatMap(\.value)
        if !unmatched.isEmpty {
            let targetIndex = moduleNames.firstIndex { classifyModuleName($0) == .highlights } ?? 0
            let existing = outputs[targetIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let merged = ([existing] + unmatched).filter { !$0.isEmpty }.joined(separator: "\n\n")
            outputs[targetIndex] = merged
        }

        return outputs
    }

    private struct MarkdownSection {
        let heading: String?
        let body: String
    }

    private static func splitByLevelTwoHeadings(_ markdown: String) -> [MarkdownSection] {
        let lines = markdown.components(separatedBy: .newlines)
        var sections: [MarkdownSection] = []
        var currentHeading: String?
        var currentLines: [String] = []

        func flush() {
            let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if currentHeading != nil || !body.isEmpty {
                sections.append(MarkdownSection(heading: currentHeading, body: body))
            }
            currentLines.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                flush()
                currentHeading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("# ") && currentHeading == nil && sections.isEmpty && currentLines.isEmpty {
                // 跳过顶层报告大标题（如有）
                continue
            } else {
                currentLines.append(rawLine)
            }
        }
        flush()
        return sections
    }

    private static func classifyHeading(_ heading: String?) -> SemanticBucket {
        guard let h = heading else { return .highlights }
        if containsAny(h, ["计划", "下一步", "下周", "下月", "规划"]) {
            return .plan
        }
        if containsAny(h, ["改进", "思考", "行动", "反思", "优化方向"]) {
            return .improvement
        }
        if containsAny(h, ["问题", "不足", "风险", "阻塞", "困难"]) {
            return .problems
        }
        return .highlights
    }

    private static func classifyModuleName(_ name: String) -> SemanticBucket {
        if containsAny(name, ["计划", "下一步", "下周", "下月"]) {
            return .plan
        }
        if containsAny(name, ["改进", "思考", "行动"]) {
            return .improvement
        }
        if containsAny(name, ["问题", "不足", "风险"]) {
            return .problems
        }
        return .highlights
    }

    private static func isGenericHighlightsHeading(_ heading: String) -> Bool {
        containsAny(heading, ["亮点", "成功经验", "完成工作", "重点成果", "工作要点", "本周工作", "本月工作"])
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - 提交请求体拼装

/// 依据 `summary/detail` 与修改后的富文本内容拼装 `summary/submit/{feedId}/{isCallBack}` 请求体。
public nonisolated enum TitaSubmitPayloadBuilder {
    public static func buildSubmitBody(
        detail: TitaReportDetail,
        updatedRichTexts: [Int: TitaRichTextConverter.ConvertedContent]
    ) throws -> [String: Any] {
        var okrModuleValue = ""
        var workModuleValue = ""
        var taskModuleValue = ""
        var dfsModuleValue = ""
        var atModuleValue = ""
        var moduleRichValues: [String] = []

        let activeModules = detail.modules.filter { !$0.isDelete }.sorted { $0.sortIndex < $1.sortIndex }
        for module in activeModules {
            switch module.moduleObjType {
            case 2:
                okrModuleValue = module.rawObjectDataJSON
            case 6:
                workModuleValue = module.rawObjectDataJSON
            case 3:
                taskModuleValue = module.rawObjectDataJSON
            case 4:
                dfsModuleValue = module.rawObjectDataJSON
            case 5:
                atModuleValue = module.rawObjectDataJSON
            case 0 where module.moduleType == "richtext":
                let content = updatedRichTexts[module.moduleId] ?? TitaRichTextConverter.ConvertedContent(
                    plainText: module.plainText,
                    richText: module.richTextHTML
                )
                let dict: [String: Any] = [
                    "text": content.plainText,
                    "mensions": [Any](),
                    "tasks": [Any](),
                    "richText": content.richText,
                ]
                let data = try JSONSerialization.data(withJSONObject: dict, options: [])
                moduleRichValues.append(String(decoding: data, as: UTF8.self))
            default:
                break
            }
        }

        return [
            "OKRModuleValue": okrModuleValue,
            "WorkModuleValue": workModuleValue,
            "TaskModuleValue": taskModuleValue,
            "DfsModuleValue": dfsModuleValue,
            "AtModuleValue": atModuleValue,
            "ModuleRichValues": moduleRichValues,
        ]
    }
}
