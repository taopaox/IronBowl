import Foundation
import IronBowlKit
import Observation

/// 禅道新指派 Bug / 任务增量判定纯函数（首次建立基线不弹窗，后续仅提醒新增指派或重激活项）。
public nonisolated enum ZentaoAssignedDiff {
    public struct Result: Equatable, Sendable {
        public let newBugs: [ZentaoBug]
        public let newTasks: [ZentaoTask]
        public let nextKnownBugIDs: [Int]
        public let nextKnownTaskIDs: [Int]
        public let isInitialBaseline: Bool

        public var hasNewItems: Bool {
            !newBugs.isEmpty || !newTasks.isEmpty
        }
    }

    public static func evaluate(
        openBugs: [ZentaoBug],
        openTasks: [ZentaoTask],
        knownBugIDs: [Int]?,
        knownTaskIDs: [Int]?,
        bugsOnly: Bool
    ) -> Result {
        let activeBugs = openBugs.filter(\.isOpen)
        let activeTasks = openTasks.filter(\.isOpen)
        let currentBugIDs = Array(Set(activeBugs.map(\.id))).sorted()
        let currentTaskIDs = Array(Set(activeTasks.map(\.id))).sorted()

        let newBugs: [ZentaoBug]
        if let knownBugIDs {
            let knownSet = Set(knownBugIDs)
            newBugs = activeBugs.filter { !knownSet.contains($0.id) }
        } else {
            newBugs = []
        }

        let newTasks: [ZentaoTask]
        if bugsOnly {
            newTasks = []
        } else if let knownTaskIDs {
            let knownSet = Set(knownTaskIDs)
            newTasks = activeTasks.filter { !knownSet.contains($0.id) }
        } else {
            newTasks = []
        }

        let isInitial = (knownBugIDs == nil) && (bugsOnly || knownTaskIDs == nil)
        return Result(
            newBugs: newBugs,
            newTasks: newTasks,
            nextKnownBugIDs: currentBugIDs,
            nextKnownTaskIDs: currentTaskIDs,
            isInitialBaseline: isInitial
        )
    }
}

/// 后台定时巡检禅道指派给我的新 Bug 与新任务，发现增量时通过提醒中心弹窗。
@Observable
final class ZentaoAssignedWatcher {
    let model: LogModel
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var lastIntervalConfig = 0
    @ObservationIgnored private var lastEnabledConfig = false
    @ObservationIgnored private var isChecking = false

    private(set) var lastCheckedAt: Date?
    private(set) var lastCheckSummary: String?

    init(model: LogModel) {
        self.model = model
    }

    var settings: SettingsStore { model.settings }

    func start() {
        reconfigureTimer()
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            guard let self, self.settings[LogKeys.watchAssignedEnabled], self.model.isConfigured else { return }
            _ = await self.checkNow(manual: false)
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        timer?.invalidate()
        timer = nil
    }

    func reconfigureTimer() {
        let enabled = settings[LogKeys.watchAssignedEnabled]
        let minutes = max(5, settings[LogKeys.watchAssignedInterval])
        guard timer == nil || enabled != lastEnabledConfig || minutes != lastIntervalConfig else { return }
        lastEnabledConfig = enabled
        lastIntervalConfig = minutes

        timer?.invalidate()
        timer = nil
        guard enabled else { return }

        let interval = TimeInterval(minutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconfigureTimer()
                guard self.settings[LogKeys.watchAssignedEnabled], self.model.isConfigured else { return }
                Task { _ = await self.checkNow(manual: false) }
            }
        }
        timer?.tolerance = min(30, interval * 0.1)
    }

    @discardableResult
    func checkNow(manual: Bool) async -> String {
        guard model.isConfigured else {
            let msg = "尚未配置禅道账号，无法巡检指派列表。"
            if manual { lastCheckSummary = msg }
            return msg
        }
        guard !isChecking else {
            return "正在检查中…"
        }
        isChecking = true
        defer { isChecking = false }

        do {
            try await model.fetchAssignedSilently()
            let result = ZentaoAssignedDiff.evaluate(
                openBugs: model.openBugs,
                openTasks: model.openTasks,
                knownBugIDs: settings[LogKeys.knownOpenBugIDs],
                knownTaskIDs: settings[LogKeys.knownOpenTaskIDs],
                bugsOnly: settings[LogKeys.watchBugsOnly]
            )
            settings[LogKeys.knownOpenBugIDs] = result.nextKnownBugIDs
            settings[LogKeys.knownOpenTaskIDs] = result.nextKnownTaskIDs
            lastCheckedAt = Date()

            if result.hasNewItems {
                postReminder(bugs: result.newBugs, tasks: result.newTasks)
                let summary = "发现新指派：\(result.newBugs.count) 个 Bug、\(result.newTasks.count) 个任务"
                lastCheckSummary = summary
                return summary
            } else if result.isInitialBaseline {
                let summary = "已建立基线（当前 \(result.nextKnownBugIDs.count) Bug · \(result.nextKnownTaskIDs.count) 任务）"
                lastCheckSummary = summary
                return summary
            } else {
                let summary = "暂无新指派（当前未解决 \(result.nextKnownBugIDs.count) Bug · 进行中 \(result.nextKnownTaskIDs.count) 任务）"
                lastCheckSummary = summary
                return summary
            }
        } catch {
            let msg = "巡检失败：\(error.localizedDescription)"
            if manual { lastCheckSummary = msg }
            return msg
        }
    }

    private func postReminder(bugs: [ZentaoBug], tasks: [ZentaoTask]) {
        var parts: [String] = []
        if !bugs.isEmpty {
            let preview = bugs.prefix(2).map { "#\($0.id) \($0.title)" }.joined(separator: "；")
            let suffix = bugs.count > 2 ? " 等 \(bugs.count) 个 Bug" : ""
            parts.append("新 Bug：\(preview)\(suffix)")
        }
        if !tasks.isEmpty {
            let preview = tasks.prefix(2).map { "#\($0.id) \($0.name)" }.joined(separator: "；")
            let suffix = tasks.count > 2 ? " 等 \(tasks.count) 个任务" : ""
            parts.append("新任务：\(preview)\(suffix)")
        }

        let title = !bugs.isEmpty && tasks.isEmpty
            ? "禅道新指派 \(bugs.count) 个 Bug"
            : (bugs.isEmpty ? "禅道新指派 \(tasks.count) 个任务" : "禅道新指派 \(bugs.count) 个 Bug、\(tasks.count) 个任务")

        let content = ReminderContent(
            id: "zentao.assigned.new",
            title: title,
            message: parts.joined(separator: "\n"),
            systemImage: bugs.isEmpty ? "checklist" : "ladybug.fill",
            source: .zentao,
            targetPluginID: ZentaoLogPlugin.pluginID,
            actions: [
                ReminderAction(id: "ok", title: "知道了") {},
                ReminderAction(id: "todo", title: "一键转待办") { [weak self] in
                    guard let self else { return }
                    for bug in bugs { self.model.addTodoFromBug(bug) }
                    for task in tasks { self.model.addTodoFromTask(task) }
                },
                ReminderAction(id: "view", title: "去查看", isPrimary: true) { [weak self] in
                    guard let self else { return }
                    self.model.showAssignedSheet = true
                    self.model.context.openPlugin(ZentaoLogPlugin.pluginID)
                },
            ]
        )
        model.context.reminders.show(content, style: settings[LogKeys.reminderStyle])
    }
}
