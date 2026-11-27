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
    case tita

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "标准周报"
        case .byProject: "按项目汇总"
        case .concise: "精简要点"
        case .tita: "Tita 模板"
        }
    }

    public var detail: String {
        switch self {
        case .standard: "包含本周完成工作、问题与风险、下周工作计划，适合正式周报。"
        case .byProject: "按禅道项目或模块归类本周产出并附工时明细，适合项目同步。"
        case .concise: "输出紧凑清晰的要点清单，适合直接发到飞书或钉钉群。"
        case .tita: "按 Tita 周报/月报的四个总结模块输出：亮点与成功经验、问题与不足、改进思考与行动、下一步工作计划。"
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
        case .tita:
            "采用「Tita 模板」结构，严格使用以下四个二级标题输出：`## 亮点与成功经验`（按项目或模块提炼本周核心成果与价值，若需附带工时请在末尾简明列出）、`## 问题与不足`（若日报中无明确阻塞可写暂无）、`## 改进思考与行动`（针对问题或效率提升给出具体改进动作，无明显问题可写持续保持现状并优化细节）、`## 下一步工作计划`。"
        }
    }

    public var monthlyPromptInstruction: String {
        switch self {
        case .standard:
            "采用公司月报规范五段结构输出，严格使用以下二级标题：`## 一、当月OKR完成情况`（逐条对照本月 OKR 用量化数据说明完成进度百分比或实际数值，未完成项说明偏差原因）、`## 二、当月亮点工作`（提炼最具代表性与产出价值的成果，每项附带项目/工时/提交/效率等关键数据支撑，避免流水账）、`## 三、当月存在的问题及改进措施 / 建议`（分「存在的问题」与「改进措施 / 建议」写清具体问题、根因和可落地动作，杜绝“加强学习/提高重视”等空话）、`## 四、下一个月工作重点`（对齐下月目标列出核心任务与预期量化指标）、`## 附：Git 数据概览`（仅在提供了 Git 提交统计时简明列出关键量化数据，不要编造数字）。"
        case .byProject:
            "采用「按项目汇总」结构，按禅道项目（未关联项目归入其他工作）分小节梳理本月核心产出与关键进度，结合本月 OKR 与 Git 提交数据突出量化成果，并在文末汇总本月工时与代码分布。"
        case .concise:
            "采用「精简要点」结构，提炼本月 OKR 完成度、核心成果清单与工时/Git 数据结论，条理紧凑、便于直接在飞书/钉钉汇报或同步。"
        case .tita:
            "采用「Tita 模板」结构，严格使用以下四个二级标题输出：`## 亮点与成功经验`（融合本月 OKR 量化达成情况、跨周重点交付成果以及工时/Git 关键数据支撑，避免流水账）、`## 问题与不足`（明确列出本月实际遇到的具体问题并分析根本原因，无明确阻塞可写暂无）、`## 改进思考与行动`（针对上述问题提出可落地的改进措施或建议，杜绝“加强学习/提高重视”等空话）、`## 下一步工作计划`（对齐下月目标与 OKR，列出核心工作重点并预估关键产出或量化指标）。"
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
    static let includeGitStats = SettingKey<Bool>("report.monthly.includeGitStats", default: true)
    static let lastPeriodKind = SettingKey<ReportPeriodKind>("report.lastPeriodKind", default: .weekly)
    static let titaBaseURL = SettingKey<String>("report.tita.baseURL", default: "https://www.tita.net")
    static let titaCookie = SettingKey<String>("report.tita.cookie", default: "")
    static let titaTenantID = SettingKey<String>("report.tita.tenantID", default: "")
    static let titaUserID = SettingKey<String>("report.tita.userID", default: "")
    static let titaUserName = SettingKey<String>("report.tita.userName", default: "")
    static let titaWeeklyTemplateID = SettingKey<Int>("report.tita.weeklyTemplateID", default: 1006)
    static let titaMonthlyTemplateID = SettingKey<Int>("report.tita.monthlyTemplateID", default: 1007)
    static let titaDefaultMood = SettingKey<Int>("report.tita.defaultMood", default: 0)
    static let feishuCLIPath = SettingKey<String>("report.feishu.cliPath", default: "")
    static let feishuMonthlyDocURL = SettingKey<String>("report.feishu.monthlyDocURL", default: "")
    static let annualStyle = SettingKey<AnnualReviewStyle>("report.annual.style", default: .performanceSTAR)
    static let annualPrompt = SettingKey<String>("report.annual.prompt", default: AnnualReviewGenerator.defaultPrompt)
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
    var monthlyOKR: String = ""
}

/// 按季度 / 半年度 / 全年保存的述职总结记录。
nonisolated struct ReviewReportRecord: Sendable, Hashable, Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reviewReport"

    var id: String { periodKey }
    var periodKey: String
    var scopeKind: String
    var periodStart: String
    var periodEnd: String
    var title: String
    var content: String
    var extraNotes: String
    var style: String
    var providerName: String
    var totalHours: Double
    var overtimeHours: Double
    var commitCount: Int
    var generatedAt: Date
    var updatedAt: Date
}

/// 周报/月报插件数据库迁移。
public nonisolated enum ReportMigrations {
    public static let weekly = DatabaseMigration("report.v1") { db in
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
    }

    public static let monthly = DatabaseMigration("report.v2") { db in
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
    }

    public static let review = DatabaseMigration("report.v3") { db in
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
        try db.create(index: "idx_reviewReport_updatedAt", on: "reviewReport", columns: ["updatedAt"])
    }

    public static let monthlyOKR = DatabaseMigration("report.v4") { db in
        try db.alter(table: "monthlyReport") { t in
            t.add(column: "monthlyOKR", .text).notNull().defaults(to: "")
        }
    }

    public static let all: [DatabaseMigration] = [weekly, monthly, review, monthlyOKR]
}

/// 周报/月报数据库读写。
nonisolated struct ReportStore {
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

    func recentReports(limit: Int = 100) -> [WeeklyReportRecord] {
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

    func recentMonthlyReports(limit: Int = 60) -> [MonthlyReportRecord] {
        (try? db.pool.read { db in
            try MonthlyReportRecord
                .order(Column("monthKey").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func monthlyReports(matchingMonthKeys monthKeys: [String]) -> [MonthlyReportRecord] {
        guard !monthKeys.isEmpty else { return [] }
        return (try? db.pool.read { db in
            try MonthlyReportRecord
                .filter(monthKeys.contains(Column("monthKey")))
                .order(Column("monthKey").asc)
                .fetchAll(db)
        }) ?? []
    }

    func reviewReport(forPeriodKey periodKey: String) -> ReviewReportRecord? {
        try? db.pool.read { db in
            try ReviewReportRecord.filter(Column("periodKey") == periodKey).fetchOne(db)
        }
    }

    func saveReview(_ record: ReviewReportRecord) {
        try? db.pool.write { db in
            try record.save(db)
        }
    }

    func deleteReview(periodKey: String) {
        _ = try? db.pool.write { db in
            try ReviewReportRecord.filter(Column("periodKey") == periodKey).deleteAll(db)
        }
    }

    func recentReviews(limit: Int = 40) -> [ReviewReportRecord] {
        (try? db.pool.read { db in
            try ReviewReportRecord
                .order(Column("periodKey").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }
}
