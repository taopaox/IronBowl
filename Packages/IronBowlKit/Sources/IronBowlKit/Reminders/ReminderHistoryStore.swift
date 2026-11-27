import Foundation
import GRDB

/// 提醒来源分类。
public nonisolated enum ReminderSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case zentao
    case scheduler
    case attendance
    case todo
    case general

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zentao: "禅道日志"
        case .scheduler: "定时任务"
        case .attendance: "考勤同步"
        case .todo: "待办备忘"
        case .general: "系统提醒"
        }
    }

    public var systemImage: String {
        switch self {
        case .zentao: "square.and.pencil"
        case .scheduler: "clock.badge.checkmark"
        case .attendance: "person.badge.clock"
        case .todo: "checklist"
        case .general: "bell.fill"
        }
    }

    /// 根据提醒 ID 前缀推断所属来源。
    public static func infer(fromReminderID id: String) -> ReminderSource {
        if id.hasPrefix("zentao.") { return .zentao }
        if id.hasPrefix("scheduler.") { return .scheduler }
        if id.hasPrefix("core.attendance.") { return .attendance }
        if id.hasPrefix("todo.") { return .todo }
        return .general
    }
}

/// 提醒投递状态（对应桌面弹窗或系统通知的发送结果）。
public nonisolated enum ReminderDeliveryStatus: String, Codable, Sendable, Equatable {
    case delivered
    case unavailable
    case permissionDenied
    case alertsDisabled
    case failed

    public var displayName: String {
        switch self {
        case .delivered: "已送达"
        case .unavailable: "未送达（非应用环境）"
        case .permissionDenied: "未授权系统通知"
        case .alertsDisabled: "系统通知横幅已关闭"
        case .failed: "发送失败"
        }
    }

    public var isSuccess: Bool { self == .delivered }

    public static func from(_ result: ReminderDeliveryResult) -> (status: ReminderDeliveryStatus, detail: String) {
        switch result {
        case .delivered:
            (.delivered, "")
        case .unavailable:
            (.unavailable, "当前未以 .app 应用形态运行，无法投递系统通知。")
        case .permissionDenied:
            (.permissionDenied, "未获得系统通知授权，请在「系统设置 → 通知」中开启。")
        case .alertsDisabled:
            (.alertsDisabled, "系统通知横幅/提醒样式当前已关闭。")
        case .failed(let message):
            (.failed, message)
        }
    }
}

/// 持久化在 SQLite 中的历史提醒记录。
public nonisolated struct ReminderHistoryRecord: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let reminderID: String
    public let title: String
    public let message: String
    public let systemImage: String
    public let source: ReminderSource
    public let style: ReminderStyle
    public var deliveryStatus: ReminderDeliveryStatus
    public var deliveryDetail: String
    public var isRead: Bool
    public var readAt: Date?
    public var handledActionTitle: String?
    public var handledAt: Date?
    public let targetPluginID: String?
    public let targetSettingsPage: String?
    public let createdAt: Date

    public init(
        id: Int64,
        reminderID: String,
        title: String,
        message: String,
        systemImage: String,
        source: ReminderSource,
        style: ReminderStyle,
        deliveryStatus: ReminderDeliveryStatus,
        deliveryDetail: String,
        isRead: Bool,
        readAt: Date?,
        handledActionTitle: String?,
        handledAt: Date?,
        targetPluginID: String?,
        targetSettingsPage: String?,
        createdAt: Date
    ) {
        self.id = id
        self.reminderID = reminderID
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.source = source
        self.style = style
        self.deliveryStatus = deliveryStatus
        self.deliveryDetail = deliveryDetail
        self.isRead = isRead
        self.readAt = readAt
        self.handledActionTitle = handledActionTitle
        self.handledAt = handledAt
        self.targetPluginID = targetPluginID
        self.targetSettingsPage = targetSettingsPage
        self.createdAt = createdAt
    }
}

/// 写入历史表前的草稿对象。
public nonisolated struct ReminderHistoryDraft: Sendable {
    public let reminderID: String
    public let title: String
    public let message: String
    public let systemImage: String
    public let source: ReminderSource
    public let style: ReminderStyle
    public let deliveryStatus: ReminderDeliveryStatus
    public let deliveryDetail: String
    public let targetPluginID: String?
    public let targetSettingsPage: String?
    public let createdAt: Date

    public init(
        reminderID: String,
        title: String,
        message: String,
        systemImage: String,
        source: ReminderSource,
        style: ReminderStyle,
        deliveryStatus: ReminderDeliveryStatus = .delivered,
        deliveryDetail: String = "",
        targetPluginID: String? = nil,
        targetSettingsPage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.reminderID = reminderID
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.source = source
        self.style = style
        self.deliveryStatus = deliveryStatus
        self.deliveryDetail = deliveryDetail
        self.targetPluginID = targetPluginID
        self.targetSettingsPage = targetSettingsPage
        self.createdAt = createdAt
    }
}

private nonisolated struct ReminderHistoryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reminderHistory"

    var id: Int64?
    var reminderID: String
    var title: String
    var message: String
    var systemImage: String
    var source: String
    var style: String
    var deliveryStatus: String
    var deliveryDetail: String
    var isRead: Bool
    var readAt: Date?
    var handledActionTitle: String?
    var handledAt: Date?
    var targetPluginID: String?
    var targetSettingsPage: String?
    var createdAt: Date

    init(from draft: ReminderHistoryDraft) {
        id = nil
        reminderID = draft.reminderID
        title = draft.title
        message = draft.message
        systemImage = draft.systemImage
        source = draft.source.rawValue
        style = draft.style.rawValue
        deliveryStatus = draft.deliveryStatus.rawValue
        deliveryDetail = draft.deliveryDetail
        isRead = false
        readAt = nil
        handledActionTitle = nil
        handledAt = nil
        targetPluginID = draft.targetPluginID
        targetSettingsPage = draft.targetSettingsPage
        createdAt = draft.createdAt
    }

    func toRecord() -> ReminderHistoryRecord? {
        guard let id else { return nil }
        return ReminderHistoryRecord(
            id: id,
            reminderID: reminderID,
            title: title,
            message: message,
            systemImage: systemImage,
            source: ReminderSource(rawValue: source) ?? .general,
            style: ReminderStyle(rawValue: style) ?? .cornerCard,
            deliveryStatus: ReminderDeliveryStatus(rawValue: deliveryStatus) ?? .delivered,
            deliveryDetail: deliveryDetail,
            isRead: isRead,
            readAt: readAt,
            handledActionTitle: handledActionTitle,
            handledAt: handledAt,
            targetPluginID: targetPluginID,
            targetSettingsPage: targetSettingsPage,
            createdAt: createdAt
        )
    }
}

/// 提醒历史记录的 SQLite 读写封装。
public nonisolated struct ReminderHistoryStore: Sendable {
    public let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    @discardableResult
    public func insert(_ draft: ReminderHistoryDraft) -> ReminderHistoryRecord? {
        var row = ReminderHistoryRow(from: draft)
        let insertedID: Int64? = try? db.pool.write { db in
            try row.insert(db)
            return db.lastInsertedRowID
        }
        guard let insertedID else { return nil }
        row.id = insertedID
        return row.toRecord()
    }

    public func updateDelivery(id: Int64, status: ReminderDeliveryStatus, detail: String) {
        try? db.pool.write { db in
            try db.execute(
                sql: """
                UPDATE reminderHistory
                SET deliveryStatus = ?, deliveryDetail = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, detail, id]
            )
        }
    }

    public func markHandled(id: Int64, actionTitle: String, at date: Date = Date()) {
        try? db.pool.write { db in
            try db.execute(
                sql: """
                UPDATE reminderHistory
                SET handledActionTitle = ?, handledAt = ?, isRead = 1, readAt = COALESCE(readAt, ?)
                WHERE id = ?
                """,
                arguments: [actionTitle, date, date, id]
            )
        }
    }

    public func setRead(id: Int64, isRead: Bool, at date: Date = Date()) {
        try? db.pool.write { db in
            if isRead {
                try db.execute(
                    sql: "UPDATE reminderHistory SET isRead = 1, readAt = ? WHERE id = ?",
                    arguments: [date, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE reminderHistory SET isRead = 0, readAt = NULL WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    public func markAllRead(source: ReminderSource? = nil, at date: Date = Date()) {
        try? db.pool.write { db in
            if let source {
                try db.execute(
                    sql: "UPDATE reminderHistory SET isRead = 1, readAt = COALESCE(readAt, ?) WHERE isRead = 0 AND source = ?",
                    arguments: [date, source.rawValue]
                )
            } else {
                try db.execute(
                    sql: "UPDATE reminderHistory SET isRead = 1, readAt = COALESCE(readAt, ?) WHERE isRead = 0",
                    arguments: [date]
                )
            }
        }
    }

    public func delete(id: Int64) {
        try? db.pool.write { db in
            _ = try ReminderHistoryRow.deleteOne(db, key: id)
        }
    }

    public func clearAll(source: ReminderSource? = nil) {
        try? db.pool.write { db in
            if let source {
                try db.execute(sql: "DELETE FROM reminderHistory WHERE source = ?", arguments: [source.rawValue])
            } else {
                try db.execute(sql: "DELETE FROM reminderHistory")
            }
        }
    }

    public func fetchRecent(limit: Int = 500) -> [ReminderHistoryRecord] {
        let rows: [ReminderHistoryRow] = (try? db.pool.read { db in
            try ReminderHistoryRow
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        return rows.compactMap { $0.toRecord() }
    }

    public func prune(keepingLatest: Int = 500) {
        guard keepingLatest > 0 else { return }
        try? db.pool.write { db in
            try db.execute(
                sql: """
                DELETE FROM reminderHistory
                WHERE id NOT IN (
                    SELECT id FROM reminderHistory
                    ORDER BY createdAt DESC, id DESC
                    LIMIT ?
                )
                """,
                arguments: [keepingLatest]
            )
        }
    }
}
