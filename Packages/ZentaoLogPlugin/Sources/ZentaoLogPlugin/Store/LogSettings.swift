import Foundation
import GRDB
import IronBowlKit

public nonisolated enum ScanMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case onDemand, onDemandPlusInterval, manualOnly
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .onDemand: "按需扫描（打开日志页、提醒弹出、点刷新）"
        case .onDemandPlusInterval: "按需 + 每隔 N 分钟定时扫描"
        case .manualOnly: "只在点「刷新」时扫描"
        }
    }
    public var detail: String {
        switch self {
        case .onDemand: "打开日志页、提醒弹出或点刷新时自动扫描。"
        case .onDemandPlusInterval: "在按需扫描的基础上，每隔固定分钟自动扫描一次。"
        case .manualOnly: "不自动扫描，仅在手动点击「刷新」时读取仓库。"
        }
    }
}

/// 日志插件的所有设置键。
enum LogKeys {
    static let baseURL = SettingKey<String>("zentao.baseURL", default: "https://hwsz.chandao.com")
    static let account = SettingKey<String>("zentao.account", default: "")
    static let password = SettingKey<String>("zentao.password", default: "")
    static let fallbackTaskID = SettingKey<Int?>("zentao.fallbackTaskID", default: nil)

    static let gitRoot = SettingKey<String>("git.root", default: "/Users/yxhc/huanwei")
    static let gitDepth = SettingKey<Int>("git.depth", default: 2)
    static let authorEmail = SettingKey<String>("git.authorEmail", default: "")

    static let scanMode = SettingKey<ScanMode>("scan.mode", default: .onDemand)
    static let scanInterval = SettingKey<Int>("scan.intervalMinutes", default: 10)

    static let quickLogShortcut = SettingKey<Bool>("log.quickLogShortcut", default: true)
    static let prompt = SettingKey<String>("log.prompt", default: DraftGenerator.defaultPrompt)
    static let overtimeDefaultHours = SettingKey<Double>("log.overtimeDefaultHours", default: 2)
    static let offDayOvertime = SettingKey<Bool>("log.offDayOvertime", default: true)

    static let reminderTimes = SettingKey<[String]>("reminder.times", default: ["18:00"])
    static let reminderStyle = SettingKey<ReminderStyle>("reminder.style", default: .cornerCard)
    static let snoozeMinutes = SettingKey<Int>("reminder.snoozeMinutes", default: 15)
    static let remindOnOffDays = SettingKey<Bool>("reminder.offDays", default: false)
    static let skipDate = SettingKey<String>("reminder.skipDate", default: "")

    static let watchAssignedEnabled = SettingKey<Bool>("zentao.watch.enabled", default: true)
    static let watchAssignedInterval = SettingKey<Int>("zentao.watch.intervalMinutes", default: 15)
    static let watchBugsOnly = SettingKey<Bool>("zentao.watch.bugsOnly", default: false)
    static let knownOpenBugIDs = SettingKey<[Int]?>("zentao.watch.knownBugIDs", default: nil)
    static let knownOpenTaskIDs = SettingKey<[Int]?>("zentao.watch.knownTaskIDs", default: nil)
}

public extension GitScanner {
    @MainActor
    static func configuredRepos(database: AppDatabase, settings: SettingsStore) -> [String] {
        let root = settings[LogKeys.gitRoot]
        let depth = settings[LogKeys.gitDepth]
        let discovered = discoverRepos(root: root, depth: depth)
        let mappings = LogStore(db: database).mappings()
        return discovered.filter { mappings[$0]?.excluded != true }
    }

    @MainActor
    static func mappedProjectNames(database: AppDatabase) -> [String: String] {
        let mappings = LogStore(db: database).mappings()
        var out: [String: String] = [:]
        for (path, m) in mappings where !m.excluded && !m.projectName.isEmpty {
            out[path] = m.projectName
        }
        return out
    }

    @MainActor
    static func configuredAuthorEmail(settings: SettingsStore) async -> String {
        let saved = settings[LogKeys.authorEmail].trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        return await globalEmail() ?? ""
    }

    @MainActor
    static func configuredGitRoot(settings: SettingsStore) -> String {
        settings[LogKeys.gitRoot]
    }

    @MainActor
    static func configuredGitDepth(settings: SettingsStore) -> Int {
        settings[LogKeys.gitDepth]
    }
}

nonisolated struct RepoMapping: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "zentaoRepoMapping"
    var repoPath: String
    var projectID: Int?
    var projectName: String
    var excluded: Bool
    var sendDiff: Bool
}

nonisolated struct Submission: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "zentaoSubmission"
    var id: Int64?
    var date: String
    var taskID: Int
    var hours: Double
    var left: Double
    var work: String
    var isOvertime: Bool
    var submittedAt: Date
}

enum LogMigrations {
    static let all: [DatabaseMigration] = [
        DatabaseMigration("zentao.v1") { db in
            try db.create(table: "zentaoRepoMapping") { t in
                t.primaryKey("repoPath", .text)
                t.column("projectID", .integer)
                t.column("projectName", .text).notNull().defaults(to: "")
                t.column("excluded", .boolean).notNull().defaults(to: false)
                t.column("sendDiff", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "zentaoSubmission") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .text).notNull().indexed()
                t.column("taskID", .integer).notNull()
                t.column("hours", .double).notNull()
                t.column("left", .double).notNull()
                t.column("work", .text).notNull()
                t.column("isOvertime", .boolean).notNull().defaults(to: false)
                t.column("submittedAt", .datetime).notNull()
            }
            try db.create(table: "zentaoLastTask") { t in
                t.primaryKey("repoPath", .text)
                t.column("taskID", .integer).notNull()
            }
        },
        DatabaseMigration("zentao.v2") { db in
            try db.create(table: "zentaoPendingDraft") { t in
                t.primaryKey("date", .text)
                t.column("payload", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        },
        DatabaseMigration("zentao.v3") { db in
            try db.create(table: "zentaoDailyOvertime") { t in
                t.primaryKey("date", .text)
                t.column("hours", .double).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        },
    ]
}

/// 日志插件的数据库读写。
struct LogStore {
    let db: AppDatabase

    func mappings() -> [String: RepoMapping] {
        let list = (try? db.pool.read { try RepoMapping.fetchAll($0) }) ?? []
        return Dictionary(uniqueKeysWithValues: list.map { ($0.repoPath, $0) })
    }

    func save(_ mapping: RepoMapping) {
        try? db.pool.write { try mapping.save($0) }
    }

    func submissions(on date: String) -> [Submission] {
        (try? db.pool.read { try Submission.filter(Column("date") == date).fetchAll($0) }) ?? []
    }

    func submissions(since minDate: String) -> [Submission] {
        (try? db.pool.read { try Submission.filter(Column("date") >= minDate).fetchAll($0) }) ?? []
    }

    func submissions(from startDate: String, to endDate: String) -> [Submission] {
        (try? db.pool.read {
            try Submission
                .filter(Column("date") >= startDate && Column("date") <= endDate)
                .order(Column("date").asc, Column("id").asc)
                .fetchAll($0)
        }) ?? []
    }

    func add(_ submission: Submission) {
        try? db.pool.write { try submission.insert($0) }
    }

    func lastTasks() -> [String: Int] {
        let rows = (try? db.pool.read { try Row.fetchAll($0, sql: "SELECT repoPath, taskID FROM zentaoLastTask") }) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["repoPath"] as String, $0["taskID"] as Int) })
    }

    func setLastTask(_ taskID: Int, for repos: [String]) {
        try? db.pool.write { db in
            for repo in repos {
                try db.execute(sql: "INSERT OR REPLACE INTO zentaoLastTask(repoPath, taskID) VALUES (?, ?)", arguments: [repo, taskID])
            }
        }
    }

    func pendingDrafts(since minDate: String) -> [String: [DraftEntry]] {
        let rows = (try? db.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT date, payload FROM zentaoPendingDraft WHERE date >= ?", arguments: [minDate])
        }) ?? []
        return Self.decodePendingRows(rows)
    }

    func pendingDrafts(from startDate: String, to endDate: String) -> [String: [DraftEntry]] {
        let rows = (try? db.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT date, payload FROM zentaoPendingDraft WHERE date >= ? AND date <= ?",
                arguments: [startDate, endDate]
            )
        }) ?? []
        return Self.decodePendingRows(rows)
    }

    private static func decodePendingRows(_ rows: [Row]) -> [String: [DraftEntry]] {
        let decoder = JSONDecoder()
        var out: [String: [DraftEntry]] = [:]
        for row in rows {
            guard let date: String = row["date"],
                  let payload: String = row["payload"],
                  let data = payload.data(using: .utf8),
                  let entries = try? decoder.decode([DraftEntry].self, from: data) else {
                continue
            }
            let pending = entries.filter { !$0.isRecorded }
            if !pending.isEmpty {
                out[date] = pending
            }
        }
        return out
    }

    @discardableResult
    func savePendingDrafts(_ entries: [DraftEntry], for date: String) -> Bool {
        let pending = entries.filter { !$0.isRecorded }
        if pending.isEmpty {
            return (try? db.pool.write { db in
                try db.execute(sql: "DELETE FROM zentaoPendingDraft WHERE date = ?", arguments: [date])
            }) != nil
        }
        guard let data = try? JSONEncoder().encode(pending),
              let payload = String(data: data, encoding: .utf8) else {
            return false
        }
        let now = Date()
        return (try? db.pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO zentaoPendingDraft(date, payload, updatedAt) VALUES (?, ?, ?)",
                arguments: [date, payload, now]
            )
        }) != nil
    }
}
