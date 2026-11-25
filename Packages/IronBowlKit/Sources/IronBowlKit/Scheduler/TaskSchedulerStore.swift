import Foundation
import GRDB

private nonisolated struct ScheduledTaskRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scheduledTask"

    var id: String
    var name: String
    var actionID: String
    var isEnabled: Bool
    var scheduleJSON: String
    var misfirePolicy: String
    var notifyPolicy: String
    var notifyStyle: String
    var parametersJSON: String
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastFiredSlot: String?
    var lastStatus: String?
    var lastSummary: String?
    var createdAt: Date
    var updatedAt: Date

    init(from task: ScheduledTask) {
        let encoder = JSONEncoder()
        let scheduleData = (try? encoder.encode(task.schedule)) ?? Data()
        let paramsData = (try? encoder.encode(task.parameters)) ?? Data()
        id = task.id
        name = task.name
        actionID = task.actionID
        isEnabled = task.isEnabled
        scheduleJSON = String(data: scheduleData, encoding: .utf8) ?? "{}"
        misfirePolicy = task.misfirePolicy.rawValue
        notifyPolicy = task.notifyPolicy.rawValue
        notifyStyle = task.notifyStyle.rawValue
        parametersJSON = String(data: paramsData, encoding: .utf8) ?? "{}"
        nextRunAt = task.nextRunAt
        lastRunAt = task.lastRunAt
        lastFiredSlot = task.lastFiredSlot
        lastStatus = task.lastStatus?.rawValue
        lastSummary = task.lastSummary
        createdAt = task.createdAt
        updatedAt = task.updatedAt
    }

    func toTask() -> ScheduledTask? {
        let decoder = JSONDecoder()
        guard let scheduleData = scheduleJSON.data(using: .utf8),
              let schedule = try? decoder.decode(TaskSchedule.self, from: scheduleData) else {
            return nil
        }
        let parameters: [String: String]
        if let paramsData = parametersJSON.data(using: .utf8),
           let decoded = try? decoder.decode([String: String].self, from: paramsData) {
            parameters = decoded
        } else {
            parameters = [:]
        }
        return ScheduledTask(
            id: id,
            name: name,
            actionID: actionID,
            isEnabled: isEnabled,
            schedule: schedule,
            misfirePolicy: MisfirePolicy(rawValue: misfirePolicy) ?? .runIfMissedToday,
            notifyPolicy: TaskNotifyPolicy(rawValue: notifyPolicy) ?? .onSuccessAndFailure,
            notifyStyle: ReminderStyle(rawValue: notifyStyle) ?? .cornerCard,
            parameters: parameters,
            nextRunAt: nextRunAt,
            lastRunAt: lastRunAt,
            lastFiredSlot: lastFiredSlot,
            lastStatus: lastStatus.flatMap(TaskRunStatus.init(rawValue:)),
            lastSummary: lastSummary,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private nonisolated struct ScheduledTaskRunRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scheduledTaskRun"

    var id: Int64?
    var taskID: String
    var taskName: String
    var actionID: String
    var trigger: String
    var status: String
    var startedAt: Date
    var finishedAt: Date?
    var summary: String
    var detail: String

    init(from run: ScheduledTaskRun) {
        id = run.id
        taskID = run.taskID
        taskName = run.taskName
        actionID = run.actionID
        trigger = run.trigger.rawValue
        status = run.status.rawValue
        startedAt = run.startedAt
        finishedAt = run.finishedAt
        summary = run.summary
        detail = run.detail
    }

    func toRun() -> ScheduledTaskRun {
        ScheduledTaskRun(
            id: id,
            taskID: taskID,
            taskName: taskName,
            actionID: actionID,
            trigger: TaskTrigger(rawValue: trigger) ?? .scheduled,
            status: TaskRunStatus(rawValue: status) ?? .failed,
            startedAt: startedAt,
            finishedAt: finishedAt,
            summary: summary,
            detail: detail
        )
    }
}

/// 定时任务与执行历史的 SQLite 读写封装。
public nonisolated struct TaskSchedulerStore: Sendable {
    public let db: AppDatabase

    public init(db: AppDatabase) {
        self.db = db
    }

    public func allTasks() -> [ScheduledTask] {
        let rows = (try? db.pool.read { db in
            try ScheduledTaskRow.order(Column("createdAt").asc).fetchAll(db)
        }) ?? []
        return rows.compactMap { $0.toTask() }
    }

    public func task(id: String) -> ScheduledTask? {
        let row = try? db.pool.read { db in
            try ScheduledTaskRow.fetchOne(db, key: id)
        }
        return row?.toTask()
    }

    public func saveTask(_ task: ScheduledTask) {
        let row = ScheduledTaskRow(from: task)
        try? db.pool.write { db in
            try row.save(db)
        }
    }

    public func deleteTask(id: String, deleteRuns: Bool = false) {
        try? db.pool.write { db in
            _ = try ScheduledTaskRow.deleteOne(db, key: id)
            if deleteRuns {
                try db.execute(sql: "DELETE FROM scheduledTaskRun WHERE taskID = ?", arguments: [id])
            }
        }
    }

    @discardableResult
    public func insertRun(_ run: ScheduledTaskRun) -> Int64? {
        let row = ScheduledTaskRunRow(from: run)
        return try? db.pool.write { db in
            try row.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func updateRun(
        id: Int64,
        status: TaskRunStatus,
        finishedAt: Date,
        summary: String,
        detail: String
    ) {
        try? db.pool.write { db in
            try db.execute(
                sql: """
                UPDATE scheduledTaskRun
                SET status = ?, finishedAt = ?, summary = ?, detail = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, finishedAt, summary, detail, id]
            )
        }
    }

    public func recentRuns(limit: Int = 200, taskID: String? = nil) -> [ScheduledTaskRun] {
        let rows: [ScheduledTaskRunRow] = (try? db.pool.read { db in
            var query = ScheduledTaskRunRow.order(Column("startedAt").desc, Column("id").desc)
            if let taskID {
                query = query.filter(Column("taskID") == taskID)
            }
            return try query.limit(limit).fetchAll(db)
        }) ?? []
        return rows.map { $0.toRun() }
    }

    public func pruneRuns(keepingLatest: Int = 200) {
        guard keepingLatest > 0 else { return }
        try? db.pool.write { db in
            try db.execute(
                sql: """
                DELETE FROM scheduledTaskRun
                WHERE id NOT IN (
                    SELECT id FROM scheduledTaskRun
                    ORDER BY startedAt DESC, id DESC
                    LIMIT ?
                )
                """,
                arguments: [keepingLatest]
            )
        }
    }

    public func clearRuns(taskID: String? = nil) {
        try? db.pool.write { db in
            if let taskID {
                try db.execute(sql: "DELETE FROM scheduledTaskRun WHERE taskID = ?", arguments: [taskID])
            } else {
                try db.execute(sql: "DELETE FROM scheduledTaskRun")
            }
        }
    }

    public func markInterruptedRunsFailed(at date: Date = Date()) {
        try? db.pool.write { db in
            try db.execute(
                sql: """
                UPDATE scheduledTaskRun
                SET status = ?, finishedAt = ?, summary = ?, detail = CASE WHEN detail = '' THEN ? ELSE detail END
                WHERE status = ?
                """,
                arguments: [
                    TaskRunStatus.failed.rawValue,
                    date,
                    "应用退出导致执行中断",
                    "上次应用退出时该任务尚未执行完成。",
                    TaskRunStatus.running.rawValue,
                ]
            )
        }
    }
}
