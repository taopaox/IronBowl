import Foundation
import IronBowlKit
import Observation

/// 日志插件的运行状态（界面和菜单栏共用）。
@Observable
final class LogModel {
    let context: PluginContext
    let store: LogStore
    var settings: SettingsStore { context.settings }

    // 当前日期与数据
    var date: Date = Calendar.current.startOfDay(for: Date())
    var activities: [RepoActivity] = []
    var tasks: [ZentaoTask] = []
    var drafts: [DraftEntry] = []
    var providerKind: AIProviderKind

    // 状态
    var isScanning = false
    var isLoadingTasks = false
    var isGenerating = false
    var isSubmitting = false
    var message: String?
    var errorMessage: String?
    var lastScan: Date?
    /// 今天已经提交过（本地记录）。
    var todaySubmitted = false
    var todayCommitCount: Int?

    @ObservationIgnored private var client: ZentaoClient?
    @ObservationIgnored private var clientKey = ""

    init(context: PluginContext) {
        self.context = context
        store = LogStore(db: context.database)
        providerKind = context.providers.defaultKind
        refreshTodaySubmitted()
    }

    var dateString: String { WorkCalendar.dayString(date) }
    var isConfigured: Bool { !settings[LogKeys.account].isEmpty && !settings[LogKeys.password].isEmpty }
    var openTasks: [ZentaoTask] { tasks.filter(\.isOpen) }
    var mappings: [String: RepoMapping] { store.mappings() }
    var pendingDrafts: [DraftEntry] { drafts.filter { !$0.isRecorded } }
    var totalHours: Double { drafts.reduce(0) { $0 + $1.hours } }
    var defaultHours: Double { context.workCalendar.defaultWorkHours }

    func task(_ id: Int?) -> ZentaoTask? { tasks.first { $0.id == id } }

    /// 最近 7 天（含今天）。
    var recentDays: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }

    // MARK: 客户端

    func zentao() throws -> ZentaoClient {
        let key = [settings[LogKeys.baseURL], settings[LogKeys.account], settings[LogKeys.password]].joined(separator: "\u{1f}")
        if let client, key == clientKey { return client }
        let c = try ZentaoClient(baseURL: settings[LogKeys.baseURL], account: settings[LogKeys.account], password: settings[LogKeys.password])
        client = c
        clientKey = key
        return c
    }

    // MARK: 扫描与任务

    func authorEmail() async -> String {
        let saved = settings[LogKeys.authorEmail]
        if !saved.isEmpty { return saved }
        if let email = await GitScanner.globalEmail() {
            settings[LogKeys.authorEmail] = email
            return email
        }
        return ""
    }

    func repos() -> [String] {
        GitScanner.discoverRepos(root: settings[LogKeys.gitRoot], depth: settings[LogKeys.gitDepth])
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let email = await authorEmail()
        guard !email.isEmpty else {
            errorMessage = "没有提交作者邮箱，请在设置里填写"
            return
        }
        let excluded = Set(mappings.values.filter(\.excluded).map(\.repoPath))
        let repos = repos().filter { !excluded.contains($0) }
        activities = await GitScanner.activity(repos: repos, authorEmail: email, day: date)
        lastScan = Date()
        if Calendar.current.isDateInToday(date) {
            todayCommitCount = activities.reduce(0) { $0 + $1.commits.count }
        }
    }

    /// 只为菜单栏统计今天的提交数。
    func scanTodayCount() async {
        let email = await authorEmail()
        guard !email.isEmpty else { return }
        let excluded = Set(mappings.values.filter(\.excluded).map(\.repoPath))
        let acts = await GitScanner.activity(repos: repos().filter { !excluded.contains($0) }, authorEmail: email, day: Date())
        todayCommitCount = acts.reduce(0) { $0 + $1.commits.count }
    }

    func loadTasks() async {
        guard isConfigured, !isLoadingTasks else { return }
        isLoadingTasks = true
        defer { isLoadingTasks = false }
        do {
            tasks = try await zentao().myTasks()
            if settings[LogKeys.fallbackTaskID] == nil,
               let misc = openTasks.first(where: { $0.name.contains("杂项") }) {
                settings[LogKeys.fallbackTaskID] = misc.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        errorMessage = nil
        async let a: Void = scan()
        async let b: Void = loadTasks()
        _ = await (a, b)
    }

    func select(date newDate: Date) async {
        date = Calendar.current.startOfDay(for: newDate)
        drafts = []
        message = nil
        await scan()
    }

    // MARK: 生成

    func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        message = nil
        if activities.isEmpty || lastScan == nil { await scan() }
        if tasks.isEmpty { await loadTasks() }

        let maps = mappings
        var diffs: [String: String] = [:]
        for act in activities where maps[act.repoPath]?.sendDiff == true {
            for c in act.commits { diffs[c.hash] = await GitScanner.diff(repo: act.repoPath, hash: c.hash) }
        }

        var recorded: [ZentaoEstimate] = []
        if isConfigured {
            // 拉取禅道当天已记工时：最近的 30 个未关闭任务 + 上次用过的 + 兜底任务。
            let recent = openTasks.sorted { $0.id > $1.id }.prefix(30).map(\.id)
            let candidateIDs = Set(recent).union(store.lastTasks().values)
                .union(settings[LogKeys.fallbackTaskID].map { [$0] } ?? [])
            recorded = (try? await zentao().myEstimates(on: dateString, taskIDs: Array(candidateIDs))) ?? []
        }

        let info = context.workCalendar.dayInfo(date)
        let input = DraftInput(
            date: dateString,
            isWorkday: info.isWorkday,
            offDayOvertime: settings[LogKeys.offDayOvertime],
            defaultHours: defaultHours,
            activities: activities,
            mappings: maps,
            openTasks: openTasks,
            lastTasks: store.lastTasks(),
            fallbackTaskID: settings[LogKeys.fallbackTaskID],
            recorded: recorded,
            diffs: diffs,
            promptTemplate: settings[LogKeys.prompt]
        )
        let provider = context.providers.config(providerKind)
        let output = await DraftGenerator.generate(input, provider: provider.executablePath.isEmpty ? nil : provider)
        drafts = output.entries
        // 本地已提交过的，标成已记录（防止禅道接口没回查到时重复提交）。
        markLocallySubmitted()
        if let err = output.aiError {
            errorMessage = "AI 生成失败，已改用提交信息拼接：\(err)"
        } else if output.usedAI, let s = output.aiSeconds {
            message = "\(provider.kind.displayName) 生成完成，用时 \(Int(s)) 秒"
        } else if activities.isEmpty {
            message = "这一天没有找到你的提交，可以手动添加工作内容"
        }
    }

    private func markLocallySubmitted() {
        let subs = store.submissions(on: dateString)
        guard !subs.isEmpty else { return }
        let existing = Set(drafts.filter(\.isRecorded).map { "\($0.taskID ?? 0)|\($0.work)" })
        for s in subs where !existing.contains("\(s.taskID)|\(s.work)") {
            drafts.insert(DraftEntry(taskID: s.taskID, hours: s.hours, left: s.left, work: s.work,
                                     isOvertime: s.isOvertime, isRecorded: true), at: 0)
        }
    }

    // MARK: 编辑

    func addManual() {
        drafts.append(DraftEntry(taskID: settings[LogKeys.fallbackTaskID], hours: 1, left: 0, work: "", isManual: true))
        recomputeLeft(for: drafts.count - 1)
    }

    func addOvertime(hours: Double, taskID: Int?, work: String) {
        drafts.append(DraftEntry(taskID: taskID, hours: hours, left: 0, work: work.isEmpty ? "加班处理工作" : work,
                                 isFallback: taskID == settings[LogKeys.fallbackTaskID], isOvertime: true, isManual: true))
        recomputeLeft(for: drafts.count - 1)
    }

    func recomputeLeft(for index: Int) {
        guard drafts.indices.contains(index), let task = task(drafts[index].taskID) else { return }
        drafts[index].left = max(0, task.left - drafts[index].hours)
        drafts[index].isFallback = drafts[index].taskID == settings[LogKeys.fallbackTaskID]
    }

    /// 当天剩余可分配工时最多的那条（加班默认记到这里）。
    var busiestTaskID: Int? {
        pendingDrafts.max { $0.hours < $1.hours }?.taskID ?? settings[LogKeys.fallbackTaskID]
    }

    // MARK: 提交

    func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        errorMessage = nil
        var failures: [String] = []
        var count = 0
        for i in drafts.indices where !drafts[i].isRecorded {
            let d = drafts[i]
            guard let taskID = d.taskID, d.hours > 0, !d.work.trimmingCharacters(in: .whitespaces).isEmpty else {
                failures.append("有一条没选任务、工时为 0 或内容为空，已跳过")
                continue
            }
            do {
                try await zentao().recordEstimate(taskID: taskID, date: dateString, consumed: d.hours, left: d.left, work: d.work)
                store.add(Submission(id: nil, date: dateString, taskID: taskID, hours: d.hours, left: d.left,
                                     work: d.work, isOvertime: d.isOvertime, submittedAt: Date()))
                store.setLastTask(taskID, for: d.repoPaths)
                drafts[i].isRecorded = true
                count += 1
            } catch {
                failures.append("#\(taskID)：\(error.localizedDescription)")
            }
        }
        refreshTodaySubmitted()
        if failures.isEmpty {
            message = "已提交 \(count) 条日志到禅道"
        } else {
            errorMessage = (["成功 \(count) 条，以下失败："] + failures).joined(separator: "\n")
        }
        await loadTasks()
    }

    func refreshTodaySubmitted() {
        todaySubmitted = !store.submissions(on: WorkCalendar.dayString(Date())).isEmpty
    }

    // MARK: 映射

    func setMapping(repo: String, project: (id: Int, name: String)?) {
        var m = mappings[repo] ?? RepoMapping(repoPath: repo, projectID: nil, projectName: "", excluded: false, sendDiff: false)
        m.projectID = project?.id
        m.projectName = project?.name ?? ""
        store.save(m)
    }

    func updateMapping(repo: String, _ change: (inout RepoMapping) -> Void) {
        var m = mappings[repo] ?? RepoMapping(repoPath: repo, projectID: nil, projectName: "", excluded: false, sendDiff: false)
        change(&m)
        store.save(m)
    }

    /// 禅道项目列表（从我的任务里汇总）。
    var projects: [(id: Int, name: String)] {
        var seen = Set<Int>()
        return tasks.compactMap { t in seen.insert(t.projectID).inserted ? (t.projectID, t.projectName) : nil }
            .sorted { $0.name < $1.name }
    }

    /// 让 AI 推荐仓库 → 禅道项目。
    func suggestMappings(repos: [String: [String]]) async -> [String: Int] {
        let provider = context.providers.config(providerKind)
        guard !provider.executablePath.isEmpty, !projects.isEmpty else { return [:] }
        var prompt = "把我的本地 git 仓库对应到禅道项目。根据仓库名和最近的提交信息判断；判断不了的 projectId 填 0。\n\n## 仓库\n"
        for (repo, subjects) in repos.sorted(by: { $0.key < $1.key }) {
            prompt += "- \((repo as NSString).lastPathComponent)：\(subjects.prefix(6).joined(separator: "；"))\n"
        }
        prompt += "\n## 禅道项目\n" + projects.map { "- projectId=\($0.id) \($0.name)" }.joined(separator: "\n")
        let schema = #"{"type":"object","additionalProperties":false,"required":["mappings"],"properties":{"mappings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["repo","projectId"],"properties":{"repo":{"type":"string"},"projectId":{"type":"integer"}}}}}}"#
        struct R: Decodable { struct M: Decodable { let repo: String; let projectId: Int }; let mappings: [M] }
        do {
            let result = try await AIRunner.run(config: provider, prompt: prompt, schema: schema)
            let r = try JSONDecoder().decode(R.self, from: result.json)
            var out: [String: Int] = [:]
            for m in r.mappings where m.projectId != 0 {
                if let repo = repos.keys.first(where: { ($0 as NSString).lastPathComponent == m.repo }) { out[repo] = m.projectId }
            }
            return out
        } catch {
            errorMessage = error.localizedDescription
            return [:]
        }
    }
}
