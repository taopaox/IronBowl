import Foundation
import IronBowlKit

/// 草稿里的一条日志（= 某个任务当天的一条工时）。
public nonisolated struct DraftEntry: Sendable, Identifiable, Hashable, Codable {
    public var id = UUID()
    public var taskID: Int?
    public var taskTitle: String? = nil
    public var hours: Double
    public var left: Double
    public var work: String
    public var repoPaths: [String] = []
    public var commitHashes: [String] = []
    /// 记到了兜底（杂项）任务上。
    public var isFallback = false
    public var isOvertime = false
    /// 手动添加（没有提交记录的工作）。
    public var isManual = false
    /// 仅明确标记的、尚未被用户修改的自动草稿允许重建。旧版 JSON 缺少此字段。
    var allowsRegeneration: Bool?
    var manualLeft: Double?
    /// 禅道里已经有的记录，只展示、不再提交。
    public var isRecorded = false
}

nonisolated struct DraftInput: Sendable {
    var date: String
    var isWorkday: Bool
    var offDayOvertime: Bool
    var defaultHours: Double
    var activities: [RepoActivity]
    var mappings: [String: RepoMapping]
    var openTasks: [ZentaoTask]
    var lastTasks: [String: Int]
    var fallbackTaskID: Int?
    var recorded: [ZentaoEstimate]
    var diffs: [String: String]
    var promptTemplate: String
    var overtimeHours: Double = 0
    var workEnd: Date? = nil
    var localSubmissions: [Submission] = []
    var pendingDrafts: [DraftEntry] = []
}

nonisolated struct DraftOutput: Sendable {
    var entries: [DraftEntry]
    var usedAI: Bool
    var aiError: String?
    var aiSeconds: Double?
}

nonisolated enum DraftGenerator {
    static let defaultPrompt = """
    你是我的工作日志助手。下面是我 {{date}} 在各个 git 仓库的提交，以及我在禅道里还没关闭的任务。
    请为每个仓库：
    1. 从「可选任务」里挑一个最贴近这些提交内容的任务，填它的 taskId；实在没有合适的，填兜底任务的 taskId。
       仓库标注了"上次用过"的任务时，内容没有明显变化就沿用它。
    2. 用中文写这个仓库当天的工作内容：1–3 个要点，每点一行，以"1. "开头编号；
       写做了什么业务功能或修了什么问题，不写技术细节、文件名、提交哈希；不要编造提交里没有的内容。
       提交信息只有 add、update 之类没有信息量时，根据改动的文件推断模块和工作。

    {{activity}}

    {{tasks}}

    只输出符合 JSON Schema 的结果。
    """

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["entries"],"properties":{"entries":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["repo","taskId","work"],"properties":{"repo":{"type":"string"},"taskId":{"type":"integer"},"work":{"type":"string"}}}}}}
    """

    private struct AIResult: Decodable {
        struct Entry: Decodable { let repo: String; let taskId: Int; let work: String }
        let entries: [Entry]
    }

    /// 为仓库路径生成唯一标识：仓库名唯一时直接用仓库名，同名子仓库改用「父目录/仓库名」或完整路径。
    static func repoKeys(for paths: [String]) -> [String: String] {
        let uniquePaths = Array(Set(paths))
        let names = Dictionary(grouping: uniquePaths) { ($0 as NSString).lastPathComponent }
        var twoLevelGroups: [String: [String]] = [:]
        for path in uniquePaths {
            let name = (path as NSString).lastPathComponent
            guard (names[name]?.count ?? 0) > 1 else { continue }
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let twoLevel = parent.isEmpty ? name : "\(parent)/\(name)"
            twoLevelGroups[twoLevel, default: []].append(path)
        }
        var result: [String: String] = [:]
        for path in uniquePaths {
            let name = (path as NSString).lastPathComponent
            if (names[name]?.count ?? 0) <= 1 {
                result[path] = name
            } else {
                let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let twoLevel = parent.isEmpty ? name : "\(parent)/\(name)"
                result[path] = (twoLevelGroups[twoLevel]?.count ?? 0) <= 1 ? twoLevel : path
            }
        }
        return result
    }

    /// 按条目的先后顺序累加扣减同一任务的剩余工时，并同步标记是否为兜底任务。
    static func recomputeLefts(_ entries: inout [DraftEntry], tasks: [ZentaoTask], fallbackTaskID: Int?) {
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var remaining: [Int: Double] = [:]
        for i in entries.indices {
            let taskID = entries[i].taskID
            entries[i].isFallback = taskID != nil && taskID == fallbackTaskID
            guard !entries[i].isRecorded, let id = taskID, let task = tasksByID[id] else { continue }
            let currentLeft = remaining[id] ?? task.left
            let nextLeft = entries[i].manualLeft ?? max(0, currentLeft - entries[i].hours)
            entries[i].left = nextLeft
            remaining[id] = nextLeft
        }
    }

    /// 按下班时间把仓库提交拆成「正常工作时段」与「加班时段」两批。
    static func splitActivities(_ activities: [RepoActivity], workEnd: Date?) -> (normal: [RepoActivity], overtime: [RepoActivity]) {
        guard let workEnd else { return (activities, []) }
        var normal: [RepoActivity] = []
        var overtime: [RepoActivity] = []
        for act in activities {
            let normalCommits = act.commits.filter { $0.date <= workEnd }
            let overtimeCommits = act.commits.filter { $0.date > workEnd }
            if !normalCommits.isEmpty {
                normal.append(RepoActivity(repoPath: act.repoPath, commits: normalCommits))
            }
            if !overtimeCommits.isEmpty {
                overtime.append(RepoActivity(repoPath: act.repoPath, commits: overtimeCommits))
            }
        }
        return (normal, overtime)
    }

    private typealias AIPicks = [String: (taskID: Int, work: String)]

    private static func runAI(
        input: DraftInput,
        activities: [RepoActivity],
        provider: AIProviderConfig?,
        sectionTitle: String
    ) async -> (picks: AIPicks, error: String?, seconds: Double?) {
        guard let provider, !activities.isEmpty else { return ([:], nil, nil) }
        let keys = repoKeys(for: activities.map(\.repoPath))
        let nameCounts = Dictionary(grouping: activities, by: \.repoName).mapValues(\.count)
        do {
            let result = try await AIRunner.run(
                config: provider,
                prompt: prompt(input, activities: activities, sectionTitle: sectionTitle),
                schema: schema
            )
            let decoded = try JSONDecoder().decode(AIResult.self, from: result.json)
            var picks: AIPicks = [:]
            for e in decoded.entries {
                // 优先按消歧后的仓库标识匹配，其次完整路径，仅在仓库名唯一时按仓库名匹配。
                if let act = activities.first(where: {
                    keys[$0.repoPath] == e.repo
                        || $0.repoPath == e.repo
                        || (nameCounts[$0.repoName] == 1 && $0.repoName == e.repo)
                }) {
                    picks[act.repoPath] = (e.taskId, e.work.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            return (picks, nil, result.duration)
        } catch {
            return ([:], error.localizedDescription, nil)
        }
    }

    private static func buildEntries(
        activities: [RepoActivity],
        budget: Double,
        isOvertime: Bool,
        aiPicks: AIPicks,
        input: DraftInput,
        tasksByID: [Int: ZentaoTask]
    ) -> [DraftEntry] {
        guard !activities.isEmpty, budget > 0 else { return [] }
        let hours = allocate(total: budget, weights: activities.map(\.weight))

        func isAllowed(_ id: Int, for repoPath: String) -> Bool {
            guard let task = tasksByID[id] else { return false }
            if let mappedProjectID = input.mappings[repoPath]?.projectID {
                return id == input.fallbackTaskID || task.projectID == mappedProjectID
            }
            return id == input.fallbackTaskID
        }

        // 仓库 → 任务
        struct Piece { var repo: RepoActivity; var taskID: Int?; var work: String; var hours: Double }
        var pieces: [Piece] = []
        for (i, act) in activities.enumerated() {
            var taskID: Int?
            if let pick = aiPicks[act.repoPath]?.taskID, isAllowed(pick, for: act.repoPath) {
                taskID = pick
            } else if let last = input.lastTasks[act.repoPath], isAllowed(last, for: act.repoPath) {
                taskID = last
            } else {
                taskID = input.fallbackTaskID
            }
            let work = aiPicks[act.repoPath]?.work.nonEmpty ?? fallbackWork(act)
            pieces.append(Piece(repo: act, taskID: taskID, work: work, hours: hours[i]))
        }

        // 同一时段内的同一任务合并成一条（正常与加班分别生成，不互相合并）。
        var entries: [DraftEntry] = []
        for piece in pieces where piece.hours > 0 {
            if let i = entries.firstIndex(where: { $0.taskID != nil && $0.taskID == piece.taskID }) {
                entries[i].hours += piece.hours
                entries[i].work = mergeWork(entries[i].work, piece.work)
                entries[i].repoPaths.append(piece.repo.repoPath)
                entries[i].commitHashes += piece.repo.commits.map(\.hash)
            } else {
                entries.append(DraftEntry(
                    taskID: piece.taskID, hours: piece.hours, left: 0, work: piece.work,
                    repoPaths: [piece.repo.repoPath], commitHashes: piece.repo.commits.map(\.hash),
                    isFallback: piece.taskID != nil && piece.taskID == input.fallbackTaskID,
                    isOvertime: isOvertime
                ))
            }
        }
        return entries
    }

    private static func overtimeSummary(from anchor: DraftEntry?, tasksByID: [Int: ZentaoTask]) -> String {
        if let raw = anchor?.work {
            let lines = raw.split(separator: "\n")
                .map {
                    $0.replacingOccurrences(of: #"^\s*\d+[.、]\s*"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
            if let first = lines.first {
                return "1. 加班继续推进：\(first)"
            }
        }
        if let taskID = anchor?.taskID, let task = tasksByID[taskID] {
            return "1. 加班处理「\(task.name)」相关工作"
        }
        return "1. 加班处理工作"
    }

    /// 生成草稿：先用 AI；AI 不可用或失败时退回为拼接提交信息。
    static func generate(_ input: DraftInput, provider: AIProviderConfig?) async -> DraftOutput {
        let mergedRecorded = mergeRecorded(remote: input.recorded, local: input.localSubmissions)
        let baseNormalHours = input.isWorkday ? input.defaultHours : 0
        let plannedOvertimeHours = max(0, input.overtimeHours)
        let totalTarget = baseNormalHours + plannedOvertimeHours
        var preserved = input.pendingDrafts.filter { !$0.isRecorded && $0.allowsRegeneration != true }
        recomputeLefts(&preserved, tasks: input.openTasks, fallbackTaskID: input.fallbackTaskID)
        let accounted = mergedRecorded + preserved
        let recordedNormal = accounted.filter { !$0.isOvertime }.reduce(0) { $0 + $1.hours }
        let recordedOvertime = accounted.filter(\.isOvertime).reduce(0) { $0 + $1.hours }
        let totalRecorded = recordedNormal + recordedOvertime
        let totalRemaining = max(0, totalTarget - totalRecorded)
        let normalBudget = min(totalRemaining, max(0, baseNormalHours - recordedNormal))
        let overtimeBudget = max(0, totalRemaining - normalBudget)

        let coveredHashes = Set(preserved.flatMap(\.commitHashes))
        let active = input.activities.compactMap { activity -> RepoActivity? in
            guard input.mappings[activity.repoPath]?.excluded != true else { return nil }
            let commits = activity.commits.filter { !coveredHashes.contains($0.hash) }
            return commits.isEmpty ? nil : RepoActivity(repoPath: activity.repoPath, commits: commits)
        }
        guard !active.isEmpty, normalBudget > 0 || overtimeBudget > 0 else {
            return DraftOutput(entries: accounted, usedAI: false, aiError: nil, aiSeconds: nil)
        }

        let tasksByID = Dictionary(uniqueKeysWithValues: input.openTasks.map { ($0.id, $0) })
        var entries: [DraftEntry] = []
        var usedAI = false
        var aiError: String?
        var aiSeconds: Double?

        if normalBudget > 0 && overtimeBudget == 0 {
            let ai = await runAI(input: input, activities: active, provider: provider, sectionTitle: "我的提交")
            usedAI = !ai.picks.isEmpty
            aiError = ai.error
            aiSeconds = ai.seconds
            entries = buildEntries(
                activities: active,
                budget: normalBudget,
                isOvertime: false,
                aiPicks: ai.picks,
                input: input,
                tasksByID: tasksByID
            )
        } else if normalBudget > 0 && overtimeBudget > 0 {
            let (normalActs, overtimeActs) = splitActivities(active, workEnd: input.workEnd)
            if !normalActs.isEmpty && !overtimeActs.isEmpty {
                async let normalAI = runAI(
                    input: input,
                    activities: normalActs,
                    provider: provider,
                    sectionTitle: "我的提交（正常工作时段）"
                )
                async let overtimeAI = runAI(
                    input: input,
                    activities: overtimeActs,
                    provider: provider,
                    sectionTitle: "我的提交（加班时段）"
                )
                let (nAI, oAI) = await (normalAI, overtimeAI)
                let normalEntries = buildEntries(
                    activities: normalActs,
                    budget: normalBudget,
                    isOvertime: false,
                    aiPicks: nAI.picks,
                    input: input,
                    tasksByID: tasksByID
                )
                let overtimeEntries = buildEntries(
                    activities: overtimeActs,
                    budget: overtimeBudget,
                    isOvertime: true,
                    aiPicks: oAI.picks,
                    input: input,
                    tasksByID: tasksByID
                )
                entries = normalEntries + overtimeEntries
                usedAI = !nAI.picks.isEmpty || !oAI.picks.isEmpty
                var seenErrors = Set<String>()
                let errors = [nAI.error, oAI.error].compactMap { $0 }.filter { seenErrors.insert($0).inserted }
                aiError = errors.isEmpty ? nil : errors.joined(separator: "；")
                aiSeconds = [nAI.seconds, oAI.seconds].compactMap { $0 }.max()
            } else {
                let sourceActs = !normalActs.isEmpty ? normalActs : overtimeActs
                let ai = await runAI(input: input, activities: sourceActs, provider: provider, sectionTitle: "我的提交")
                usedAI = !ai.picks.isEmpty
                aiError = ai.error
                aiSeconds = ai.seconds
                let normalEntries = buildEntries(
                    activities: sourceActs,
                    budget: normalBudget,
                    isOvertime: false,
                    aiPicks: ai.picks,
                    input: input,
                    tasksByID: tasksByID
                )
                let anchor = normalEntries.max(by: { $0.hours < $1.hours })
                let overtimeTaskID = anchor?.taskID ?? input.fallbackTaskID
                let overtimeEntry = DraftEntry(
                    taskID: overtimeTaskID,
                    hours: overtimeBudget,
                    left: 0,
                    work: overtimeSummary(from: anchor, tasksByID: tasksByID),
                    repoPaths: anchor?.repoPaths ?? [],
                    isFallback: overtimeTaskID != nil && overtimeTaskID == input.fallbackTaskID,
                    isOvertime: true
                )
                entries = normalEntries + [overtimeEntry]
            }
        } else {
            let overtimeSource: [RepoActivity]
            if input.isWorkday {
                let split = splitActivities(active, workEnd: input.workEnd)
                overtimeSource = !split.overtime.isEmpty ? split.overtime : active
            } else {
                overtimeSource = active
            }
            let ai = await runAI(
                input: input,
                activities: overtimeSource,
                provider: provider,
                sectionTitle: "我的提交（加班时段）"
            )
            usedAI = !ai.picks.isEmpty
            aiError = ai.error
            aiSeconds = ai.seconds
            entries = buildEntries(
                activities: overtimeSource,
                budget: overtimeBudget,
                isOvertime: true,
                aiPicks: ai.picks,
                input: input,
                tasksByID: tasksByID
            )
        }

        for i in entries.indices { entries[i].allowsRegeneration = true }
        entries = preserved + entries
        recomputeLefts(&entries, tasks: input.openTasks, fallbackTaskID: input.fallbackTaskID)
        return DraftOutput(entries: mergedRecorded + entries, usedAI: usedAI, aiError: aiError, aiSeconds: aiSeconds)
    }

    private static func normalizeWork(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 合并远端禅道工时和本地提交记录，同一条不重复计入并保留本地加班标记。
    static func mergeRecorded(remote: [ZentaoEstimate], local: [Submission]) -> [DraftEntry] {
        var entries = remote.map {
            DraftEntry(
                taskID: $0.taskID > 0 ? $0.taskID : nil,
                taskTitle: $0.objectTitle,
                hours: $0.consumed,
                left: $0.left,
                work: $0.work,
                isRecorded: true
            )
        }
        var matchedRemoteIndices = Set<Int>()
        var extras: [DraftEntry] = []
        for s in local {
            let sWork = normalizeWork(s.work)
            if let idx = entries.indices.first(where: { i in
                !matchedRemoteIndices.contains(i)
                    && entries[i].taskID == s.taskID
                    && abs(entries[i].hours - s.hours) < 0.01
                    && normalizeWork(entries[i].work) == sWork
            }) {
                matchedRemoteIndices.insert(idx)
                if s.isOvertime { entries[idx].isOvertime = true }
            } else {
                extras.append(DraftEntry(
                    taskID: s.taskID, hours: s.hours, left: s.left, work: s.work,
                    isOvertime: s.isOvertime, isRecorded: true
                ))
            }
        }
        return extras + entries
    }

    // MARK: 提示词

    static func prompt(_ input: DraftInput, activities: [RepoActivity], sectionTitle: String = "我的提交") -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let keys = repoKeys(for: activities.map(\.repoPath))
        var activity = "## \(sectionTitle)\n"
        activity += "注意：已关联禅道项目的仓库只能从该项目任务或兜底任务里选；未关联项目的仓库请直接填兜底任务的 taskId。输出 JSON 的 repo 字段请原样填下面「### 仓库 ...」后的仓库标识。\n"
        for act in activities {
            let mapping = input.mappings[act.repoPath]
            let project = mapping?.projectID.map { "\(mapping?.projectName ?? "") #\($0)" } ?? "未关联（请记到兜底任务）"
            let key = keys[act.repoPath] ?? act.repoName
            activity += "\n### 仓库 \(key)（禅道项目：\(project)）"
            if let last = input.lastTasks[act.repoPath] { activity += "（上次用过任务 #\(last)）" }
            activity += "\n"
            for c in act.commits.sorted(by: { $0.date < $1.date }) {
                let files = c.files.prefix(8).map { "\($0.path)(+\($0.added)/-\($0.deleted))" }.joined(separator: ", ")
                let more = c.files.count > 8 ? " 等 \(c.files.count) 个文件" : ""
                activity += "- \(timeFormatter.string(from: c.date)) \(c.subject)  [\(files)\(more)]\n"
                if let diff = input.diffs[c.hash], !diff.isEmpty {
                    activity += "```diff\n\(diff)\n```\n"
                }
            }
        }

        var tasks = "## 可选任务（taskId 只能从这里选）\n"
        for t in input.openTasks.sorted(by: { ($0.projectName, $0.id) < ($1.projectName, $1.id) }) {
            tasks += "- taskId=\(t.id) [\(t.projectName)] \(t.name)（\(t.statusText)，剩余 \(t.left)h）\n"
        }
        if let fb = input.fallbackTaskID {
            let name = input.openTasks.first { $0.id == fb }?.name ?? ""
            tasks += "\n兜底任务：taskId=\(fb) \(name)\n"
        }

        return input.promptTemplate
            .replacingOccurrences(of: "{{date}}", with: input.date)
            .replacingOccurrences(of: "{{activity}}", with: activity)
            .replacingOccurrences(of: "{{tasks}}", with: tasks)
    }

    // MARK: 不用 AI 时

    static func fallbackWork(_ act: RepoActivity) -> String {
        var seen = Set<String>()
        let items = act.commits.map { cleanSubject($0.subject) }
            .filter { $0.count >= 4 && seen.insert($0).inserted }
            .prefix(3)
        if items.isEmpty {
            return "1. 完成 \(act.repoName) 相关开发（\(act.commits.count) 次提交，改动 \(act.lines) 行）"
        }
        return items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// 去掉 `feat(scope): `、emoji 前缀这类约定式格式。
    static func cleanSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^[^\p{Han}\w(]*\w*(\([^)]*\))?!?[:：]\s*"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        let lowered = t.lowercased()
        return ["add", "update", "fix", "wip", "test", "修改", "提交"].contains(lowered) ? "" : t
    }

    static func mergeWork(_ a: String, _ b: String) -> String {
        let lines = (a + "\n" + b).split(separator: "\n").map {
            $0.replacingOccurrences(of: #"^\s*\d+[.、]\s*"#, with: "", options: .regularExpression)
        }
        var seen = Set<String>()
        let unique = lines.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(3)
        return unique.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// 按权重分配总工时，0.5 小时取整，总和不变；每个仓库至少 0.5（总量够的话）。
    static func allocate(total: Double, weights: [Double]) -> [Double] {
        guard !weights.isEmpty else { return [] }
        let units = Int((total * 2).rounded(.down))
        let sum = weights.reduce(0, +)
        guard units > 0, sum > 0 else { return weights.map { _ in 0 } }
        var shares = weights.map { Double(units) * $0 / sum }
        var result = shares.map { Int($0.rounded(.down)) }
        if units >= weights.count {
            for i in result.indices where result[i] == 0 { result[i] = 1; shares[i] = 1 }
        }
        var remaining = units - result.reduce(0, +)
        let order = shares.indices.sorted { (shares[$0] - Double(result[$0])) > (shares[$1] - Double(result[$1])) }
        var k = 0
        while remaining > 0 { result[order[k % order.count]] += 1; remaining -= 1; k += 1 }
        while remaining < 0, let j = result.indices.max(by: { result[$0] < result[$1] }), result[j] > 1 {
            result[j] -= 1; remaining += 1
        }
        return result.map { Double($0) / 2 }
    }
}

extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
