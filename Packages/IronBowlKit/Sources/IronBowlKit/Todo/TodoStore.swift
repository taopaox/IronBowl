import Foundation
import GRDB
import Observation
import SwiftUI

/// 待办事项优先级。
public nonisolated enum TodoPriority: Int, Codable, Sendable, CaseIterable, Identifiable {
    case normal = 0
    case important = 1
    case urgent = 2

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .normal: "普通"
        case .important: "重要"
        case .urgent: "紧急"
        }
    }

    @MainActor
    public var tint: Color {
        switch self {
        case .normal: DS.textSecondary
        case .important: DS.warning
        case .urgent: DS.danger
        }
    }
}

/// 跨「待办」「万年历」「禅道日报」共享的待办与备忘数据模型。
public nonisolated struct TodoItem: Sendable, Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "todoItem"

    public var id: String
    public var title: String
    public var notes: String
    /// 截止/日程日期（`yyyy-MM-dd`），nil 表示无日期随手待办。
    public var dueDate: String?
    public var remindAt: Date?
    public var remindedAt: Date?
    public var priority: Int
    public var estimatedHours: Double
    public var isCompleted: Bool
    public var completedAt: Date?
    /// 已转入哪一天禅道日报草稿（`yyyy-MM-dd`），nil 表示未转入。
    public var loggedDate: String?
    /// 关联的禅道对象类型（`"task"` 或 `"bug"`）。
    public var zentaoObjectType: String?
    /// 关联的禅道对象 ID。
    public var zentaoObjectID: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        notes: String = "",
        dueDate: String? = nil,
        remindAt: Date? = nil,
        remindedAt: Date? = nil,
        priority: TodoPriority = .normal,
        estimatedHours: Double = 1.0,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        loggedDate: String? = nil,
        zentaoObjectType: String? = nil,
        zentaoObjectID: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.remindAt = remindAt
        self.remindedAt = remindedAt
        self.priority = priority.rawValue
        self.estimatedHours = max(0.5, (estimatedHours * 2).rounded() / 2)
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.loggedDate = loggedDate
        self.zentaoObjectType = zentaoObjectType
        self.zentaoObjectID = zentaoObjectID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var priorityLevel: TodoPriority {
        get { TodoPriority(rawValue: priority) ?? .normal }
        set { priority = newValue.rawValue }
    }

    public func isOverdue(todayString: String) -> Bool {
        guard !isCompleted, let dueDate, !dueDate.isEmpty else { return false }
        return dueDate < todayString
    }

    public func isDueToday(todayString: String) -> Bool {
        guard let dueDate, !dueDate.isEmpty else { return false }
        return dueDate == todayString
    }
}

/// 跨工作台与独立版万年历共享的待办存储（带跨进程实时同步）。
@Observable
public final class TodoStore {
    private static let changeNotification = Notification.Name("com.taopaox.ironbowl.todosDidChange")

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    public private(set) var items: [TodoItem] = []

    public init(database: AppDatabase) {
        self.database = database
        reload()
        let myPID = ProcessInfo.processInfo.processIdentifier
        let dbPath = database.path
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.changeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let payload = note.object as? String
            Task { @MainActor [weak self] in
                guard let self, let payload else { return }
                let parts = payload.split(separator: "|", maxSplits: 1)
                guard parts.count == 2,
                      Int32(parts[0]) != myPID,
                      String(parts[1]) == dbPath else { return }
                self.reload()
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func notifyExternalChange() {
        let payload = "\(ProcessInfo.processInfo.processIdentifier)|\(database.path)"
        DistributedNotificationCenter.default().postNotificationName(
            Self.changeNotification,
            object: payload,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public func reload() {
        let fetched: [TodoItem] = (try? database.pool.read { db in
            try TodoItem
                .order(Column("isCompleted").asc, Column("priority").desc, Column("createdAt").desc)
                .fetchAll(db)
        }) ?? []
        items = fetched
    }

    @discardableResult
    public func add(
        title: String,
        notes: String = "",
        dueDate: String? = nil,
        remindAt: Date? = nil,
        priority: TodoPriority = .normal,
        estimatedHours: Double = 1.0,
        zentaoObjectType: String? = nil,
        zentaoObjectID: Int? = nil
    ) -> TodoItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let normalizedDue = dueDate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = TodoItem(
            title: trimmed,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            dueDate: (normalizedDue?.isEmpty == false) ? normalizedDue : nil,
            remindAt: remindAt,
            remindedAt: nil,
            priority: priority,
            estimatedHours: estimatedHours,
            isCompleted: false,
            completedAt: nil,
            loggedDate: nil,
            zentaoObjectType: zentaoObjectType,
            zentaoObjectID: zentaoObjectID,
            createdAt: now,
            updatedAt: now
        )
        do {
            try database.pool.write { db in
                try item.insert(db)
            }
        } catch {
            return nil
        }
        reload()
        notifyExternalChange()
        return item
    }

    public func update(_ item: TodoItem) {
        var next = item
        next.title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.title.isEmpty else { return }
        next.estimatedHours = max(0.5, (next.estimatedHours * 2).rounded() / 2)
        next.updatedAt = Date()
        if let old = items.first(where: { $0.id == next.id }), old.remindAt != next.remindAt {
            next.remindedAt = nil
        }
        try? database.pool.write { db in
            try next.update(db)
        }
        reload()
        notifyExternalChange()
    }

    public func toggleCompleted(id: String, now: Date = Date()) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.isCompleted.toggle()
        item.completedAt = item.isCompleted ? now : nil
        item.updatedAt = now
        try? database.pool.write { db in
            try item.update(db)
        }
        reload()
        notifyExternalChange()
    }

    public func markLogged(id: String, dateString: String) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.loggedDate = dateString
        item.updatedAt = Date()
        try? database.pool.write { db in
            try item.update(db)
        }
        reload()
        notifyExternalChange()
    }

    public func markReminded(id: String, at date: Date = Date()) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.remindedAt = date
        item.updatedAt = date
        try? database.pool.write { db in
            try item.update(db)
        }
        reload()
        notifyExternalChange()
    }

    public func snoozeReminder(id: String, minutes: Int, from now: Date = Date()) {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.remindAt = now.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        item.remindedAt = nil
        item.updatedAt = now
        try? database.pool.write { db in
            try item.update(db)
        }
        reload()
        notifyExternalChange()
    }

    public func delete(id: String) {
        try? database.pool.write { db in
            _ = try TodoItem.deleteOne(db, key: id)
        }
        reload()
        notifyExternalChange()
    }

    public func clearCompleted() {
        try? database.pool.write { db in
            try db.execute(sql: "DELETE FROM todoItem WHERE isCompleted = 1")
        }
        reload()
        notifyExternalChange()
    }

    // MARK: - 查询

    public func items(on date: Date) -> [TodoItem] {
        items(forDateString: WorkCalendar.dayString(date))
    }

    public func items(forDateString ds: String) -> [TodoItem] {
        items
            .filter { item in
                if item.dueDate == ds { return true }
                if let completedAt = item.completedAt, WorkCalendar.dayString(completedAt) == ds {
                    return true
                }
                return false
            }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.createdAt > rhs.createdAt
            }
    }

    public func counts(on date: Date) -> (incomplete: Int, completed: Int) {
        let ds = WorkCalendar.dayString(date)
        var incomplete = 0
        var completed = 0
        for item in items where item.dueDate == ds {
            if item.isCompleted {
                completed += 1
            } else {
                incomplete += 1
            }
        }
        return (incomplete, completed)
    }

    public func todayIncompleteCount(now: Date = Date()) -> Int {
        let today = WorkCalendar.dayString(now)
        return items.filter { item in
            guard !item.isCompleted, let due = item.dueDate, !due.isEmpty else { return false }
            return due <= today
        }.count
    }

    public func overdueCount(now: Date = Date()) -> Int {
        let today = WorkCalendar.dayString(now)
        return items.filter { $0.isOverdue(todayString: today) }.count
    }

    public func dueReminderItems(at now: Date = Date()) -> [TodoItem] {
        items.filter { item in
            !item.isCompleted
                && item.remindAt != nil
                && item.remindAt! <= now
                && item.remindedAt == nil
        }
    }
}
