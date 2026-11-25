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

    public nonisolated static var databaseURL: URL {
        supportDirectory.appending(path: "ironbowl.sqlite")
    }
}

/// 全应用共享的 SQLite（WAL）。独立版万年历也打开同一个文件。
public nonisolated final class AppDatabase: Sendable {
    public let pool: DatabasePool

    public init(url: URL = AppPaths.databaseURL, migrations: [DatabaseMigration]) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        for m in Self.coreMigrations + migrations {
            migrator.registerMigration(m.identifier, migrate: m.migrate)
        }
        try migrator.migrate(pool)
    }

    static let coreMigrations: [DatabaseMigration] = [
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
    ]
}
