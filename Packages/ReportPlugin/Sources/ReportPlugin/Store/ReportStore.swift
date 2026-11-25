import Foundation
import GRDB
import IronBowlKit

/// 报告周期类型：周报 / 月报。
public nonisolated enum ReportPeriodKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case weekly
    case monthly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .weekly: "周报"
        case .monthly: "月报"
        }
    }
}

/// 周报 / 月报风格。
public nonisolated enum WeeklyReportStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard
    case byProject
    case concise

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "标准周报"
        case .byProject: "按项目汇总"
        case .concise: "精简要点"
        }
    }

    public var detail: String {
        switch self {
        case .standard: "包含本周完成工作、问题与风险、下周工作计划，适合正式周报。"
        case .byProject: "按禅道项目或模块归类本周产出并附工时明细，适合项目同步。"
        case .concise: "输出紧凑清晰的要点清单，适合直接发到飞书或钉钉群。"
        }
    }

    public var promptInstruction: String {
        switch self {
        case .standard:
            "采用「标准周报」结构，包含 `## 本周完成工作`（按模块或项目归类、合并同类项）、`## 问题与风险`（若日报中无明确阻塞可简写暂无）和 `## 下周工作计划`。"
        case .byProject:
            "采用「按项目汇总」结构，按禅道项目（未关联项目归入其他工作）分小节梳理本周工作成果，每个项目下提炼 2-5 条业务要点，并在文末汇总本周工时概况。"
        case .concise:
            "采用「精简要点」结构，去掉繁琐套话，用简洁的 Markdown 列表直接总结本周核心完成事项与工时结论，方便在聊天群内直接发送。"
        }
    }

    public var monthlyPromptInstruction: String {
        switch self {
        case .standard:
            "采用「标准月报」结构，包含 `## 本月重点成果`（跨周整合同类工作、提炼阶段性交付与里程碑）、`## 问题与风险`（若无明确阻塞可简写暂无）和 `## 下月工作计划`。"
        case .byProject:
            "采用「按项目汇总」结构，按禅道项目（未关联项目归入其他工作）分小节梳理本月核心产出与关键进度，并在文末汇总本月工时分布。"
        case .concise:
            "采用「精简要点」结构，提炼本月核心成果清单与工时结论，条理紧凑、便于直接在飞书/钉钉汇报或同步。"
        }
    }
}

/// 周报/月报插件设置键。
enum ReportKeys {
    static let prompt = SettingKey<String>("report.prompt", default: WeeklyReportGenerator.defaultPrompt)
    static let monthlyPrompt = SettingKey<String>("report.monthlyPrompt", default: WeeklyReportGenerator.defaultMonthlyPrompt)
    static let style = SettingKey<WeeklyReportStyle>("report.style", default: .standard)
    static let includeDrafts = SettingKey<Bool>("report.includeDrafts", default: true)
    static let includeHours = SettingKey<Bool>("report.includeHours", default: true)
    static let lastPeriodKind = SettingKey<ReportPeriodKind>("report.lastPeriodKind", default: .weekly)
}

/// 按周保存的周报持久化记录。
nonisolated struct WeeklyReportRecord: Sendable, Hashable, Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "weeklyReport"

    var id: String { weekStart }
    var weekStart: String
    var weekEnd: String
    var title: String
    var content: String
    var extraNotes: String
    var style: String
    var providerName: String
    var totalHours: Double
    var generatedAt: Date
    var updatedAt: Date
}

/// 按月保存的月报持久化记录。
nonisolated struct MonthlyReportRecord: Sendable, Hashable, Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "monthlyReport"

    var id: String { monthKey }
    var monthKey: String
    var periodStart: String
    var periodEnd: String
    var title: String
    var content: String
    var extraNotes: String
    var style: String
    var providerName: String
    var totalHours: Double
    var generatedAt: Date
    var updatedAt: Date
}

/// 周报/月报插件数据库迁移。
enum ReportMigrations {
    static let all: [DatabaseMigration] = [
        DatabaseMigration("report.v1") { db in
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
            try db.create(index: "idx_weeklyReport_updatedAt", on: "weeklyReport", columns: ["updatedAt"])
        },
        DatabaseMigration("report.v2") { db in
            try db.create(table: "monthlyReport") { t in
                t.primaryKey("monthKey", .text)
                t.column("periodStart", .text).notNull()
                t.column("periodEnd", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("extraNotes", .text).notNull().defaults(to: "")
                t.column("style", .text).notNull()
                t.column("providerName", .text).notNull().defaults(to: "")
                t.column("totalHours", .double).notNull().defaults(to: 0)
                t.column("generatedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "idx_monthlyReport_updatedAt", on: "monthlyReport", columns: ["updatedAt"])
        },
    ]
}

/// 周报/月报数据库读写。
struct ReportStore {
    let db: AppDatabase

    func report(forWeekStart weekStart: String) -> WeeklyReportRecord? {
        try? db.pool.read { db in
            try WeeklyReportRecord.filter(Column("weekStart") == weekStart).fetchOne(db)
        }
    }

    func weeklyReports(matchingWeekStarts weekStarts: [String]) -> [WeeklyReportRecord] {
        guard !weekStarts.isEmpty else { return [] }
        return (try? db.pool.read { db in
            try WeeklyReportRecord
                .filter(weekStarts.contains(Column("weekStart")))
                .order(Column("weekStart").asc)
                .fetchAll(db)
        }) ?? []
    }

    func save(_ record: WeeklyReportRecord) {
        try? db.pool.write { db in
            try record.save(db)
        }
    }

    func delete(weekStart: String) {
        _ = try? db.pool.write { db in
            try WeeklyReportRecord.filter(Column("weekStart") == weekStart).deleteAll(db)
        }
    }

    func recentReports(limit: Int = 20) -> [WeeklyReportRecord] {
        (try? db.pool.read { db in
            try WeeklyReportRecord
                .order(Column("weekStart").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func monthlyReport(forMonthKey monthKey: String) -> MonthlyReportRecord? {
        try? db.pool.read { db in
            try MonthlyReportRecord.filter(Column("monthKey") == monthKey).fetchOne(db)
        }
    }

    func saveMonthly(_ record: MonthlyReportRecord) {
        try? db.pool.write { db in
            try record.save(db)
        }
    }

    func deleteMonthly(monthKey: String) {
        _ = try? db.pool.write { db in
            try MonthlyReportRecord.filter(Column("monthKey") == monthKey).deleteAll(db)
        }
    }

    func recentMonthlyReports(limit: Int = 24) -> [MonthlyReportRecord] {
        (try? db.pool.read { db in
            try MonthlyReportRecord
                .order(Column("monthKey").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }
}
