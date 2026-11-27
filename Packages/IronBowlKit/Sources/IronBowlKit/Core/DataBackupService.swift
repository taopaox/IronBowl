import Foundation
import GRDB

public nonisolated struct BackupManifest: Codable, Sendable, Equatable {
    public let version: Int
    public let appVersion: String
    public let createdAt: Date
    public let includedDirectories: [String]
    public let settingsCount: Int
    public let todosCount: Int
    public let notesCount: Int

    public init(
        version: Int = 1,
        appVersion: String,
        createdAt: Date = Date(),
        includedDirectories: [String],
        settingsCount: Int,
        todosCount: Int,
        notesCount: Int
    ) {
        self.version = version
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.includedDirectories = includedDirectories
        self.settingsCount = settingsCount
        self.todosCount = todosCount
        self.notesCount = notesCount
    }
}

public nonisolated enum DataBackupError: LocalizedError, Sendable {
    case invalidArchive(String)
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail): "备份包格式无效：\(detail)"
        case .archiveFailed(let detail): "备份打包或解压失败：\(detail)"
        }
    }
}

/// 全应用数据一键备份与恢复服务（覆盖 SQLite 共享库、自定义头像与 AI 图标目录）。
public nonisolated enum DataBackupService {
    private static let assetDirectoryNames = ["user-avatars", "ai-logos"]

    @concurrent
    public static func exportBackup(
        database: AppDatabase,
        supportDirectory: URL = AppPaths.supportDirectory,
        appVersion: String = Bundle.main.displayVersion,
        to destinationZipURL: URL
    ) async throws -> BackupManifest {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appending(path: "ironbowl-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let stageDir = tempRoot.appending(path: "ironbowl-backup", directoryHint: .isDirectory)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let stagedDB = stageDir.appending(path: "ironbowl.sqlite")
        try await database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [stagedDB.path])
        }

        let counts = try await database.pool.read { db -> (settings: Int, todos: Int, notes: Int) in
            let s = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM setting")) ?? 0
            let t = (try db.tableExists("todoItem"))
                ? ((try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM todoItem")) ?? 0)
                : 0
            let n = (try db.tableExists("scratchpadNote"))
                ? ((try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scratchpadNote")) ?? 0)
                : 0
            return (s, t, n)
        }

        var includedDirs: [String] = []
        for dirName in assetDirectoryNames {
            let src = supportDirectory.appending(path: dirName, directoryHint: .isDirectory)
            if let children = try? fm.contentsOfDirectory(atPath: src.path), !children.isEmpty {
                let dst = stageDir.appending(path: dirName, directoryHint: .isDirectory)
                try fm.copyItem(at: src, to: dst)
                includedDirs.append(dirName)
            }
        }

        let manifest = BackupManifest(
            version: 1,
            appVersion: appVersion,
            createdAt: Date(),
            includedDirectories: includedDirs,
            settingsCount: counts.settings,
            todosCount: counts.todos,
            notesCount: counts.notes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stageDir.appending(path: "manifest.json"), options: .atomic)

        let parent = destinationZipURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationZipURL.path) {
            try fm.removeItem(at: destinationZipURL)
        }

        let result = try await Shell.run(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", stageDir.path, destinationZipURL.path],
            timeout: 120
        )
        guard result.status == 0 else {
            throw DataBackupError.archiveFailed(result.stderr.isEmpty ? "ditto exited \(result.status)" : result.stderr)
        }
        return manifest
    }

    @concurrent
    public static func restoreBackup(
        from zipURL: URL,
        into database: AppDatabase,
        supportDirectory: URL = AppPaths.supportDirectory,
        migrations: [DatabaseMigration] = []
    ) async throws -> BackupManifest {
        let fm = FileManager.default
        guard fm.fileExists(atPath: zipURL.path) else {
            throw DataBackupError.invalidArchive("找不到备份文件 \(zipURL.lastPathComponent)")
        }

        let tempRoot = fm.temporaryDirectory.appending(path: "ironbowl-restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let extractResult = try await Shell.run(
            "/usr/bin/ditto",
            ["-x", "-k", zipURL.path, tempRoot.path],
            timeout: 120
        )
        guard extractResult.status == 0 else {
            throw DataBackupError.archiveFailed(extractResult.stderr.isEmpty ? "ditto exited \(extractResult.status)" : extractResult.stderr)
        }

        guard let extractedDBURL = findSQLiteFile(in: tempRoot) else {
            throw DataBackupError.invalidArchive("压缩包中缺少 ironbowl.sqlite 数据库文件")
        }
        let backupRoot = extractedDBURL.deletingLastPathComponent()

        let sourceQueue = try DatabaseQueue(path: extractedDBURL.path)
        let hasSettingTable = try await sourceQueue.read { db in
            try db.tableExists("setting")
        }
        guard hasSettingTable else {
            throw DataBackupError.invalidArchive("数据库缺少核心 setting 表，不是有效的饭碗备份")
        }

        // 恢复前留存当前数据库安全快照
        let safetyDir = supportDirectory.appending(path: "backups", directoryHint: .isDirectory)
        try fm.createDirectory(at: safetyDir, withIntermediateDirectories: true)
        let stampFmt = DateFormatter()
        stampFmt.calendar = Calendar(identifier: .gregorian)
        stampFmt.locale = Locale(identifier: "en_US_POSIX")
        stampFmt.dateFormat = "yyyyMMdd-HHmmss"
        let safetySnapshot = safetyDir.appending(path: "pre-restore-\(stampFmt.string(from: Date())).sqlite")
        if fm.fileExists(atPath: safetySnapshot.path) {
            try? fm.removeItem(at: safetySnapshot)
        }
        try await database.pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [safetySnapshot.path])
        }
        pruneSafetySnapshots(in: safetyDir, keepingLatest: 5)

        // 在线原子恢复并补跑最新迁移
        try sourceQueue.backup(to: database.pool)
        var migrator = DatabaseMigrator()
        for m in AppDatabase.coreMigrations + migrations {
            migrator.registerMigration(m.identifier, migrate: m.migrate)
        }
        try migrator.migrate(database.pool)

        // 恢复图片资源目录
        var restoredDirs: [String] = []
        for dirName in assetDirectoryNames {
            let src = backupRoot.appending(path: dirName, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = supportDirectory.appending(path: dirName, directoryHint: .isDirectory)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
            for file in files {
                let sFile = src.appending(path: file)
                let dFile = dst.appending(path: file)
                if fm.fileExists(atPath: dFile.path) {
                    try fm.removeItem(at: dFile)
                }
                try fm.copyItem(at: sFile, to: dFile)
            }
            restoredDirs.append(dirName)
        }

        let manifestURL = backupRoot.appending(path: "manifest.json")
        if let data = try? Data(contentsOf: manifestURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(BackupManifest.self, from: data) {
                return decoded
            }
        }

        let counts = try await database.pool.read { db -> (settings: Int, todos: Int, notes: Int) in
            let s = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM setting")) ?? 0
            let t = (try db.tableExists("todoItem"))
                ? ((try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM todoItem")) ?? 0)
                : 0
            let n = (try db.tableExists("scratchpadNote"))
                ? ((try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scratchpadNote")) ?? 0)
                : 0
            return (s, t, n)
        }
        return BackupManifest(
            version: 1,
            appVersion: "unknown",
            createdAt: Date(),
            includedDirectories: restoredDirs,
            settingsCount: counts.settings,
            todosCount: counts.todos,
            notesCount: counts.notes
        )
    }

    private static func findSQLiteFile(in root: URL) -> URL? {
        let fm = FileManager.default
        let preferred = [
            root.appending(path: "ironbowl-backup/ironbowl.sqlite"),
            root.appending(path: "ironbowl.sqlite"),
        ]
        for url in preferred where fm.fileExists(atPath: url.path) {
            return url
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "ironbowl.sqlite" {
            return fileURL
        }
        return nil
    }

    private static func pruneSafetySnapshots(in dir: URL, keepingLatest: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let snapshots = names
            .filter { $0.hasPrefix("pre-restore-") && $0.hasSuffix(".sqlite") }
            .sorted(by: >)
        if snapshots.count > keepingLatest {
            for old in snapshots.dropFirst(keepingLatest) {
                try? fm.removeItem(at: dir.appending(path: old))
            }
        }
    }
}
