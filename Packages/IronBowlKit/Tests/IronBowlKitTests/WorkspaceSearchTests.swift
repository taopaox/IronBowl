import Foundation
import Testing
@testable import IronBowlKit

struct WorkspaceSearchTests {
    @MainActor
    @Test("跨模块搜索可检索待办、便签、剪贴板、对话及禅道与周报插件表")
    func crossModuleSearchReturnsRankedHits() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "ironbowl-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginMigrations = [
            DatabaseMigration("test.zentao.mock") { db in
                try db.create(table: "zentaoSubmission") { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("date", .text).notNull()
                    t.column("taskID", .integer).notNull()
                    t.column("hours", .double).notNull()
                    t.column("left", .double).notNull()
                    t.column("work", .text).notNull()
                    t.column("isOvertime", .boolean).notNull().defaults(to: false)
                    t.column("submittedAt", .datetime).notNull()
                }
                try db.create(table: "zentaoPendingDraft") { t in
                    t.primaryKey("date", .text)
                    t.column("payload", .text).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
            },
            DatabaseMigration("test.report.mock") { db in
                try db.create(table: "weeklyReport") { t in
                    t.primaryKey("weekStart", .text)
                    t.column("weekEnd", .text).notNull()
                    t.column("title", .text).notNull()
                    t.column("content", .text).notNull()
                    t.column("extraNotes", .text).notNull().defaults(to: "")
                    t.column("style", .text).notNull()
                    t.column("providerName", .text).notNull().defaults(to: "")
                    t.column("totalHours", .double).notNull().defaults(to: 0)
                    t.column("generatedAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
                try db.create(table: "reviewReport") { t in
                    t.primaryKey("periodKey", .text)
                    t.column("scopeKind", .text).notNull()
                    t.column("periodStart", .text).notNull()
                    t.column("periodEnd", .text).notNull()
                    t.column("title", .text).notNull()
                    t.column("content", .text).notNull()
                    t.column("extraNotes", .text).notNull().defaults(to: "")
                    t.column("style", .text).notNull()
                    t.column("providerName", .text).notNull().defaults(to: "")
                    t.column("totalHours", .double).notNull().defaults(to: 0)
                    t.column("overtimeHours", .double).notNull().defaults(to: 0)
                    t.column("commitCount", .integer).notNull().defaults(to: 0)
                    t.column("generatedAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                }
            },
        ]

        let db = try AppDatabase(url: tempDir.appending(path: "test.sqlite"), migrations: pluginMigrations)
        let settings = SettingsStore(database: db)
        let todos = TodoStore(database: db)
        let notes = ScratchpadStore(database: db)
        let clipboard = ClipboardHistoryStore(database: db, settings: settings)
        let chat = ChatStore(database: db, settings: settings, providers: AIProviderStore(settings: settings))

        _ = todos.add(title: "排查结算网关超时", notes: "联系支付团队核对超时阈值", dueDate: "2026-11-27", priority: .urgent)
        _ = notes.createNote(title: "支付联调笔记", content: "测试网关灰度签名算法与回调地址")
        _ = clipboard.saveSnippet(title: "网关压测命令", content: "wrk -t4 -c64 -d30s https://pay.example.com/gateway")

        let thread = chat.createThread(title: "网关异常排查", workspacePath: tempDir.path)
        chat.insertCards([ChatCardAttachment(cardID: "test", label: "状态", valueSnapshot: "正常")], into: thread.id)

        try db.pool.write { wdb in
            try wdb.execute(
                sql: "INSERT INTO chatMessage(id, threadID, role, content, status, activitiesJSON, rawEventsJSON, cardsJSON, createdAt, updatedAt) VALUES (?, ?, 'user', ?, 'completed', '[]', '[]', '[]', ?, ?)",
                arguments: [UUID().uuidString, thread.id, "为什么网关会返回 504？", Date(), Date()]
            )
            try wdb.execute(
                sql: "INSERT INTO zentaoSubmission(date, taskID, hours, left, work, isOvertime, submittedAt) VALUES ('2026-11-26', 108, 4.0, 0, '优化结算网关连接池参数', 0, ?)",
                arguments: [Date()]
            )
            try wdb.execute(
                sql: "INSERT INTO zentaoPendingDraft(date, payload, updatedAt) VALUES ('2026-11-27', ?, ?)",
                arguments: [#"[{"taskID":109,"taskTitle":"网关监控","hours":2.0,"work":"补充网关超时告警规则"}]"#, Date()]
            )
            try wdb.execute(
                sql: "INSERT INTO weeklyReport(weekStart, weekEnd, title, content, extraNotes, style, providerName, totalHours, generatedAt, updatedAt) VALUES ('2026-11-23', '2026-11-27', '第48周周报', '完成网关链路优化并下降错误率', '', 'standard', 'agy', 40, ?, ?)",
                arguments: [Date(), Date()]
            )
            try wdb.execute(
                sql: "INSERT INTO reviewReport(periodKey, scopeKind, periodStart, periodEnd, title, content, extraNotes, style, providerName, totalHours, overtimeHours, commitCount, generatedAt, updatedAt) VALUES ('2026-Q4', 'quarter', '2026-10-01', '2026-12-31', 'Q4 述职总结', '主导核心网关高可用改造', '', 'performanceSTAR', 'agy', 320, 12, 48, ?, ?)",
                arguments: [Date(), Date()]
            )
        }

        let allGatewayHits = WorkspaceSearchEngine.search(database: db, query: "网关", limit: 20)
        let sources = Set(allGatewayHits.map(\.source))
        #expect(sources.contains(.todo))
        #expect(sources.contains(.scratchpad))
        #expect(sources.contains(.clipboard))
        #expect(sources.contains(.chat))
        #expect(sources.contains(.dailyLog))
        #expect(sources.contains(.dailyDraft))
        #expect(sources.contains(.weeklyReport))
        #expect(sources.contains(.annualReview))

        // 多关键词 AND 过滤
        let multiToken = WorkspaceSearchEngine.search(database: db, query: "网关 压测", limit: 10)
        #expect(multiToken.count == 1)
        #expect(multiToken[0].source == .clipboard)
        #expect(multiToken[0].copyText?.contains("wrk") == true)
    }

    @MainActor
    @Test("仅有核心库表时缺失插件表不会崩溃并能安全返回")
    func searchGracefullySkipsMissingPluginTables() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "ironbowl-search-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try AppDatabase(url: tempDir.appending(path: "core-only.sqlite"), migrations: [])
        let todos = TodoStore(database: db)
        _ = todos.add(title: "独立日历联调")

        let hits = WorkspaceSearchEngine.search(database: db, query: "日历")
        #expect(hits.count == 1)
        #expect(hits[0].source == .todo)
    }
}
