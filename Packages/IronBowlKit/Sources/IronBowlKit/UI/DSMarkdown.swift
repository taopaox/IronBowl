import AppKit
import SwiftUI

/// 通用 Markdown 块级节点（支持标题、列表/任务清单、引用、代码块、表格、分隔线与段落）。
public nonisolated enum DSMarkdownBlock: Sendable, Identifiable, Equatable {
    case heading(id: Int, level: Int, text: String)
    case bullet(id: Int, indentLevel: Int, marker: String, text: String, checked: Bool?)
    case blockquote(id: Int, text: String)
    case codeBlock(id: Int, language: String, code: String)
    case table(id: Int, headers: [String], rows: [[String]])
    case divider(id: Int)
    case paragraph(id: Int, text: String)

    public var id: Int {
        switch self {
        case .heading(let id, _, _),
             .bullet(let id, _, _, _, _),
             .blockquote(let id, _),
             .codeBlock(let id, _, _),
             .table(let id, _, _),
             .divider(let id),
             .paragraph(let id, _):
            id
        }
    }
}

private nonisolated final class DSMarkdownCache: @unchecked Sendable {
    static let shared = DSMarkdownCache()

    private let lock = NSLock()
    private let maxBlocksEntries = 64
    private let maxInlineEntries = 512

    private var blocksCache: [String: [DSMarkdownBlock]] = [:]
    private var blocksOrder: [String] = []
    private var inlineCache: [String: AttributedString] = [:]
    private var inlineOrder: [String] = []

    func blocks(for markdown: String) -> [DSMarkdownBlock]? {
        lock.lock()
        defer { lock.unlock() }
        return blocksCache[markdown]
    }

    func storeBlocks(_ blocks: [DSMarkdownBlock], for markdown: String) {
        guard markdown.utf8.count <= 200_000 else { return }
        lock.lock()
        defer { lock.unlock() }
        if blocksCache[markdown] == nil {
            if blocksOrder.count >= maxBlocksEntries, let evicted = blocksOrder.first {
                blocksOrder.removeFirst()
                blocksCache.removeValue(forKey: evicted)
            }
            blocksOrder.append(markdown)
        }
        blocksCache[markdown] = blocks
    }

    func inline(for text: String) -> AttributedString? {
        lock.lock()
        defer { lock.unlock() }
        return inlineCache[text]
    }

    func storeInline(_ attributed: AttributedString, for text: String) {
        guard text.utf8.count <= 32_000 else { return }
        lock.lock()
        defer { lock.unlock() }
        if inlineCache[text] == nil {
            if inlineOrder.count >= maxInlineEntries, let evicted = inlineOrder.first {
                inlineOrder.removeFirst()
                inlineCache.removeValue(forKey: evicted)
            }
            inlineOrder.append(text)
        }
        inlineCache[text] = attributed
    }
}

/// 面向中文与对话输出场景的轻量 Markdown 解析器（支持表格、任务列表，且无中文标点相邻加粗失效问题）。
public nonisolated enum DSMarkdown {
    public static func parseBlocks(_ markdown: String) -> [DSMarkdownBlock] {
        if let cached = DSMarkdownCache.shared.blocks(for: markdown) {
            return cached
        }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [DSMarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCodeBlock = false
        var codeLanguage = ""

        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                out.append(.paragraph(id: out.count, text: joined))
            }
            paragraphBuffer.removeAll()
        }

        func flushQuote() {
            let joined = quoteBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                out.append(.blockquote(id: out.count, text: joined))
            }
            quoteBuffer.removeAll()
        }

        func flushCodeBlock() {
            let joined = codeBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            out.append(.codeBlock(id: out.count, language: codeLanguage, code: joined))
            codeBuffer.removeAll()
            codeLanguage = ""
        }

        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                if inCodeBlock {
                    flushCodeBlock()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                index += 1
                continue
            }

            if inCodeBlock {
                codeBuffer.append(rawLine)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                index += 1
                continue
            }

            // GFM 表格：header 行含 `|`，且下一行是 `| --- |` 分隔行
            if index + 1 < lines.count,
               let headers = parseTableRow(trimmed),
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces), expectedColumns: headers.count) {
                flushParagraph()
                flushQuote()
                var rows: [[String]] = []
                var rowIndex = index + 2
                while rowIndex < lines.count {
                    let rowTrimmed = lines[rowIndex].trimmingCharacters(in: .whitespaces)
                    guard !rowTrimmed.isEmpty,
                          rowTrimmed.contains("|"),
                          let cells = parseTableRow(rowTrimmed) else {
                        break
                    }
                    let normalized = normalizeRow(cells, columnCount: headers.count)
                    rows.append(normalized)
                    rowIndex += 1
                }
                out.append(.table(id: out.count, headers: headers, rows: rows))
                index = rowIndex
                continue
            }

            if isDividerLine(trimmed) {
                flushParagraph()
                flushQuote()
                out.append(.divider(id: out.count))
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let quoteText = trimmed == ">" ? "" : String(trimmed.dropFirst(2))
                quoteBuffer.append(quoteText)
                index += 1
                continue
            } else {
                flushQuote()
            }

            if let headingMatch = parseHeading(trimmed) {
                flushParagraph()
                out.append(.heading(id: out.count, level: headingMatch.level, text: headingMatch.text))
                index += 1
                continue
            }

            let indentLevel = computeIndentLevel(rawLine)
            if let bullet = parseBullet(trimmed, indentLevel: indentLevel, nextID: out.count) {
                flushParagraph()
                out.append(bullet)
                index += 1
                continue
            }

            paragraphBuffer.append(rawLine.trimmingCharacters(in: .newlines))
            index += 1
        }

        if inCodeBlock {
            flushCodeBlock()
        }
        flushQuote()
        flushParagraph()
        DSMarkdownCache.shared.storeBlocks(out, for: markdown)
        return out
    }

    /// 解析行内 Markdown（支持 `**加粗**`、`__加粗__`、`*斜体*`、`` `代码` ``、`~~删除线~~`、`[链接](url)`，无中文标点边界限制）。
    public static func attributedInline(_ text: String) -> AttributedString {
        if let cached = DSMarkdownCache.shared.inline(for: text) {
            return cached
        }
        let parsed = parseAttributedInline(text)
        DSMarkdownCache.shared.storeInline(parsed, for: text)
        return parsed
    }

    private static func parseAttributedInline(_ text: String) -> AttributedString {
        var result = AttributedString()
        var plainBuffer = ""
        var index = text.startIndex

        func flushPlain() {
            guard !plainBuffer.isEmpty else { return }
            result.append(AttributedString(plainBuffer))
            plainBuffer.removeAll()
        }

        while index < text.endIndex {
            let ch = text[index]

            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, "*_`~\\[]".contains(text[next]) {
                    plainBuffer.append(text[next])
                    index = text.index(after: next)
                    continue
                }
            }

            if ch == "`" {
                let contentStart = text.index(after: index)
                if let closeIdx = text[contentStart...].firstIndex(of: "`"), closeIdx > contentStart {
                    flushPlain()
                    var run = AttributedString(String(text[contentStart..<closeIdx]))
                    run.inlinePresentationIntent = .code
                    result.append(run)
                    index = text.index(after: closeIdx)
                    continue
                }
            }

            if ch == "[", let link = parseLink(in: text, from: index) {
                flushPlain()
                var inner = attributedInline(link.label)
                if let url = URL(string: link.url) {
                    inner.link = url
                }
                result.append(inner)
                index = link.nextIndex
                continue
            }

            if (ch == "*" || ch == "_"),
               let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex,
               text[next] == ch {
                let delimiter = ch == "*" ? "**" : "__"
                let contentStart = text.index(index, offsetBy: 2)
                if let closeRange = findClosingDoubleDelimiter(delimiter, in: text, from: contentStart),
                   closeRange.lowerBound > contentStart {
                    let innerText = String(text[contentStart..<closeRange.lowerBound])
                    if !innerText.trimmingCharacters(in: .whitespaces).isEmpty {
                        flushPlain()
                        var inner = attributedInline(innerText)
                        applyPresentationIntent(.stronglyEmphasized, to: &inner)
                        result.append(inner)
                        index = closeRange.upperBound
                        continue
                    }
                }
            }

            if ch == "~",
               let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex,
               text[next] == "~" {
                let contentStart = text.index(index, offsetBy: 2)
                if let closeRange = text.range(of: "~~", range: contentStart..<text.endIndex),
                   closeRange.lowerBound > contentStart {
                    flushPlain()
                    var inner = attributedInline(String(text[contentStart..<closeRange.lowerBound]))
                    inner.strikethroughStyle = .single
                    result.append(inner)
                    index = closeRange.upperBound
                    continue
                }
            }

            if ch == "*" {
                let contentStart = text.index(after: index)
                if contentStart < text.endIndex,
                   !text[contentStart].isWhitespace,
                   text[contentStart] != "*",
                   let closeIdx = findClosingSingleAsterisk(in: text, from: contentStart) {
                    flushPlain()
                    var inner = attributedInline(String(text[contentStart..<closeIdx]))
                    applyPresentationIntent(.emphasized, to: &inner)
                    result.append(inner)
                    index = text.index(after: closeIdx)
                    continue
                }
            }

            plainBuffer.append(ch)
            index = text.index(after: index)
        }

        flushPlain()
        return result
    }

    // MARK: - 内部解析辅助

    private static func isDividerLine(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func computeIndentLevel(_ rawLine: String) -> Int {
        var spaces = 0
        for ch in rawLine {
            if ch == " " {
                spaces += 1
            } else if ch == "\t" {
                spaces += 2
            } else {
                break
            }
        }
        return min(4, spaces / 2)
    }

    private static func parseHeading(_ trimmedLine: String) -> (level: Int, text: String)? {
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level) + " "
            if trimmedLine.hasPrefix(prefix) {
                return (level, String(trimmedLine.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func parseBullet(_ trimmed: String, indentLevel: Int, nextID: Int) -> DSMarkdownBlock? {
        let unorderedPrefixes = ["- ", "* ", "+ ", "• "]
        for prefix in unorderedPrefixes where trimmed.hasPrefix(prefix) {
            let body = String(trimmed.dropFirst(prefix.count))
            if body.hasPrefix("[ ] ") {
                return .bullet(id: nextID, indentLevel: indentLevel, marker: "•", text: String(body.dropFirst(4)), checked: false)
            }
            if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                return .bullet(id: nextID, indentLevel: indentLevel, marker: "•", text: String(body.dropFirst(4)), checked: true)
            }
            return .bullet(id: nextID, indentLevel: indentLevel, marker: "•", text: body, checked: nil)
        }
        if let dotRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let num = trimmed[..<dotRange.upperBound].trimmingCharacters(in: .whitespaces)
            let content = String(trimmed[dotRange.upperBound...])
            return .bullet(id: nextID, indentLevel: indentLevel, marker: num, text: content, checked: nil)
        }
        return nil
    }

    private static func parseTableRow(_ trimmed: String) -> [String]? {
        guard trimmed.contains("|") else { return nil }
        var inner = trimmed
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        let parts = inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        return parts
    }

    private static func isTableSeparator(_ trimmed: String, expectedColumns: Int) -> Bool {
        guard let cells = parseTableRow(trimmed), cells.count == expectedColumns else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: ":", with: "")
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }
    }

    private static func normalizeRow(_ cells: [String], columnCount: Int) -> [String] {
        if cells.count == columnCount { return cells }
        if cells.count > columnCount { return Array(cells.prefix(columnCount)) }
        return cells + Array(repeating: "", count: columnCount - cells.count)
    }

    private static func findClosingDoubleDelimiter(
        _ delimiter: String,
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var cursor = start
        while cursor < text.endIndex {
            guard let found = text.range(of: delimiter, range: cursor..<text.endIndex) else {
                return nil
            }
            if isEscaped(at: found.lowerBound, in: text) {
                cursor = text.index(after: found.lowerBound)
                continue
            }
            return found
        }
        return nil
    }

    private static func findClosingSingleAsterisk(in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch == "*" && !isEscaped(at: cursor, in: text) {
                let next = text.index(after: cursor)
                if next < text.endIndex && text[next] == "*" {
                    cursor = text.index(after: next)
                    continue
                }
                let prev = text.index(before: cursor)
                if cursor > start && !text[prev].isWhitespace {
                    return cursor
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func parseLink(
        in text: String,
        from bracketStart: String.Index
    ) -> (label: String, url: String, nextIndex: String.Index)? {
        let labelStart = text.index(after: bracketStart)
        guard let closeBracket = text[labelStart...].firstIndex(of: "]"),
              !isEscaped(at: closeBracket, in: text) else {
            return nil
        }
        let openParen = text.index(after: closeBracket)
        guard openParen < text.endIndex, text[openParen] == "(" else {
            return nil
        }
        let urlStart = text.index(after: openParen)
        guard let closeParen = text[urlStart...].firstIndex(of: ")") else {
            return nil
        }
        let urlString = String(text[urlStart..<closeParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return nil }
        let label = String(text[labelStart..<closeBracket])
        return (label, urlString, text.index(after: closeParen))
    }

    private static func isEscaped(at index: String.Index, in text: String) -> Bool {
        var backslashes = 0
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if text[cursor] == "\\" {
                backslashes += 1
            } else {
                break
            }
        }
        return backslashes % 2 == 1
    }

    private static func applyPresentationIntent(_ intent: InlinePresentationIntent, to attributed: inout AttributedString) {
        for run in attributed.runs {
            var current = run.inlinePresentationIntent ?? []
            current.insert(intent)
            attributed[run.range].inlinePresentationIntent = current
        }
    }
}

// MARK: - SwiftUI 渲染视图

/// 统一工作台 Markdown 渲染组件（支持块级排版、表格、任务列表与代码块复制）。
public struct DSMarkdownView: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    private var blocks: [DSMarkdownBlock] {
        DSMarkdown.parseBlocks(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                DSMarkdownBlockRow(block: block)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DSMarkdownBlockRow: View, Equatable {
    let block: DSMarkdownBlock

    var body: some View {
        switch block {
        case .heading(_, let level, let content):
            Text(DSMarkdown.attributedInline(content))
                .font(headingFont(level: level))
                .foregroundStyle(DS.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 6 : 3)

        case .bullet(_, let indentLevel, let marker, let content, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(DS.font(13))
                        .foregroundStyle(checked ? DS.success : DS.textTertiary)
                        .frame(width: DS.s(15), alignment: .center)
                } else {
                    Text(marker)
                        .font(DS.font(13.5, .semibold))
                        .foregroundStyle(DS.textSecondary)
                        .frame(minWidth: DS.s(14), alignment: marker == "•" ? .center : .trailing)
                }
                Text(DSMarkdown.attributedInline(content))
                    .font(DS.body)
                    .foregroundStyle(checked == true ? DS.textSecondary : DS.text)
                    .strikethrough(checked == true)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indentLevel) * 16)

        case .blockquote(_, let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DS.brand.opacity(0.65))
                    .frame(width: 3)
                Text(DSMarkdown.attributedInline(content))
                    .font(DS.body)
                    .foregroundStyle(DS.textSecondary)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.well.opacity(0.65), in: .rect(cornerRadius: 8))

        case .codeBlock(_, let language, let code):
            DSMarkdownCodeCard(language: language, code: code)

        case .table(_, let headers, let rows):
            DSMarkdownTableCard(headers: headers, rows: rows)

        case .divider:
            Divider().overlay(DS.borderStrong).padding(.vertical, 4)

        case .paragraph(_, let content):
            Text(DSMarkdown.attributedInline(content))
                .font(DS.body)
                .foregroundStyle(DS.text)
                .lineSpacing(3.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: DS.font(20, .bold)
        case 2: DS.font(17.5, .semibold)
        case 3: DS.font(15.5, .semibold)
        default: DS.font(14.5, .semibold)
        }
    }
}

private struct DSMarkdownCodeCard: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language)
                    .font(DS.font(11.5, .medium))
                    .foregroundStyle(DS.textSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(DS.font(11))
                        .foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DS.well)

            Divider().overlay(DS.border)

            ScrollView(.horizontal) {
                Text(code)
                    .font(DS.mono(12))
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.card, in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(DS.border) }
    }
}

private struct DSMarkdownTableCard: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { colIndex, cell in
                        Text(DSMarkdown.attributedInline(cell))
                            .font(DS.font(13, .semibold))
                            .foregroundStyle(DS.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(minWidth: 96, maxWidth: 260, alignment: .leading)
                            .background(DS.well)
                            .overlay(alignment: .trailing) {
                                if colIndex < headers.count - 1 {
                                    Rectangle().fill(DS.border).frame(width: 1)
                                }
                            }
                    }
                }

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(DS.border)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            Text(DSMarkdown.attributedInline(cell))
                                .font(DS.font(13))
                                .foregroundStyle(DS.text)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(minWidth: 96, maxWidth: 260, alignment: .leading)
                                .overlay(alignment: .trailing) {
                                    if colIndex < row.count - 1 {
                                        Rectangle().fill(DS.border).frame(width: 1)
                                    }
                                }
                        }
                    }
                }
            }
            .background(DS.card)
        }
        .clipShape(.rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(DS.border) }
    }
}
