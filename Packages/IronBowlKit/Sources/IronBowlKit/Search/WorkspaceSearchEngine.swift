import Foundation
import GRDB

/// 跨模块历史全文检索结果来源。
public nonisolated enum WorkspaceSearchSource: String, Codable, Sendable, CaseIterable {
    case dailyLog
    case dailyDraft
    case weeklyReport
    case monthlyReport
    case annualReview
    case todo
    case scratchpad
    case clipboard
    case chat

    public var displayName: String {
        switch self {
        case .dailyLog: "日报"
        case .dailyDraft: "日报草稿"
        case .weeklyReport: "周报"
        case .monthlyReport: "月报"
        case .annualReview: "述职"
        case .todo: "待办"
        case .scratchpad: "便签"
        case .clipboard: "剪贴板"
        case .chat: "对话"
        }
    }

    public var systemImage: String {
        switch self {
        case .dailyLog, .dailyDraft: "square.and.pencil"
        case .weeklyReport: "doc.text"
        case .monthlyReport: "doc.richtext"
        case .annualReview: "chart.bar.doc.horizontal"
        case .todo: "checklist"
        case .scratchpad: "note.text"
        case .clipboard: "doc.on.clipboard"
        case .chat: "bubble.left.and.bubble.right"
        }
    }

    public var defaultPluginID: String {
        switch self {
        case .dailyLog, .dailyDraft: "zentao.log"
        case .weeklyReport: "report"
        case .monthlyReport: "report.monthly"
        case .annualReview: "report.annual"
        case .todo: "todo"
        case .scratchpad, .clipboard: "scratchpad"
        case .chat: "home"
        }
    }
}

/// 跨模块全文搜索的单条命中记录。
public nonisolated struct WorkspaceSearchHit: Identifiable, Sendable, Equatable {
    public let id: String
    public let source: WorkspaceSearchSource
    public let title: String
    public let snippet: String
    public let dateText: String?
    public let targetPluginID: String
    public let copyText: String?
    public let chatThreadID: String?
    public let score: Int

    public init(
        id: String,
        source: WorkspaceSearchSource,
        title: String,
        snippet: String,
        dateText: String? = nil,
        targetPluginID: String? = nil,
        copyText: String? = nil,
        chatThreadID: String? = nil,
        score: Int = 0
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.snippet = snippet
        self.dateText = dateText
        self.targetPluginID = targetPluginID ?? source.defaultPluginID
        self.copyText = copyText
        self.chatThreadID = chatThreadID
        self.score = score
    }
}

/// 跨模块 SQLite 历史全文搜索引擎（安全兼容可选插件表）。
public nonisolated enum WorkspaceSearchEngine {
    @concurrent
    public static func searchAsync(
        database: AppDatabase,
        query: String,
        limit: Int = 30
    ) async -> [WorkspaceSearchHit] {
        search(database: database, query: query, limit: limit)
    }

    public static func search(database: AppDatabase, query: String, limit: Int = 30) -> [WorkspaceSearchHit] {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty, limit > 0 else { return [] }

        var hits: [WorkspaceSearchHit] = []

        try? database.pool.read { db in
            let existingTables = Set(
                (try? String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")) ?? []
            )

            // 1. 已提交禅道日报
            if existingTables.contains("zentaoSubmission") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, date, taskID, hours, work FROM zentaoSubmission ORDER BY date DESC, id DESC LIMIT 400"
                )
                for row in rows {
                    let rowID: Int64 = row["id"] ?? 0
                    let date: String = row["date"] ?? ""
                    let taskID: Int = row["taskID"] ?? 0
                    let hours: Double = row["hours"] ?? 0
                    let work: String = row["work"] ?? ""
                    let title = taskID > 0 ? "日报 #\(taskID) · \(date)" : "日报 · \(date)"
                    if let hit = buildHit(
                        id: "dailyLog.\(rowID)",
                        source: .dailyLog,
                        title: title,
                        body: work,
                        dateText: "\(date) · \(formatHours(hours))h",
                        tokens: tokens,
                        baseBonus: 15
                    ) {
                        hits.append(hit)
                    }
                }
            }

            // 2. 待提交禅道草稿
            if existingTables.contains("zentaoPendingDraft") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT date, payload FROM zentaoPendingDraft ORDER BY date DESC LIMIT 120"
                )
                for row in rows {
                    let date: String = row["date"] ?? ""
                    let payload: String = row["payload"] ?? ""
                    guard let data = payload.data(using: .utf8),
                          let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        continue
                    }
                    for (idx, entry) in entries.enumerated() {
                        let work = (entry["work"] as? String) ?? ""
                        let hours = (entry["hours"] as? Double) ?? 0
                        let taskTitle = (entry["taskTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let title = (taskTitle?.isEmpty == false) ? "草稿 · \(taskTitle!)" : "日报草稿 · \(date)"
                        if let hit = buildHit(
                            id: "dailyDraft.\(date).\(idx)",
                            source: .dailyDraft,
                            title: title,
                            body: work,
                            dateText: "\(date) · \(formatHours(hours))h",
                            tokens: tokens,
                            baseBonus: 18
                        ) {
                            hits.append(hit)
                        }
                    }
                }
            }

            // 3. 周报
            if existingTables.contains("weeklyReport") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT weekStart, weekEnd, title, content, extraNotes FROM weeklyReport ORDER BY weekStart DESC LIMIT 120"
                )
                for row in rows {
                    let weekStart: String = row["weekStart"] ?? ""
                    let weekEnd: String = row["weekEnd"] ?? ""
                    let title: String = row["title"] ?? "工作周报 \(weekStart)"
                    let content: String = row["content"] ?? ""
                    let notes: String = row["extraNotes"] ?? ""
                    if let hit = buildHit(
                        id: "weekly.\(weekStart)",
                        source: .weeklyReport,
                        title: title,
                        body: notes.isEmpty ? content : "\(content)\n\(notes)",
                        dateText: "\(weekStart) ~ \(weekEnd)",
                        tokens: tokens,
                        baseBonus: 20
                    ) {
                        hits.append(hit)
                    }
                }
            }

            // 4. 月报
            if existingTables.contains("monthlyReport") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT monthKey, title, content, extraNotes FROM monthlyReport ORDER BY monthKey DESC LIMIT 60"
                )
                for row in rows {
                    let monthKey: String = row["monthKey"] ?? ""
                    let title: String = row["title"] ?? "工作月报 \(monthKey)"
                    let content: String = row["content"] ?? ""
                    let notes: String = row["extraNotes"] ?? ""
                    if let hit = buildHit(
                        id: "monthly.\(monthKey)",
                        source: .monthlyReport,
                        title: title,
                        body: notes.isEmpty ? content : "\(content)\n\(notes)",
                        dateText: monthKey,
                        tokens: tokens,
                        baseBonus: 20
                    ) {
                        hits.append(hit)
                    }
                }
            }

            // 5. 季度与年度述职总结
            if existingTables.contains("reviewReport") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT periodKey, periodStart, periodEnd, title, content, extraNotes FROM reviewReport ORDER BY updatedAt DESC LIMIT 60"
                )
                for row in rows {
                    let key: String = row["periodKey"] ?? ""
                    let start: String = row["periodStart"] ?? ""
                    let end: String = row["periodEnd"] ?? ""
                    let title: String = row["title"] ?? "述职总结 \(key)"
                    let content: String = row["content"] ?? ""
                    let notes: String = row["extraNotes"] ?? ""
                    if let hit = buildHit(
                        id: "review.\(key)",
                        source: .annualReview,
                        title: title,
                        body: notes.isEmpty ? content : "\(content)\n\(notes)",
                        dateText: "\(start) ~ \(end)",
                        tokens: tokens,
                        baseBonus: 22
                    ) {
                        hits.append(hit)
                    }
                }
            }

            // 6. 待办与备忘
            if existingTables.contains("todoItem") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, title, notes, dueDate, isCompleted, updatedAt FROM todoItem ORDER BY isCompleted ASC, updatedAt DESC LIMIT 400"
                )
                for row in rows {
                    let id: String = row["id"] ?? ""
                    let title: String = row["title"] ?? ""
                    let notes: String = row["notes"] ?? ""
                    let dueDate: String? = row["dueDate"]
                    let isCompleted: Bool = row["isCompleted"] ?? false
                    let updatedAt: Date? = row["updatedAt"]
                    let statusText = isCompleted ? "已完成" : "待完成"
                    let dateLabel = dueDate.map { "截止 \($0) · \(statusText)" } ?? (updatedAt.map { "\(WorkCalendar.dayString($0)) · \(statusText)" } ?? statusText)
                    if let hit = buildHit(
                        id: "todo.\(id)",
                        source: .todo,
                        title: title,
                        body: notes,
                        dateText: dateLabel,
                        tokens: tokens,
                        baseBonus: isCompleted ? 10 : 30
                    ) {
                        hits.append(hit)
                    }
                }
            }

            // 7. 随手便签
            if existingTables.contains("scratchpadNote") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, title, content, updatedAt FROM scratchpadNote ORDER BY isPinned DESC, updatedAt DESC LIMIT 300"
                )
                for row in rows {
                    let id: String = row["id"] ?? ""
                    let rawTitle: String = row["title"] ?? ""
                    let content: String = row["content"] ?? ""
                    let updatedAt: Date? = row["updatedAt"]
                    let derived = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = derived.isEmpty ? firstNonEmptyLine(of: content, fallback: "随手便签") : derived
                    if let hit = buildHit(
                        id: "scratchpad.\(id)",
                        source: .scratchpad,
                        title: displayTitle,
                        body: content,
                        dateText: updatedAt.map { WorkCalendar.dayString($0) },
                        copyText: content,
                        tokens: tokens,
                        baseBonus: 25
                    ) {
                        hits.append(hit)
                    }
                }
            }

            // 8. 剪贴板历史与常用片段
            if existingTables.contains("clipboardHistory") {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, snippetTitle, content, isSnippet, sourceApp, copiedAt FROM clipboardHistory ORDER BY isSnippet DESC, copiedAt DESC LIMIT 300"
                )
                for row in rows {
                    let id: String = row["id"] ?? ""
                    let snippetTitle: String = row["snippetTitle"] ?? ""
                    let content: String = row["content"] ?? ""
                    let isSnippet: Bool = row["isSnippet"] ?? false
                    let sourceApp: String = row["sourceApp"] ?? ""
                    let copiedAt: Date? = row["copiedAt"]
                    let cleanTitle = snippetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayTitle = cleanTitle.isEmpty ? firstNonEmptyLine(of: content, fallback: "剪贴板文本") : cleanTitle
                    let datePart = copiedAt.map { WorkCalendar.dayString($0) } ?? ""
                    let meta = [isSnippet ? "常用片段" : (sourceApp.isEmpty ? "剪贴板" : sourceApp), datePart]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if let hit = buildHit(
                        id: "clipboard.\(id)",
                        source: .clipboard,
                        title: displayTitle,
                        body: content,
                        dateText: meta,
                        copyText: content,
                        tokens: tokens,
                        baseBonus: isSnippet ? 35 : 12
                    ) {
                        hits.append(hit)
                    }
                }
            }

            // 9. 首页 AI 对话消息
            if existingTables.contains("chatMessage"), existingTables.contains("chatThread") {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT m.id, m.threadID, m.role, m.content, m.createdAt, t.title AS threadTitle
                    FROM chatMessage m
                    JOIN chatThread t ON t.id = m.threadID
                    WHERE m.content <> ''
                    ORDER BY m.createdAt DESC
                    LIMIT 400
                    """
                )
                for row in rows {
                    let msgID: String = row["id"] ?? ""
                    let threadID: String = row["threadID"] ?? ""
                    let role: String = row["role"] ?? ""
                    let content: String = row["content"] ?? ""
                    let threadTitle: String = row["threadTitle"] ?? "工作台对话"
                    let createdAt: Date? = row["createdAt"]
                    let roleLabel = role == "user" ? "提问" : "回复"
                    let dateLabel = [roleLabel, createdAt.map { WorkCalendar.dayString($0) } ?? ""]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if let hit = buildHit(
                        id: "chat.\(msgID)",
                        source: .chat,
                        title: threadTitle,
                        body: content,
                        dateText: dateLabel,
                        copyText: nil,
                        chatThreadID: threadID,
                        tokens: tokens,
                        baseBonus: 14
                    ) {
                        hits.append(hit)
                    }
                }
            }
        }

        hits.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return (lhs.dateText ?? "") > (rhs.dateText ?? "")
        }
        return Array(hits.prefix(limit))
    }

    private static func buildHit(
        id: String,
        source: WorkspaceSearchSource,
        title: String,
        body: String,
        dateText: String?,
        copyText: String? = nil,
        chatThreadID: String? = nil,
        tokens: [String],
        baseBonus: Int
    ) -> WorkspaceSearchHit? {
        var score = baseBonus
        for token in tokens {
            let titleRange = title.range(of: token, options: [.caseInsensitive])
            let inBody = body.range(of: token, options: [.caseInsensitive]) != nil
            let inDate = dateText?.range(of: token, options: [.caseInsensitive]) != nil
            guard titleRange != nil || inBody || inDate else { return nil }
            if let titleRange {
                if titleRange.lowerBound == title.startIndex && titleRange.upperBound == title.endIndex {
                    score += 120
                } else if titleRange.lowerBound == title.startIndex {
                    score += 75
                } else {
                    score += 45
                }
            }
            if inBody { score += 20 }
            if inDate { score += 10 }
        }

        let snippetSource = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : body
        let snippet = snippetAroundMatch(in: snippetSource, tokens: tokens)
        return WorkspaceSearchHit(
            id: id,
            source: source,
            title: title,
            snippet: snippet,
            dateText: dateText,
            copyText: copyText,
            chatThreadID: chatThreadID,
            score: score
        )
    }

    static func snippetAroundMatch(in text: String, tokens: [String], maxLength: Int = 84) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return "" }
        guard singleLine.count > maxLength else { return singleLine }

        if let firstRange = tokens.compactMap({ singleLine.range(of: $0, options: [.caseInsensitive]) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let matchPos = singleLine.distance(from: singleLine.startIndex, to: firstRange.lowerBound)
            let startOffset = max(0, matchPos - 22)
            let endOffset = min(singleLine.count, startOffset + maxLength)
            let startIdx = singleLine.index(singleLine.startIndex, offsetBy: startOffset)
            let endIdx = singleLine.index(singleLine.startIndex, offsetBy: endOffset)
            var out = String(singleLine[startIdx..<endIdx])
            if startOffset > 0 { out = "…" + out }
            if endOffset < singleLine.count { out += "…" }
            return out
        }
        return String(singleLine.prefix(maxLength)) + "…"
    }

    private static func firstNonEmptyLine(of text: String, fallback: String) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.isEmpty { return fallback }
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }

    private static func formatHours(_ hours: Double) -> String {
        if hours.rounded() == hours {
            return "\(Int(hours))"
        }
        return String(format: "%.1f", hours)
    }
}
