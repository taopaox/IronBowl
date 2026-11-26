import Foundation
import IronBowlKit

/// 供周报等跨天功能使用的单条每日日报记录。
public nonisolated struct DailyLogItem: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let date: String
    public let taskID: Int?
    public let taskTitle: String?
    public let projectID: Int?
    public let projectName: String?
    public let hours: Double
    public let work: String
    public let isOvertime: Bool
    public let isDraft: Bool

    public init(
        id: String,
        date: String,
        taskID: Int?,
        taskTitle: String?,
        projectID: Int?,
        projectName: String?,
        hours: Double,
        work: String,
        isOvertime: Bool,
        isDraft: Bool
    ) {
        self.id = id
        self.date = date
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.projectID = projectID
        self.projectName = projectName
        self.hours = hours
        self.work = work
        self.isOvertime = isOvertime
        self.isDraft = isDraft
    }
}

/// 按日期区间查询每日日报的汇总结果。
public nonisolated struct DailyLogRangeResult: Sendable {
    public let itemsByDate: [String: [DailyLogItem]]
    public let syncedFromZentao: Bool
    public let zentaoConfigured: Bool
    public let remoteError: String?

    public init(
        itemsByDate: [String: [DailyLogItem]],
        syncedFromZentao: Bool,
        zentaoConfigured: Bool,
        remoteError: String?
    ) {
        self.itemsByDate = itemsByDate
        self.syncedFromZentao = syncedFromZentao
        self.zentaoConfigured = zentaoConfigured
        self.remoteError = remoteError
    }
}

/// 面向其他插件的只读每日日报区间查询服务（融合禅道远端工时、本地已提交与未提交草稿）。
public final class ZentaoDailyLogService {
    public let database: AppDatabase
    public let settings: SettingsStore
    private let store: LogStore
    private var client: ZentaoClient?
    private var clientKey = ""
    private var tasksByID: [Int: ZentaoTask] = [:]

    public init(database: AppDatabase, settings: SettingsStore) {
        self.database = database
        self.settings = settings
        self.store = LogStore(db: database)
    }

    public var isZentaoConfigured: Bool {
        !settings[LogKeys.account].isEmpty && !settings[LogKeys.password].isEmpty
    }

    /// 立即读取本地数据库中的每日日报（已提交 + 可选草稿）。
    public func loadLocal(from startDate: String, to endDate: String, includeDrafts: Bool) -> [String: [DailyLogItem]] {
        let localSubmissions = store.submissions(from: startDate, to: endDate)
        let localByDate = Dictionary(grouping: localSubmissions, by: \.date)
        let pendingByDate = includeDrafts ? store.pendingDrafts(from: startDate, to: endDate) : [:]
        let mappings = store.mappings()
        let projectNames = Self.projectNamesByID(tasksByID: tasksByID, mappings: mappings)
        let dates = Set(localByDate.keys).union(pendingByDate.keys).sorted()
        var out: [String: [DailyLogItem]] = [:]
        for date in dates {
            let items = Self.mergeDailyItems(
                date: date,
                remote: [],
                local: localByDate[date] ?? [],
                pendingDrafts: pendingByDate[date] ?? [],
                tasksByID: tasksByID,
                projectNamesByID: projectNames,
                mappings: mappings
            )
            if !items.isEmpty {
                out[date] = items
            }
        }
        return out
    }

    /// 查询指定日期闭区间（`yyyy-MM-dd`）的每日日报，并在已配置禅道时同步远端工时记录。
    public func fetch(from startDate: String, to endDate: String, includeDrafts: Bool) async -> DailyLogRangeResult {
        let localSubmissions = store.submissions(from: startDate, to: endDate)
        let localByDate = Dictionary(grouping: localSubmissions, by: \.date)
        let pendingByDate = includeDrafts ? store.pendingDrafts(from: startDate, to: endDate) : [:]
        let mappings = store.mappings()
        let lastTasks = store.lastTasks()

        guard isZentaoConfigured else {
            let localItems = assembleItems(
                remoteByDate: [:],
                localByDate: localByDate,
                pendingByDate: pendingByDate,
                tasksByID: tasksByID,
                mappings: mappings
            )
            return DailyLogRangeResult(
                itemsByDate: localItems,
                syncedFromZentao: false,
                zentaoConfigured: false,
                remoteError: nil
            )
        }

        do {
            let zentao = try zentaoClient()
            let myTasks = try await zentao.myTasks()
            let finished = (try? await zentao.finishedTasks()) ?? []
            var nextTasksByID: [Int: ZentaoTask] = [:]
            for t in finished { nextTasksByID[t.id] = t }
            for t in myTasks { nextTasksByID[t.id] = t }
            tasksByID = nextTasksByID

            let openTasks = myTasks.filter(\.isOpen)
            let recentOpen = openTasks.sorted { $0.id > $1.id }.prefix(30).map(\.id)
            let consumedTasks = (myTasks + finished).filter { $0.consumed > 0 }.prefix(40).map(\.id)
            let candidateIDs = Array(
                Set(recentOpen)
                    .union(consumedTasks)
                    .union(lastTasks.values)
                    .union(settings[LogKeys.fallbackTaskID].map { [$0] } ?? [])
                    .union(localSubmissions.map(\.taskID))
            )

            let rawRemote = try await zentao.myEstimates(since: startDate, taskIDs: candidateIDs)
            let remoteByDate = rawRemote.filter { $0.key >= startDate && $0.key <= endDate }
            let items = assembleItems(
                remoteByDate: remoteByDate,
                localByDate: localByDate,
                pendingByDate: pendingByDate,
                tasksByID: nextTasksByID,
                mappings: mappings
            )
            return DailyLogRangeResult(
                itemsByDate: items,
                syncedFromZentao: true,
                zentaoConfigured: true,
                remoteError: nil
            )
        } catch {
            let fallbackItems = assembleItems(
                remoteByDate: [:],
                localByDate: localByDate,
                pendingByDate: pendingByDate,
                tasksByID: tasksByID,
                mappings: mappings
            )
            return DailyLogRangeResult(
                itemsByDate: fallbackItems,
                syncedFromZentao: false,
                zentaoConfigured: true,
                remoteError: error.localizedDescription
            )
        }
    }

    private func assembleItems(
        remoteByDate: [String: [ZentaoEstimate]],
        localByDate: [String: [Submission]],
        pendingByDate: [String: [DraftEntry]],
        tasksByID: [Int: ZentaoTask],
        mappings: [String: RepoMapping]
    ) -> [String: [DailyLogItem]] {
        let projectNames = Self.projectNamesByID(tasksByID: tasksByID, mappings: mappings)
        let dates = Set(remoteByDate.keys).union(localByDate.keys).union(pendingByDate.keys).sorted()
        var out: [String: [DailyLogItem]] = [:]
        for date in dates {
            let items = Self.mergeDailyItems(
                date: date,
                remote: remoteByDate[date] ?? [],
                local: localByDate[date] ?? [],
                pendingDrafts: pendingByDate[date] ?? [],
                tasksByID: tasksByID,
                projectNamesByID: projectNames,
                mappings: mappings
            )
            if !items.isEmpty {
                out[date] = items
            }
        }
        return out
    }

    private func zentaoClient() throws -> ZentaoClient {
        let key = [settings[LogKeys.baseURL], settings[LogKeys.account], settings[LogKeys.password]].joined(separator: "\u{1f}")
        if let client, key == clientKey { return client }
        let c = try ZentaoClient(
            baseURL: settings[LogKeys.baseURL],
            account: settings[LogKeys.account],
            password: settings[LogKeys.password]
        )
        client = c
        clientKey = key
        return c
    }

    nonisolated static func projectNamesByID(tasksByID: [Int: ZentaoTask], mappings: [String: RepoMapping]) -> [Int: String] {
        var names: [Int: String] = [:]
        for mapping in mappings.values {
            if let pid = mapping.projectID, !mapping.projectName.isEmpty {
                names[pid] = mapping.projectName
            }
        }
        for task in tasksByID.values where !task.projectName.isEmpty {
            names[task.projectID] = task.projectName
        }
        return names
    }

    private nonisolated static func normalizeWork(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 合并单日远端工时、本地已提交与未提交草稿，与 `DraftGenerator.mergeRecorded` 保持一致的去重语义并补齐项目/任务信息。
    nonisolated static func mergeDailyItems(
        date: String,
        remote: [ZentaoEstimate],
        local: [Submission],
        pendingDrafts: [DraftEntry],
        tasksByID: [Int: ZentaoTask],
        projectNamesByID: [Int: String],
        mappings: [String: RepoMapping]
    ) -> [DailyLogItem] {
        struct RecordedSeed {
            var taskID: Int?
            var taskTitle: String?
            var projectID: Int?
            var projectName: String?
            var hours: Double
            var work: String
            var isOvertime: Bool
        }

        var remoteSeeds: [RecordedSeed] = remote.map { est in
            let tid: Int? = est.taskID > 0 ? est.taskID : nil
            let task = tid.flatMap { tasksByID[$0] }
            let pid = est.projectID ?? task?.projectID
            let pname = pid.flatMap { projectNamesByID[$0] } ?? task?.projectName
            return RecordedSeed(
                taskID: tid,
                taskTitle: est.objectTitle ?? task?.name,
                projectID: pid,
                projectName: pname,
                hours: est.consumed,
                work: est.work.trimmingCharacters(in: .whitespacesAndNewlines),
                isOvertime: false
            )
        }

        var matchedRemoteIndices = Set<Int>()
        var extraSeeds: [RecordedSeed] = []
        for s in local {
            let sWork = normalizeWork(s.work)
            if let idx = remoteSeeds.indices.first(where: { i in
                !matchedRemoteIndices.contains(i)
                    && remoteSeeds[i].taskID == s.taskID
                    && abs(remoteSeeds[i].hours - s.hours) < 0.01
                    && normalizeWork(remoteSeeds[i].work) == sWork
            }) {
                matchedRemoteIndices.insert(idx)
                if s.isOvertime {
                    remoteSeeds[idx].isOvertime = true
                }
            } else {
                let task = tasksByID[s.taskID]
                let pid = task?.projectID
                let pname = pid.flatMap { projectNamesByID[$0] } ?? task?.projectName
                extraSeeds.append(RecordedSeed(
                    taskID: s.taskID,
                    taskTitle: task?.name,
                    projectID: pid,
                    projectName: pname,
                    hours: s.hours,
                    work: s.work.trimmingCharacters(in: .whitespacesAndNewlines),
                    isOvertime: s.isOvertime
                ))
            }
        }

        let recordedSeeds = extraSeeds + remoteSeeds
        var items: [DailyLogItem] = recordedSeeds.enumerated().map { index, seed in
            DailyLogItem(
                id: "\(date)-r-\(index)-\(seed.taskID ?? 0)",
                date: date,
                taskID: seed.taskID,
                taskTitle: seed.taskTitle,
                projectID: seed.projectID,
                projectName: seed.projectName,
                hours: seed.hours,
                work: seed.work,
                isOvertime: seed.isOvertime,
                isDraft: false
            )
        }

        let drafts = pendingDrafts.filter { !$0.isRecorded }
        for (index, draft) in drafts.enumerated() {
            let task = draft.taskID.flatMap { tasksByID[$0] }
            let mapped = draft.repoPaths.compactMap { mappings[$0] }.first { $0.projectID != nil }
            let pid = task?.projectID ?? mapped?.projectID
            let pname = pid.flatMap { projectNamesByID[$0] }
                ?? task?.projectName
                ?? mapped?.projectName
            items.append(DailyLogItem(
                id: "\(date)-d-\(index)-\(draft.taskID ?? 0)",
                date: date,
                taskID: draft.taskID,
                taskTitle: draft.taskTitle ?? task?.name,
                projectID: pid,
                projectName: pname,
                hours: draft.hours,
                work: draft.work.trimmingCharacters(in: .whitespacesAndNewlines),
                isOvertime: draft.isOvertime,
                isDraft: true
            ))
        }

        return items
    }
}
