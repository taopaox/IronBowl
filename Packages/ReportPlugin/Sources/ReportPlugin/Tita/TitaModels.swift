import Foundation

/// Tita 工作总结周期类型：`26` 周报、`27` 月报。
public nonisolated enum TitaSummaryType: Int, Codable, Sendable, CaseIterable {
    case weekly = 26
    case monthly = 27

    public init(periodKind: ReportPeriodKind) {
        switch periodKind {
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        }
    }

    public var activeKey: String {
        switch self {
        case .weekly: "week"
        case .monthly: "month"
        }
    }

    public var displayName: String {
        switch self {
        case .weekly: "周报"
        case .monthly: "月报"
        }
    }
}

/// Tita 总结提交状态枚举（对应 `summaryStatu` / `summaryStatus` / `submitState`）。
public nonisolated enum TitaSubmitState: Int, Codable, Sendable, Equatable {
    case none = 0
    case onTime = 1
    case delay = 2
    case unSubmit = 3

    public init(rawInt: Int?) {
        self = rawInt.flatMap(TitaSubmitState.init(rawValue:)) ?? .none
    }

    public var displayName: String {
        switch self {
        case .none: "未创建"
        case .onTime: "按时提交"
        case .delay: "延时提交"
        case .unSubmit: "草稿/未提交"
        }
    }

    public var isSubmitted: Bool {
        self == .onTime || self == .delay
    }
}

/// Tita 心情模块枚举（`0..4`）。
public nonisolated enum TitaMood: Int, Codable, Sendable, CaseIterable, Identifiable {
    case unset = 0
    case happy = 1
    case fighting = 2
    case hardToPutWords = 3
    case stressful = 4

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .unset: "不选"
        case .happy: "开心"
        case .fighting: "加油"
        case .hardToPutWords: "一言难尽"
        case .stressful: "压力大"
        }
    }
}

/// 验证登录态后解析得到的 Tita 当前账号与租户信息。
public nonisolated struct TitaAccountInfo: Sendable, Equatable {
    public let tenantID: String
    public let userID: String
    public let userName: String

    public init(tenantID: String, userID: String, userName: String) {
        self.tenantID = tenantID
        self.userID = userID
        self.userName = userName
    }
}

/// Tita 指定周期的提交状态摘要。
public nonisolated struct TitaPeriodStatus: Sendable, Equatable {
    public let summaryDate: String
    public let summaryType: TitaSummaryType
    public let state: TitaSubmitState
    public let dailyID: String
    public let templateID: Int?
    public let submitDate: String?
    public let delayDate: String?

    public init(
        summaryDate: String,
        summaryType: TitaSummaryType,
        state: TitaSubmitState,
        dailyID: String,
        templateID: Int?,
        submitDate: String? = nil,
        delayDate: String? = nil
    ) {
        self.summaryDate = summaryDate
        self.summaryType = summaryType
        self.state = state
        self.dailyID = dailyID
        self.templateID = templateID
        self.submitDate = submitDate
        self.delayDate = delayDate
    }
}

/// Tita 模板元信息（用于自动探测周报/月报模板 ID 与富文本模块名称）。
public nonisolated struct TitaTemplateSummary: Sendable, Equatable {
    public let templateID: Int
    public let name: String
    public let richtextModuleNames: [String]

    public init(templateID: Int, name: String, richtextModuleNames: [String]) {
        self.templateID = templateID
        self.name = name
        self.richtextModuleNames = richtextModuleNames
    }
}

/// Tita 报告详情里的单个模块。
public nonisolated struct TitaReportModule: Sendable, Identifiable, Equatable {
    public var id: Int { moduleId }
    public let moduleId: Int
    public let moduleName: String
    public let moduleType: String
    public let moduleObjType: Int
    public let sortIndex: Int
    public let isDelete: Bool
    public let plainText: String
    public let richTextHTML: String
    public let rawObjectDataJSON: String

    public init(
        moduleId: Int,
        moduleName: String,
        moduleType: String,
        moduleObjType: Int,
        sortIndex: Int,
        isDelete: Bool,
        plainText: String,
        richTextHTML: String,
        rawObjectDataJSON: String
    ) {
        self.moduleId = moduleId
        self.moduleName = moduleName
        self.moduleType = moduleType
        self.moduleObjType = moduleObjType
        self.sortIndex = sortIndex
        self.isDelete = isDelete
        self.plainText = plainText
        self.richTextHTML = richTextHTML
        self.rawObjectDataJSON = rawObjectDataJSON
    }
}

/// Tita 报告详情（对应 `summary/detail` 与 `summary/create` 的 `Data`）。
public nonisolated struct TitaReportDetail: Sendable, Equatable {
    public let dailyID: String
    public let summaryDate: String
    public let summaryType: TitaSummaryType
    public let submitState: TitaSubmitState
    public let templateID: Int
    public let delayDate: String?
    public let modules: [TitaReportModule]

    public init(
        dailyID: String,
        summaryDate: String,
        summaryType: TitaSummaryType,
        submitState: TitaSubmitState,
        templateID: Int,
        delayDate: String?,
        modules: [TitaReportModule]
    ) {
        self.dailyID = dailyID
        self.summaryDate = summaryDate
        self.summaryType = summaryType
        self.submitState = submitState
        self.templateID = templateID
        self.delayDate = delayDate
        self.modules = modules
    }

    public var richtextModules: [TitaReportModule] {
        modules
            .filter { $0.moduleType == "richtext" && $0.moduleObjType == 0 && !$0.isDelete }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    public var moodModule: TitaReportModule? {
        modules.first { $0.moduleObjType == 1 && !$0.isDelete }
    }

    public var currentMood: TitaMood {
        guard let raw = moodModule?.rawObjectDataJSON.trimmingCharacters(in: .whitespacesAndNewlines),
              let intVal = Int(raw),
              let mood = TitaMood(rawValue: intVal) else {
            return .unset
        }
        return mood
    }
}

/// 推送弹窗里供用户核对与微调的富文本模块模型。
public nonisolated struct TitaEditableModule: Sendable, Identifiable, Equatable {
    public let id: String
    public let moduleId: Int?
    public let moduleName: String
    public let sortIndex: Int
    public var text: String
    public let existingRemoteText: String

    public init(
        id: String,
        moduleId: Int?,
        moduleName: String,
        sortIndex: Int,
        text: String,
        existingRemoteText: String
    ) {
        self.id = id
        self.moduleId = moduleId
        self.moduleName = moduleName
        self.sortIndex = sortIndex
        self.text = text
        self.existingRemoteText = existingRemoteText
    }
}

/// Tita 接口调用错误。
public nonisolated enum TitaError: LocalizedError, Sendable, Equatable {
    case notConfigured
    case missingIdentity
    case sessionExpired
    case httpError(Int, String)
    case apiError(code: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "尚未配置 Tita 登录 Cookie"
        case .missingIdentity:
            "未能识别 Tita 租户 ID 或用户 ID，请先测试连接或补充填写"
        case .sessionExpired:
            "Tita 登录已过期或 Cookie 无效，请重新登录或粘贴新的 Cookie"
        case .httpError(let status, let detail):
            detail.isEmpty ? "Tita 请求失败（HTTP \(status)）" : "Tita 请求失败（HTTP \(status)）：\(detail)"
        case .apiError(let code, let message):
            message.isEmpty ? "Tita 接口返回错误（Code=\(code)）" : "Tita 接口返回错误（Code=\(code)）：\(message)"
        case .badResponse(let sample):
            "Tita 返回了无法解析的数据：\(sample.prefix(160))"
        }
    }
}

// MARK: - 历史列表查询与同步模型

/// `summary/search` 返回的单条报告中的模块内容（对应 `dailyContent[]`）。
public nonisolated struct TitaSearchFeedSection: Sendable, Equatable {
    public let contentType: Int
    public let title: String
    public let richContent: String
    public let content: String

    public init(contentType: Int, title: String, richContent: String, content: String) {
        self.contentType = contentType
        self.title = title
        self.richContent = richContent
        self.content = content
    }
}

/// `summary/search` 返回的单条周报 / 月报记录。
public nonisolated struct TitaSearchFeedItem: Sendable, Equatable {
    public let feedID: String
    public let dailyDate: String
    public let reportType: TitaSummaryType
    public let name: String
    public let submitState: TitaSubmitState
    public let submitDate: String?
    public let createDate: String?
    public let newSummary: Bool
    public let sections: [TitaSearchFeedSection]
    public let legacyContentHTML: String
    public let legacyWorkPlanHTML: String

    public init(
        feedID: String,
        dailyDate: String,
        reportType: TitaSummaryType,
        name: String,
        submitState: TitaSubmitState,
        submitDate: String?,
        createDate: String? = nil,
        newSummary: Bool = true,
        sections: [TitaSearchFeedSection] = [],
        legacyContentHTML: String = "",
        legacyWorkPlanHTML: String = ""
    ) {
        self.feedID = feedID
        self.dailyDate = dailyDate
        self.reportType = reportType
        self.name = name
        self.submitState = submitState
        self.submitDate = submitDate
        self.createDate = createDate
        self.newSummary = newSummary
        self.sections = sections
        self.legacyContentHTML = legacyContentHTML
        self.legacyWorkPlanHTML = legacyWorkPlanHTML
    }
}

/// `summary/search` 单页响应。
public nonisolated struct TitaSearchPage: Sendable, Equatable {
    public let feeds: [TitaSearchFeedItem]
    public let isEnd: Bool
    public let lastID: String?

    public init(feeds: [TitaSearchFeedItem], isEnd: Bool, lastID: String?) {
        self.feeds = feeds
        self.isEnd = isEnd
        self.lastID = lastID
    }
}

/// 历史同步范围。
public nonisolated enum TitaSyncScope: Sendable, Equatable {
    case weekly
    case monthly
    case all
}

/// 单个周期类型（周报或月报）的同步计数统计。
public nonisolated struct TitaPeriodSyncStats: Sendable, Equatable {
    public var fetched: Int
    public var inserted: Int
    public var updated: Int
    public var skipped: Int
    public var ignoredEmpty: Int

    public init(fetched: Int = 0, inserted: Int = 0, updated: Int = 0, skipped: Int = 0, ignoredEmpty: Int = 0) {
        self.fetched = fetched
        self.inserted = inserted
        self.updated = updated
        self.skipped = skipped
        self.ignoredEmpty = ignoredEmpty
    }
}

/// 历史周报/月报同步汇总结果。
public nonisolated struct TitaHistorySyncResult: Sendable, Equatable {
    public let scope: TitaSyncScope
    public let weekly: TitaPeriodSyncStats
    public let monthly: TitaPeriodSyncStats

    public init(scope: TitaSyncScope, weekly: TitaPeriodSyncStats = .init(), monthly: TitaPeriodSyncStats = .init()) {
        self.scope = scope
        self.weekly = weekly
        self.monthly = monthly
    }

    public var summaryText: String {
        switch scope {
        case .weekly:
            return Self.formatPart("周报", stats: weekly)
        case .monthly:
            return Self.formatPart("月报", stats: monthly)
        case .all:
            return "\(Self.formatPart("周报", stats: weekly))；\(Self.formatPart("月报", stats: monthly))"
        }
    }

    private static func formatPart(_ label: String, stats: TitaPeriodSyncStats) -> String {
        var parts = ["新增 \(stats.inserted) 份"]
        if stats.updated > 0 { parts.append("更新 \(stats.updated) 份") }
        if stats.skipped > 0 { parts.append("保留本地 \(stats.skipped) 份") }
        if stats.inserted == 0 && stats.updated == 0 && stats.skipped == 0 {
            return "\(label)暂无可导入内容（远端 \(stats.fetched) 条）"
        }
        return "\(label)（远端 \(stats.fetched) 条）：\(parts.joined(separator: "，"))"
    }
}
