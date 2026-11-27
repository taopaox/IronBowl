import Foundation
import GRDB
import Testing
@testable import IronBowlKit

struct WorkbenchBridgeCLITests {
    private struct DecodedDraftEntry: Decodable {
        let id: UUID
        let taskID: Int?
        let hours: Double
        let left: Double
        let work: String
        let repoPaths: [String]
        let commitHashes: [String]
        let isFallback: Bool
        let isOvertime: Bool
        let isManual: Bool
        let isRecorded: Bool
    }

    @MainActor
    @Test("ironbowl-cli 支持端到端查询、写入联动与只读权限拦截")
    func cliEndToEndReadWriteAndReadOnly() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "ironbowl-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pluginMigration = DatabaseMigration("test.cli.zentao") { db in
            try db.create(table: "zentaoPendingDraft") { t in
                t.primaryKey("date", .text)
                t.column("payload", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
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
        }

        let dbURL = tempDir.appending(path: "test.sqlite")
        let db = try AppDatabase(url: dbURL, migrations: [pluginMigration])
        let cliURL = tempDir.appending(path: "bin/ironbowl-cli")
        try WorkbenchBridgeCLI.ensureInstalled(at: cliURL)

        let settings = SettingsStore(database: db)
        let todos = TodoStore(database: db)
        let notes = ScratchpadStore(database: db)
        let cal = WorkCalendar(database: db, settings: settings)

        // 1. status 查询返回有效 JSON
        let statusRes = try await Shell.run(cliURL.path, ["--db", dbURL.path, "status"])
        #expect(statusRes.status == 0)
        let statusObj = try JSONSerialization.jsonObject(with: try #require(statusRes.stdout.data(using: .utf8))) as? [String: Any]
        #expect(statusObj?["today"] as? String != nil)

        // 2. todo-add（含单引号转义）并验证 TodoStore 可读取
        let addTodoRes = try await Shell.run(cliURL.path, [
            "--db", dbURL.path,
            "todo-add", "修复 '登录' 接口超时",
            "--due", "2026-11-27",
            "--priority", "2",
            "--hours", "1.5",
            "--notes", "联系后端联调"
        ])
        #expect(addTodoRes.status == 0)
        let addTodoObj = try JSONSerialization.jsonObject(with: try #require(addTodoRes.stdout.data(using: .utf8))) as? [String: Any]
        let todoID = try #require(addTodoObj?["id"] as? String)
        todos.reload()
        #expect(todos.items.count == 1)
        #expect(todos.items[0].title == "修复 '登录' 接口超时")
        #expect(todos.items[0].priority == 2)
        #expect(todos.items[0].estimatedHours == 1.5)

        // 3. todo-done 前缀完成待办
        let prefix = String(todoID.prefix(8))
        let doneRes = try await Shell.run(cliURL.path, ["--db", dbURL.path, "todo-done", prefix])
        #expect(doneRes.status == 0)
        todos.reload()
        #expect(todos.items[0].isCompleted == true)

        // 4. note-add 写入便签并验证 ScratchpadStore
        let noteRes = try await Shell.run(cliURL.path, ["--db", dbURL.path, "note-add", "排查记录", "端口 8080 被占用", "--pin"])
        #expect(noteRes.status == 0)
        notes.reload()
        #expect(notes.notes.count == 1)
        #expect(notes.notes[0].isPinned == true)
        #expect(notes.notes[0].content == "端口 8080 被占用")

        // 5. draft-add 写入 zentaoPendingDraft 并校验可被完整 Codable 结构反序列化
        let draftRes = try await Shell.run(cliURL.path, [
            "--db", dbURL.path,
            "draft-add", "完成支付联调与回归测试",
            "--hours", "2.5",
            "--date", "2026-11-27"
        ])
        #expect(draftRes.status == 0)
        let rawPayload: String? = try await db.pool.read { rdb in
            try String.fetchOne(rdb, sql: "SELECT payload FROM zentaoPendingDraft WHERE date = '2026-11-27'")
        }
        let payload = try #require(rawPayload)
        let decodedDrafts = try JSONDecoder().decode([DecodedDraftEntry].self, from: try #require(payload.data(using: .utf8)))
        #expect(decodedDrafts.count == 1)
        #expect(decodedDrafts[0].work == "完成支付联调与回归测试")
        #expect(decodedDrafts[0].hours == 2.5)
        #expect(decodedDrafts[0].isManual == true)
        #expect(decodedDrafts[0].isRecorded == false)

        // 6. overtime-set 写入并通过 WorkCalendar 重载验证
        let otRes = try await Shell.run(cliURL.path, ["--db", dbURL.path, "overtime-set", "2.0", "--date", "2026-11-27"])
        #expect(otRes.status == 0)
        cal.reload()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let targetDay = try #require(formatter.date(from: "2026-11-27"))
        #expect(cal.overtimeHours(on: targetDay) == 2.0)

        // 7. --read-only 模式拒绝写命令且不污染数据库
        let roRes = try await Shell.run(cliURL.path, ["--db", dbURL.path, "--read-only", "todo-add", "只读不应写入"])
        #expect(roRes.status != 0)
        todos.reload()
        #expect(todos.items.count == 1)
    }

    @Test("提示词注入文本包含日期、路径与只读标志")
    func preambleContainsExpectedContext() {
        let ro = WorkbenchBridgeCLI.promptPreamble(
            cliPath: "/tmp/ironbowl-cli",
            databasePath: "/tmp/db.sqlite",
            permissionMode: .readOnly
        )
        #expect(ro.contains("--read-only"))
        #expect(ro.contains("禁止调用写命令"))
        #expect(ro.contains("/tmp/ironbowl-cli"))
    }
}
