import Foundation
import GRDB

public nonisolated struct DatabaseMigration: Sendable {
    public let identifier: String
    public let migrate: @Sendable (Database) throws -> Void

    public init(_ identifier: String, migrate: @escaping @Sendable (Database) throws -> Void) {
        self.identifier = identifier
        self.migrate = migrate
    }
}

public nonisolated enum AppPaths {
    /// ~/Library/Application Support/IronBowl
    public nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "IronBowl", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public nonisolated static var logsDirectory: URL {
        let dir = supportDirectory.appending(path: "logs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public nonisolated static var userAvatarsDirectory: URL {
        let dir = supportDirectory.appending(path: "user-avatars", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public nonisolated static var databaseURL: URL {
        supportDirectory.appending(path: "ironbowl.sqlite")
    }
}

/// 全应用共享的 SQLite（WAL）。独立版万年历也打开同一个文件。
public nonisolated final class AppDatabase: Sendable {
    public let pool: DatabasePool
    public let path: String

    public init(url: URL = AppPaths.databaseURL, migrations: [DatabaseMigration]) throws {
        path = url.path
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        for m in Self.coreMigrations + migrations {
            migrator.registerMigration(m.identifier, migrate: m.migrate)
        }
        try migrator.migrate(pool)
    }

    public static let coreMigrations: [DatabaseMigration] = [
        DatabaseMigration("core.v1") { db in
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "holiday") { t in
                t.primaryKey("date", .text)          // yyyy-MM-dd
                t.column("isOffDay", .boolean).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("source", .text).notNull().defaults(to: "")
            }
            try db.create(table: "holidayOverride") { t in
                t.primaryKey("date", .text)
                t.column("isOffDay", .boolean).notNull()
                t.column("note", .text).notNull().defaults(to: "")
            }
        },
        DatabaseMigration("core.v2") { db in
            try db.create(table: "scheduledTask") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("actionID", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("scheduleJSON", .text).notNull()
                t.column("misfirePolicy", .text).notNull().defaults(to: "runIfMissedToday")
                t.column("notifyPolicy", .text).notNull().defaults(to: "onSuccessAndFailure")
                t.column("notifyStyle", .text).notNull().defaults(to: "cornerCard")
                t.column("parametersJSON", .text).notNull().defaults(to: "{}")
                t.column("nextRunAt", .datetime)
                t.column("lastRunAt", .datetime)
                t.column("lastFiredSlot", .text)
                t.column("lastStatus", .text)
                t.column("lastSummary", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "scheduledTaskRun") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("taskID", .text).notNull().indexed()
                t.column("taskName", .text).notNull()
                t.column("actionID", .text).notNull()
                t.column("trigger", .text).notNull()
                t.column("status", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("finishedAt", .datetime)
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("detail", .text).notNull().defaults(to: "")
            }
        },
        DatabaseMigration("core.v3") { db in
            try db.create(table: "attendanceClockIn") { t in
                t.primaryKey("date", .text)          // yyyy-MM-dd
                t.column("clockIn", .datetime).notNull()
                t.column("source", .text).notNull().defaults(to: "")
                t.column("fetchedAt", .datetime).notNull()
            }
        },
        DatabaseMigration("core.v4") { db in
            try db.create(table: "dailyOvertime") { t in
                t.primaryKey("date", .text)          // yyyy-MM-dd
                t.column("hours", .double).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            if try db.tableExists("zentaoDailyOvertime") {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO dailyOvertime(date, hours, updatedAt)
                    SELECT date, hours, updatedAt FROM zentaoDailyOvertime WHERE hours > 0
                    """)
            }
        },
        DatabaseMigration("core.v5") { db in
            try db.create(table: "chatThread") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("providerKind", .text).notNull()
                t.column("workspacePath", .text).notNull()
                t.column("permissionMode", .text).notNull().defaults(to: "agent")
                t.column("remoteSessionID", .text)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
            try db.create(table: "chatMessage") { t in
                t.primaryKey("id", .text)
                t.column("threadID", .text).notNull()
                    .references("chatThread", column: "id", onDelete: .cascade)
                    .indexed()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull().defaults(to: "completed")
                t.column("providerKind", .text)
                t.column("modelName", .text)
                t.column("durationSeconds", .double)
                t.column("usageJSON", .text)
                t.column("activitiesJSON", .text).notNull().defaults(to: "[]")
                t.column("rawEventsJSON", .text).notNull().defaults(to: "[]")
                t.column("cardsJSON", .text).notNull().defaults(to: "[]")
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
            }
        },
        DatabaseMigration("core.v6") { db in
            try db.alter(table: "chatThread") { t in
                t.add(column: "model", .text).notNull().defaults(to: "")
            }
        },
        DatabaseMigration("core.v7") { db in
            try db.create(table: "reminderHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("reminderID", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("message", .text).notNull()
                t.column("systemImage", .text).notNull().defaults(to: "bell.fill")
                t.column("source", .text).notNull().defaults(to: "general").indexed()
                t.column("style", .text).notNull()
                t.column("deliveryStatus", .text).notNull().defaults(to: "delivered")
                t.column("deliveryDetail", .text).notNull().defaults(to: "")
                t.column("isRead", .boolean).notNull().defaults(to: false).indexed()
                t.column("readAt", .datetime)
                t.column("handledActionTitle", .text)
                t.column("handledAt", .datetime)
                t.column("targetPluginID", .text)
                t.column("targetSettingsPage", .text)
                t.column("createdAt", .datetime).notNull().indexed()
            }
        },
        DatabaseMigration("core.v8") { db in
            try db.create(table: "todoItem") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("dueDate", .text).indexed()
                t.column("remindAt", .datetime)
                t.column("remindedAt", .datetime)
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("estimatedHours", .double).notNull().defaults(to: 1.0)
                t.column("isCompleted", .boolean).notNull().defaults(to: false).indexed()
                t.column("completedAt", .datetime)
                t.column("loggedDate", .text)
                t.column("zentaoObjectType", .text)
                t.column("zentaoObjectID", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
        },
        DatabaseMigration("core.v9") { db in
            try db.create(table: "scratchpadNote") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("colorTag", .text).notNull().defaults(to: "amber")
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
        },
        DatabaseMigration("core.v10") { db in
            try db.create(table: "attendanceDailyRecord") { t in
                t.primaryKey("date", .text)          // yyyy-MM-dd
                t.column("clockIn", .datetime)
                t.column("clockOut", .datetime)
                t.column("onDutyResult", .text).notNull().defaults(to: "")
                t.column("offDutyResult", .text).notNull().defaults(to: "")
                t.column("source", .text).notNull().defaults(to: "dingtalk")
                t.column("fetchedAt", .datetime).notNull()
            }
            if try db.tableExists("attendanceClockIn") {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO attendanceDailyRecord(date, clockIn, onDutyResult, offDutyResult, source, fetchedAt)
                    SELECT date, clockIn, 'Normal', '', source, fetchedAt FROM attendanceClockIn
                    """)
            }
        },
        DatabaseMigration("core.v11") { db in
            try db.create(table: "clipboardHistory") { t in
                t.primaryKey("id", .text)
                t.column("content", .text).notNull()
                t.column("contentHash", .text).notNull().indexed()
                t.column("kind", .text).notNull().defaults(to: "text")
                t.column("sourceApp", .text).notNull().defaults(to: "")
                t.column("charCount", .integer).notNull().defaults(to: 0)
                t.column("copyCount", .integer).notNull().defaults(to: 1)
                t.column("isSnippet", .boolean).notNull().defaults(to: false).indexed()
                t.column("snippetTitle", .text).notNull().defaults(to: "")
                t.column("copiedAt", .datetime).notNull().indexed()
            }
        },
    ]
}
