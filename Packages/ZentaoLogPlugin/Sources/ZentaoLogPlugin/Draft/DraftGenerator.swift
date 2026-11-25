import Foundation
import IronBowlKit

/// 草稿里的一条日志（= 某个任务当天的一条工时）。
public nonisolated struct DraftEntry: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var taskID: Int?
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

    /// 生成草稿：先用 AI；AI 不可用或失败时退回为拼接提交信息。
    static func generate(_ input: DraftInput, provider: AIProviderConfig?) async -> DraftOutput {
        var aiPicks: [String: (taskID: Int, work: String)] = [:]
        var aiError: String?
        var aiSeconds: Double?
        let active = input.activities.filter { !(input.mappings[$0.repoPath]?.excluded ?? false) }

        if let provider, !active.isEmpty {
            do {
                let result = try await AIRunner.run(config: provider, prompt: prompt(input, activities: active), schema: schema)
                aiSeconds = result.duration
                let decoded = try JSONDecoder().decode(AIResult.self, from: result.json)
                for e in decoded.entries {
                    // AI 回的是仓库名，对回路径。
                    if let act = active.first(where: { $0.repoName == e.repo || $0.repoPath == e.repo }) {
                        aiPicks[act.repoPath] = (e.taskId, e.work.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } catch {
                aiError = error.localizedDescription
            }
        }

        let openIDs = Set(input.openTasks.map(\.id))
        let recordedHours = input.recorded.reduce(0) { $0 + $1.consumed }
        let budget = max(0, input.defaultHours - recordedHours)
        let hours = allocate(total: budget, weights: active.map(\.weight))

        // 仓库 → 任务
        struct Piece { var repo: RepoActivity; var taskID: Int?; var work: String; var hours: Double }
        var pieces: [Piece] = []
        for (i, act) in active.enumerated() {
            var taskID: Int?
            if let pick = aiPicks[act.repoPath]?.taskID, openIDs.contains(pick) {
                taskID = pick
            } else if let last = input.lastTasks[act.repoPath], openIDs.contains(last) {
                taskID = last
            } else {
                taskID = input.fallbackTaskID
            }
            let work = aiPicks[act.repoPath]?.work.nonEmpty ?? fallbackWork(act)
            pieces.append(Piece(repo: act, taskID: taskID, work: work, hours: hours[i]))
        }

        // 同一任务合并成一条。
        var entries: [DraftEntry] = []
        for piece in pieces {
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
                    isOvertime: !input.isWorkday && input.offDayOvertime
                ))
            }
        }
        for i in entries.indices {
            if let task = input.openTasks.first(where: { $0.id == entries[i].taskID }) {
                entries[i].left = max(0, task.left - entries[i].hours)
            }
        }

        let recorded = input.recorded.map {
            DraftEntry(taskID: $0.taskID, hours: $0.consumed, left: $0.left, work: $0.work, isRecorded: true)
        }
        return DraftOutput(entries: recorded + entries, usedAI: !aiPicks.isEmpty, aiError: aiError, aiSeconds: aiSeconds)
    }

    // MARK: 提示词

    static func prompt(_ input: DraftInput, activities: [RepoActivity]) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        var activity = "## 我的提交\n"
        for act in activities {
            let mapping = input.mappings[act.repoPath]
            let project = mapping?.projectID.map { "\(mapping?.projectName ?? "") #\($0)" } ?? "未关联"
            activity += "\n### 仓库 \(act.repoName)（禅道项目：\(project)）"
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
        let units = Int((total * 2).rounded())
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
