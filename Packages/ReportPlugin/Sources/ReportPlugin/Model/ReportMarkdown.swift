import Foundation
import SwiftUI

/// 周报 / 月报预览使用的 Markdown 块级节点。
public nonisolated enum ReportMarkdownBlock: Sendable, Identifiable, Equatable {
    case heading(id: Int, level: Int, text: String)
    case bullet(id: Int, indentLevel: Int, marker: String, text: String)
    case blockquote(id: Int, text: String)
    case codeBlock(id: Int, code: String)
    case divider(id: Int)
    case paragraph(id: Int, text: String)

    public var id: Int {
        switch self {
        case .heading(let id, _, _),
             .bullet(let id, _, _, _),
             .blockquote(let id, _),
             .codeBlock(let id, _),
             .divider(let id),
             .paragraph(let id, _):
            id
        }
    }
}

private nonisolated final class ReportMarkdownCache: @unchecked Sendable {
    static let shared = ReportMarkdownCache()

    private let lock = NSLock()
    private let maxBlocksEntries = 64
    private let maxInlineEntries = 512

    private var blocksCache: [String: [ReportMarkdownBlock]] = [:]
    private var blocksOrder: [String] = []
    private var inlineCache: [String: AttributedString] = [:]
    private var inlineOrder: [String] = []

    func blocks(for markdown: String) -> [ReportMarkdownBlock]? {
        lock.lock()
        defer { lock.unlock() }
        return blocksCache[markdown]
    }

    func storeBlocks(_ blocks: [ReportMarkdownBlock], for markdown: String) {
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

/// 面向中文与嵌套列表的轻量 Markdown 解析器（解决 CommonMark 标点相邻 `**加粗**` 失效问题）。
public nonisolated enum ReportMarkdown {
    public static func parseBlocks(_ markdown: String) -> [ReportMarkdownBlock] {
        if let cached = ReportMarkdownCache.shared.blocks(for: markdown) {
            return cached
        }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [ReportMarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []
        var codeBuffer: [String] = []
        var inCodeBlock = false

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
            if !joined.isEmpty {
                out.append(.codeBlock(id: out.count, code: joined))
            }
            codeBuffer.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                if inCodeBlock {
                    flushCodeBlock()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBuffer.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                flushQuote()
                out.append(.divider(id: out.count))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let quoteText = trimmed == ">" ? "" : String(trimmed.dropFirst(2))
                quoteBuffer.append(quoteText)
                continue
            } else {
                flushQuote()
            }

            if let headingMatch = parseHeading(trimmed) {
                flushParagraph()
                out.append(.heading(id: out.count, level: headingMatch.level, text: headingMatch.text))
                continue
            }

            let indentLevel = computeIndentLevel(rawLine)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                out.append(.bullet(id: out.count, indentLevel: indentLevel, marker: "•", text: String(trimmed.dropFirst(2))))
            } else if let dotRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph()
                let num = trimmed[..<dotRange.upperBound].trimmingCharacters(in: .whitespaces)
                let content = String(trimmed[dotRange.upperBound...])
                out.append(.bullet(id: out.count, indentLevel: indentLevel, marker: num, text: content))
            } else {
                paragraphBuffer.append(trimmed)
            }
        }

        if inCodeBlock {
            flushCodeBlock()
        }
        flushQuote()
        flushParagraph()
        ReportMarkdownCache.shared.storeBlocks(out, for: markdown)
        return out
    }

    /// 解析行内 Markdown（支持 `**加粗**`、`*斜体*`、`` `代码` ``、`~~删除线~~`、`[链接](url)`，无中文标点边界限制）。
    public static func attributedInline(_ text: String) -> AttributedString {
        if let cached = ReportMarkdownCache.shared.inline(for: text) {
            return cached
        }
        let parsed = parseAttributedInline(text)
        ReportMarkdownCache.shared.storeInline(parsed, for: text)
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

            // 转义字符
            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, "*_`~\\[]".contains(text[next]) {
                    plainBuffer.append(text[next])
                    index = text.index(after: next)
                    continue
                }
            }

            // 行内代码 `code`
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

            // 链接 [label](url)
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

            // 加粗 **...** 或 __...__
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

            // 删除线 ~~...~~
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

            // 斜体 *...*（单个星号，且首尾不为空白）
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
        for level in 1...4 {
            let prefix = String(repeating: "#", count: level) + " "
            if trimmedLine.hasPrefix(prefix) {
                return (level, String(trimmedLine.dropFirst(prefix.count)))
            }
        }
        return nil
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
