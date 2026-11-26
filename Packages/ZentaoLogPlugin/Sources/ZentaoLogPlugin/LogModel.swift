import Foundation
import IronBowlKit
import Observation

public nonisolated enum AutoLogDraftStrategy: String, Codable, Sendable, CaseIterable {
    case regenerate
    case submitExisting
    case skip
}

public nonisolated struct AutoSubmitLogOptions: Sendable {
    public var draftStrategy: AutoLogDraftStrategy
    public var allowFallbackOnAIFailure: Bool
    public var requireMappedTask: Bool

    public init(
        draftStrategy: AutoLogDraftStrategy = .regenerate,
        allowFallbackOnAIFailure: Bool = true,
        requireMappedTask: Bool = false
    ) {
        self.draftStrategy = draftStrategy
        self.allowFallbackOnAIFailure = allowFallbackOnAIFailure
        self.requireMappedTask = requireMappedTask
    }
}

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
    var drafts: [DraftEntry] = [] {
        didSet {
            if !isSwitchingDate {
                syncCurrentPendingFromDrafts()
            }
        }
    }
    var providerKind: AIProviderKind

    // 状态
    var isScanning = false
    var isLoadingTasks = false
    var isLoadingRecorded = false
    var isGenerating = false
    var isSubmitting = false
    var hasSyncedRemoteRecorded = false
    var message: String?
    var errorMessage: String?
    var lastScan: Date?
    /// 今天已经提交过（本地记录或禅道已记录）。
    var todaySubmitted = false
    var todayCommitCount: Int?
    /// 最近 7 天每天的已写日志（key = yyyy-MM-dd）。
    private(set) var recordedByDate: [String: [DraftEntry]] = [:]
    /// 按日期缓存与落盘的未提交草稿（key = yyyy-MM-dd）。
    private(set) var pendingByDate: [String: [DraftEntry]] = [:]
    @ObservationIgnored private var isSwitchingDate = false
    @ObservationIgnored private var extraTasks: [Int: ZentaoTask] = [:]

    @ObservationIgnored private var client: ZentaoClient?
    @ObservationIgnored private var clientKey = ""

    init(context: PluginContext) {
        self.context = context
        store = LogStore(db: context.database)
        providerKind = context.providers.defaultKind
        mappings = store.mappings()
        reloadLocalRecorded()
        reloadLocalPending()
        loadDraftsForCurrentDate()
        refreshTodaySubmitted()
    }

    var dateString: String { WorkCalendar.dayString(date) }
    var isConfigured: Bool { !settings[LogKeys.account].isEmpty && !settings[LogKeys.password].isEmpty }
    var openTasks: [ZentaoTask] { tasks.filter(\.isOpen) }
    /// 仓库 → 禅道项目。缓存在内存里，界面才能观察到变化；写入时同步落库。
    private(set) var mappings: [String: RepoMapping] = [:]
    var recordedDrafts: [DraftEntry] { drafts.filter(\.isRecorded) }
    var pendingDrafts: [DraftEntry] { drafts.filter { !$0.isRecorded } }
    var recordedHours: Double { recordedDrafts.reduce(0) { $0 + $1.hours } }
    var totalHours: Double { drafts.reduce(0) { $0 + $1.hours } }
    var defaultHours: Double { context.workCalendar.defaultWorkHours }

    func baseWorkHours(on day: Date) -> Double {
        context.workCalendar.isWorkday(day) ? defaultHours : 0
    }

    func overtimeHours(on day: Date) -> Double {
        context.workCalendar.overtimeHours(on: day)
    }

    func targetHours(on day: Date) -> Double {
        baseWorkHours(on: day) + overtimeHours(on: day)
    }

    func remainingTargetHours(on day: Date) -> Double {
        max(0, targetHours(on: day) - recordedHours(on: day))
    }

    var baseWorkHours: Double { baseWorkHours(on: date) }

    var plannedOvertimeHours: Double {
        get { overtimeHours(on: date) }
        set { setOvertimeHours(newValue, for: date) }
    }

    var targetHours: Double { targetHours(on: date) }
    var remainingTargetHours: Double { remainingTargetHours(on: date) }

    func setOvertimeHours(_ hours: Double, for day: Date) {
        context.workCalendar.setOvertimeHours(hours, on: day)
    }

    func toggleOvertimeHours(_ hours: Double) {
        if abs(plannedOvertimeHours - hours) < 0.01 {
            plannedOvertimeHours = 0
        } else {
            plannedOvertimeHours = hours
        }
    }

    func task(_ id: Int?) -> ZentaoTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id } ?? extraTasks[id]
    }

    func recordedEntries(on day: Date) -> [DraftEntry] {
        recordedByDate[WorkCalendar.dayString(day)] ?? []
    }

    func recordedHours(on day: Date) -> Double {
        recordedEntries(on: day).reduce(0) { $0 + $1.hours }
    }

    func pendingEntries(on day: Date) -> [DraftEntry] {
        pendingByDate[WorkCalendar.dayString(day)] ?? []
    }

    func pendingHours(on day: Date) -> Double {
        pendingEntries(on: day).reduce(0) { $0 + $1.hours }
    }

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
        let targetDate = date
        guard let acts = await scanActivities(for: targetDate) else { return }
        if Calendar.current.isDate(date, inSameDayAs: targetDate) {
            activities = acts
            lastScan = Date()
        }
        if Calendar.current.isDateInToday(targetDate) {
            todayCommitCount = acts.reduce(0) { $0 + $1.commits.count }
        }
    }

    private func scanActivities(for day: Date) async -> [RepoActivity]? {
        let email = await authorEmail()
        guard !email.isEmpty else {
            errorMessage = "没有提交作者邮箱，请在设置里填写"
            return nil
        }
        let excluded = Set(mappings.values.filter(\.excluded).map(\.repoPath))
        let repos = repos().filter { !excluded.contains($0) }
        return await GitScanner.activity(repos: repos, authorEmail: email, day: day)
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
            try await fetchTasksThrowing()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchTasksThrowing() async throws {
        tasks = try await zentao().myTasks()
        if settings[LogKeys.fallbackTaskID] == nil,
           let misc = openTasks.first(where: { $0.name.contains("杂项") }) {
            settings[LogKeys.fallbackTaskID] = misc.id
        }
    }

    private func candidateEstimateTaskIDs(extraLocal: [Submission] = []) -> [Int] {
        let recent = openTasks.sorted { $0.id > $1.id }.prefix(30).map(\.id)
        let consumed = (tasks + Array(extraTasks.values)).filter { $0.consumed > 0 }.prefix(40).map(\.id)
        return Array(
            Set(recent)
                .union(consumed)
                .union(store.lastTasks().values)
                .union(settings[LogKeys.fallbackTaskID].map { [$0] } ?? [])
                .union(extraLocal.map(\.taskID))
        )
    }

    func refresh() async {
        errorMessage = nil
        async let a: Void = scan()
        async let b: Void = loadTasksAndRecorded()
        _ = await (a, b)
    }

    private func loadTasksAndRecorded() async {
        await loadTasks()
        await loadRecentRecorded()
    }

    func select(date newDate: Date) async {
        let normalized = Calendar.current.startOfDay(for: newDate)
        let sameDay = Calendar.current.isDate(normalized, inSameDayAs: date)
        syncCurrentPendingFromDrafts()
        date = normalized
        loadDraftsForCurrentDate()
        if !sameDay {
            message = nil
        }
        if isConfigured && !hasSyncedRemoteRecorded {
            async let s: Void = scan()
            async let r: Void = loadRecentRecorded()
            _ = await (s, r)
        } else if !sameDay || lastScan == nil {
            await scan()
        }
    }

    func reloadLocalRecorded() {
        guard let minDate = recentDays.last.map(WorkCalendar.dayString) else { return }
        let grouped = Dictionary(grouping: store.submissions(since: minDate), by: \.date)
        var map: [String: [DraftEntry]] = [:]
        for (ds, list) in grouped {
            map[ds] = DraftGenerator.mergeRecorded(remote: [], local: list)
        }
        recordedByDate = map
    }

    private func reloadLocalPending() {
        let today = Calendar.current.startOfDay(for: Date())
        guard let minDay = Calendar.current.date(byAdding: .day, value: -30, to: today) else { return }
        pendingByDate = store.pendingDrafts(since: WorkCalendar.dayString(minDay))
    }

    private func setPending(_ entries: [DraftEntry], for dateKey: String) {
        let pending = entries.filter { !$0.isRecorded }
        if pending.isEmpty {
            if pendingByDate.removeValue(forKey: dateKey) != nil {
                store.savePendingDrafts([], for: dateKey)
            }
        } else if pendingByDate[dateKey] != pending {
            pendingByDate[dateKey] = pending
            store.savePendingDrafts(pending, for: dateKey)
        }
    }

    private func syncCurrentPendingFromDrafts() {
        setPending(drafts, for: dateString)
    }

    private func loadDraftsForCurrentDate() {
        isSwitchingDate = true
        defer { isSwitchingDate = false }
        drafts = recordedEntries(on: date) + (pendingByDate[dateString] ?? [])
    }

    /// 一次性同步最近 7 天在禅道和本地的已写日志。
    func loadRecentRecorded() async {
        guard isConfigured, !isLoadingRecorded else { return }
        isLoadingRecorded = true
        defer { isLoadingRecorded = false }

        if tasks.isEmpty { await loadTasks() }
        let finished = (try? await zentao().finishedTasks()) ?? []
        var extra: [Int: ZentaoTask] = [:]
        for t in finished { extra[t.id] = t }
        extraTasks = extra

        let dateStrings = recentDays.map(WorkCalendar.dayString)
        guard let minDate = dateStrings.last else { return }

        let localAll = store.submissions(since: minDate)
        let localByDate = Dictionary(grouping: localAll, by: \.date)

        let recentOpen = openTasks.sorted { $0.id > $1.id }.prefix(30).map(\.id)
        let consumedTasks = (tasks + finished).filter { $0.consumed > 0 }.prefix(40).map(\.id)
        let candidateIDs = Set(recentOpen)
            .union(consumedTasks)
            .union(store.lastTasks().values)
            .union(settings[LogKeys.fallbackTaskID].map { [$0] } ?? [])
            .union(localAll.map(\.taskID))

        do {
            let remoteByDate = try await zentao().myEstimates(since: minDate, taskIDs: Array(candidateIDs))
            var merged: [String: [DraftEntry]] = [:]
            for ds in dateStrings {
                let entries = DraftGenerator.mergeRecorded(remote: remoteByDate[ds] ?? [], local: localByDate[ds] ?? [])
                if !entries.isEmpty { merged[ds] = entries }
            }
            recordedByDate = merged
            hasSyncedRemoteRecorded = true
            syncRecordedIntoDrafts()
            refreshTodaySubmitted()
        } catch {
            if errorMessage == nil { errorMessage = error.localizedDescription }
        }
    }

    private func syncRecordedIntoDrafts() {
        syncCurrentPendingFromDrafts()
        loadDraftsForCurrentDate()
    }

    // MARK: 生成

    func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        message = nil
        let targetDate = date
        let targetDateString = WorkCalendar.dayString(targetDate)
        let targetActivities: [RepoActivity]
        if !activities.isEmpty && lastScan != nil {
            targetActivities = activities
        } else {
            targetActivities = await scanActivities(for: targetDate) ?? []
            if dateString == targetDateString {
                activities = targetActivities
                lastScan = Date()
                if Calendar.current.isDateInToday(targetDate) {
                    todayCommitCount = targetActivities.reduce(0) { $0 + $1.commits.count }
                }
            }
        }
        if isConfigured { await loadTasks() }

        let maps = mappings
        var diffs: [String: String] = [:]
        for act in targetActivities where maps[act.repoPath]?.sendDiff == true {
            for c in act.commits { diffs[c.hash] = await GitScanner.diff(repo: act.repoPath, hash: c.hash) }
        }

        var recorded: [ZentaoEstimate] = []
        if isConfigured {
            // 拉取禅道当天已记工时：最近的 30 个未关闭任务 + 已消耗工时任务 + 上次用过的 + 兜底任务。
            let candidateIDs = candidateEstimateTaskIDs()
            recorded = (try? await zentao().myEstimates(on: targetDateString, taskIDs: candidateIDs)) ?? []
        }

        let info = context.workCalendar.dayInfo(targetDate)
        let localSubmissions = store.submissions(on: targetDateString)
        let plannedOT = overtimeHours(on: targetDate)
        let input = DraftInput(
            date: targetDateString,
            isWorkday: info.isWorkday,
            offDayOvertime: settings[LogKeys.offDayOvertime],
            defaultHours: defaultHours,
            activities: targetActivities,
            mappings: maps,
            openTasks: openTasks,
            lastTasks: store.lastTasks(),
            fallbackTaskID: settings[LogKeys.fallbackTaskID],
            recorded: recorded,
            diffs: diffs,
            promptTemplate: settings[LogKeys.prompt],
            overtimeHours: plannedOT,
            workEnd: context.workCalendar.workEnd(on: targetDate),
            localSubmissions: localSubmissions
        )
        let provider = context.providers.config(providerKind)
        let output = await DraftGenerator.generate(input, provider: provider.executablePath.isEmpty ? nil : provider)
        let mergedRecorded = DraftGenerator.mergeRecorded(remote: recorded, local: localSubmissions)
        let pendingOnly = output.entries.filter { !$0.isRecorded }
        setPending(pendingOnly, for: targetDateString)
        if mergedRecorded.isEmpty {
            recordedByDate.removeValue(forKey: targetDateString)
        } else {
            recordedByDate[targetDateString] = mergedRecorded
        }
        if dateString == targetDateString {
            loadDraftsForCurrentDate()
        }
        refreshTodaySubmitted()
        if let err = output.aiError {
            errorMessage = "AI 生成失败，已改用提交信息拼接：\(err)"
        } else if output.usedAI, let s = output.aiSeconds {
            message = "\(provider.kind.displayName) 生成完成，用时 \(Int(s)) 秒"
        } else if targetActivities.isEmpty {
            message = "这一天没有找到你的提交，可以手动添加工作内容"
        } else if pendingOnly.isEmpty {
            let recordedTotal = mergedRecorded.reduce(0) { $0 + $1.hours }
            let target = targetHours(on: targetDate)
            if !info.isWorkday && plannedOT <= 0 {
                message = "当天是休息日，默认需填 0 小时；如需生成加班日志，请先点击上方「加班」设置时长"
            } else if target > 0 && recordedTotal >= target {
                message = "当天已记录 \(hoursText(recordedTotal)) 小时，已达目标工时；如需继续补记加班，请调高加班时长"
            }
        }
    }

    // MARK: 编辑

    func addManual() {
        drafts.append(DraftEntry(taskID: settings[LogKeys.fallbackTaskID], hours: 1, left: 0, work: "", isManual: true))
        recomputeLefts()
    }

    /// 从左页 Git 提交小票摘录一条到待提交草稿。
    func addDraftFromCommit(activity: RepoActivity, commit: GitCommit) {
        let projectID = mappings[activity.repoPath]?.projectID
        let matchedTaskID = projectID.flatMap { pid in
            openTasks.first(where: { $0.projectID == pid })?.id
        }
        let lastTaskID = store.lastTasks()[activity.repoPath].flatMap { tid in
            openTasks.contains(where: { $0.id == tid }) ? tid : nil
        }
        let taskID = lastTaskID ?? matchedTaskID ?? settings[LogKeys.fallbackTaskID]
        let cleaned = DraftGenerator.cleanSubject(commit.subject)
        let workText = cleaned.isEmpty ? commit.subject : cleaned
        drafts.append(DraftEntry(
            taskID: taskID,
            hours: 1,
            left: 0,
            work: workText,
            repoPaths: [activity.repoPath],
            commitHashes: [commit.hash],
            isFallback: taskID == settings[LogKeys.fallbackTaskID],
            isManual: true
        ))
        recomputeLefts()
    }

    func addOvertime(hours: Double, taskID: Int?, work: String) {
        drafts.append(DraftEntry(taskID: taskID, hours: hours, left: 0, work: work.isEmpty ? "加班处理工作" : work,
                                 isFallback: taskID == settings[LogKeys.fallbackTaskID], isOvertime: true, isManual: true))
        recomputeLefts()
    }

    func removeDraft(id: UUID) {
        drafts.removeAll { $0.id == id }
        recomputeLefts()
    }

    func recomputeLefts() {
        DraftGenerator.recomputeLefts(&drafts, tasks: tasks, fallbackTaskID: settings[LogKeys.fallbackTaskID])
    }

    func recomputeLeft(for index: Int) {
        guard drafts.indices.contains(index) else { return }
        recomputeLefts()
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
        let targetDateString = dateString
        let result = await submitEntries(pendingDrafts, for: targetDateString)
        if result.failures.isEmpty {
            message = "已提交 \(result.succeeded.count) 条日志到禅道"
        } else {
            errorMessage = (["成功 \(result.succeeded.count) 条，以下失败："] + result.failures).joined(separator: "\n")
        }
        await loadTasks()
    }

    private func submitEntries(_ toSubmit: [DraftEntry], for targetDateString: String) async -> (succeeded: [DraftEntry], failures: [String]) {
        var failures: [String] = []
        var submittedIDs = Set<UUID>()
        var newlyRecorded: [DraftEntry] = []
        for var d in toSubmit {
            guard let taskID = d.taskID, d.hours > 0, !d.work.trimmingCharacters(in: .whitespaces).isEmpty else {
                failures.append("有一条没选任务、工时为 0 或内容为空，已跳过")
                continue
            }
            do {
                try await zentao().recordEstimate(taskID: taskID, date: targetDateString, consumed: d.hours, left: d.left, work: d.work)
                store.add(Submission(id: nil, date: targetDateString, taskID: taskID, hours: d.hours, left: d.left,
                                     work: d.work, isOvertime: d.isOvertime, submittedAt: Date()))
                store.setLastTask(taskID, for: d.repoPaths)
                d.isRecorded = true
                submittedIDs.insert(d.id)
                newlyRecorded.append(d)
            } catch {
                failures.append("#\(taskID)：\(error.localizedDescription)")
            }
        }
        if !submittedIDs.isEmpty {
            let remainingPending = (pendingByDate[targetDateString] ?? []).filter { !submittedIDs.contains($0.id) }
            setPending(remainingPending, for: targetDateString)
            recordedByDate[targetDateString, default: []].append(contentsOf: newlyRecorded)
            if dateString == targetDateString {
                loadDraftsForCurrentDate()
            }
        }
        refreshTodaySubmitted()
        return (newlyRecorded, failures)
    }

    /// 供定时任务调用：检查今日是否已提交，未提交则扫描、生成并自动提交到禅道（不影响用户正在浏览的日期）。
    func autoGenerateAndSubmitToday(options: AutoSubmitLogOptions = AutoSubmitLogOptions(), now: Date = Date()) async -> ScheduledTaskOutcome {
        guard isConfigured else {
            return .failed(
                summary: "未配置禅道账号，无法自动提交",
                detail: "请先在「设置 → 禅道日志 → 禅道账号」填写禅道地址、账号和密码。",
                actionTitle: "去填写账号",
                actionSettingsPageID: ZentaoLogPlugin.settingsAccountID
            )
        }
        guard !isGenerating && !isSubmitting else {
            return .skipped(
                summary: "当前正在生成或提交日志，跳过本次自动执行",
                detail: "请等待当前手动生成或提交操作完成后再试。"
            )
        }

        let targetDate = Calendar.current.startOfDay(for: now)
        let todayString = WorkCalendar.dayString(targetDate)
        let localSubmissions = store.submissions(on: todayString)

        let remoteRecorded: [ZentaoEstimate]
        do {
            try await fetchTasksThrowing()
            let candidateIDs = candidateEstimateTaskIDs(extraLocal: localSubmissions)
            remoteRecorded = try await zentao().myEstimates(on: todayString, taskIDs: candidateIDs)
        } catch {
            return .failed(
                summary: "同步禅道今日工时失败，为避免重复提交已中止",
                detail: error.localizedDescription,
                actionTitle: "查看日志",
                actionPluginID: ZentaoLogPlugin.pluginID
            )
        }

        let mergedRecorded = DraftGenerator.mergeRecorded(remote: remoteRecorded, local: localSubmissions)
        if mergedRecorded.isEmpty {
            recordedByDate.removeValue(forKey: todayString)
        } else {
            recordedByDate[todayString] = mergedRecorded
        }
        if dateString == todayString {
            loadDraftsForCurrentDate()
        }
        refreshTodaySubmitted()

        if !mergedRecorded.isEmpty {
            let totalRecorded = mergedRecorded.reduce(0) { $0 + $1.hours }
            let lines = mergedRecorded.map { entry in
                let title = entry.taskTitle ?? task(entry.taskID).map { "#\($0.id) \($0.name)" } ?? (entry.taskID.map { "#\($0)" } ?? "未关联任务")
                return "- \(title)（\(hoursText(entry.hours))h）：\(entry.work.replacingOccurrences(of: "\n", with: " "))"
            }.joined(separator: "\n")
            return .skipped(
                summary: "今日已提交日志（共 \(hoursText(totalRecorded))h），跳过自动提交",
                detail: "检测到今日已有 \(mergedRecorded.count) 条已提交工时记录：\n\(lines)"
            )
        }

        let existingPending = pendingEntries(on: targetDate)
        var entriesToSubmit: [DraftEntry] = []
        var generationNotes: [String] = []

        if !existingPending.isEmpty && options.draftStrategy == .skip {
            return .skipped(
                summary: "今日已有 \(existingPending.count) 条未提交草稿，按策略跳过",
                detail: "任务设置为「已有草稿时保留并跳过」，请前往禅道日志页手动确认提交。",
                actionTitle: "查看草稿",
                actionPluginID: ZentaoLogPlugin.pluginID
            )
        } else if !existingPending.isEmpty && options.draftStrategy == .submitExisting {
            entriesToSubmit = existingPending
            DraftGenerator.recomputeLefts(&entriesToSubmit, tasks: tasks, fallbackTaskID: settings[LogKeys.fallbackTaskID])
            generationNotes.append("使用今日已有未提交草稿（\(entriesToSubmit.count) 条）")
        } else {
            let email = await authorEmail()
            guard !email.isEmpty else {
                return .failed(
                    summary: "未配置 Git 作者邮箱，无法扫描提交",
                    detail: "请在「设置 → 禅道日志 → 仓库与映射」填写提交作者邮箱或配置全局 git user.email。",
                    actionTitle: "去设置",
                    actionSettingsPageID: ZentaoLogPlugin.settingsReposID
                )
            }

            isGenerating = true
            let excluded = Set(mappings.values.filter(\.excluded).map(\.repoPath))
            let targetActivities = await GitScanner.activity(
                repos: repos().filter { !excluded.contains($0) },
                authorEmail: email,
                day: targetDate
            )
            if Calendar.current.isDateInToday(targetDate) {
                todayCommitCount = targetActivities.reduce(0) { $0 + $1.commits.count }
            }
            if dateString == todayString {
                activities = targetActivities
                lastScan = Date()
            }

            if targetActivities.isEmpty {
                isGenerating = false
                return .skipped(
                    summary: "今天未检测到 Git 提交，未自动提交日志",
                    detail: "扫描根目录 \(settings[LogKeys.gitRoot]) 下没有发现 \(email) 今天的提交记录。如需记录非代码工作，请前往禅道日志页手动添加。",
                    shouldNotifyOverride: true,
                    actionTitle: "去手动补写",
                    actionPluginID: ZentaoLogPlugin.pluginID
                )
            }

            let info = context.workCalendar.dayInfo(targetDate)
            let plannedOT = overtimeHours(on: targetDate)
            if !info.isWorkday && plannedOT <= 0 {
                isGenerating = false
                return .skipped(
                    summary: "今天是休息日且未设置加班时长，无需提交日志",
                    detail: "若今天实际需要记录加班工时，请在禅道日志页设置加班时长后再生成提交。",
                    actionTitle: "去设置加班",
                    actionPluginID: ZentaoLogPlugin.pluginID
                )
            }

            let maps = mappings
            var diffs: [String: String] = [:]
            for act in targetActivities where maps[act.repoPath]?.sendDiff == true {
                for c in act.commits { diffs[c.hash] = await GitScanner.diff(repo: act.repoPath, hash: c.hash) }
            }

            let input = DraftInput(
                date: todayString,
                isWorkday: info.isWorkday,
                offDayOvertime: settings[LogKeys.offDayOvertime],
                defaultHours: defaultHours,
                activities: targetActivities,
                mappings: maps,
                openTasks: openTasks,
                lastTasks: store.lastTasks(),
                fallbackTaskID: settings[LogKeys.fallbackTaskID],
                recorded: remoteRecorded,
                diffs: diffs,
                promptTemplate: settings[LogKeys.prompt],
                overtimeHours: plannedOT,
                workEnd: context.workCalendar.workEnd(on: targetDate),
                localSubmissions: localSubmissions
            )
            let provider = context.providers.config(providerKind)
            let output = await DraftGenerator.generate(input, provider: provider.executablePath.isEmpty ? nil : provider)
            let pendingOnly = output.entries.filter { !$0.isRecorded }
            setPending(pendingOnly, for: todayString)
            if dateString == todayString {
                loadDraftsForCurrentDate()
            }
            isGenerating = false

            if let aiErr = output.aiError {
                if !options.allowFallbackOnAIFailure {
                    return .failed(
                        summary: "AI 生成失败，已保存回退草稿等待手动确认",
                        detail: "AI 错误：\(aiErr)\n已根据提交信息生成草稿并保存，请前往禅道日志页确认后提交。",
                        actionTitle: "查看草稿",
                        actionPluginID: ZentaoLogPlugin.pluginID
                    )
                }
                generationNotes.append("AI 生成失败（\(aiErr)），已按策略使用提交信息拼接结果提交")
            } else if output.usedAI, let sec = output.aiSeconds {
                generationNotes.append("\(provider.kind.displayName) 生成（用时 \(Int(sec)) 秒）")
            } else {
                generationNotes.append("使用提交信息规则生成")
            }

            entriesToSubmit = pendingOnly
        }

        guard !entriesToSubmit.isEmpty else {
            return .skipped(
                summary: "未生成可提交的日志条目",
                detail: "请前往禅道日志页检查今日目标工时、提交记录或任务配置。",
                shouldNotifyOverride: true,
                actionTitle: "查看日志",
                actionPluginID: ZentaoLogPlugin.pluginID
            )
        }

        if options.requireMappedTask && entriesToSubmit.contains(where: \.isFallback) {
            return .failed(
                summary: "存在命中兜底任务的草稿，已暂停自动提交",
                detail: "当前任务启用了「未映射项目命中兜底任务时暂停自动提交」，请前往禅道日志页确认草稿或补充仓库项目映射。",
                actionTitle: "去确认",
                actionPluginID: ZentaoLogPlugin.pluginID
            )
        }

        if entriesToSubmit.contains(where: { $0.taskID == nil || $0.hours <= 0 || $0.work.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .failed(
                summary: "草稿缺少目标禅道任务或工时无效，已保存草稿",
                detail: "请先在「禅道账号」配置兜底任务，或在「仓库与映射」关联禅道项目后重试。",
                actionTitle: "去配置",
                actionSettingsPageID: ZentaoLogPlugin.settingsAccountID
            )
        }

        isSubmitting = true
        let result = await submitEntries(entriesToSubmit, for: todayString)
        isSubmitting = false
        await loadTasks()

        let totalHours = result.succeeded.reduce(0) { $0 + $1.hours }
        let successLines = result.succeeded.map { d in
            let name = task(d.taskID).map { "#\($0.id) \($0.name)" } ?? (d.taskID.map { "#\($0)" } ?? "未选任务")
            return "- \(name) · \(hoursText(d.hours))h（剩余 \(hoursText(d.left))h）\n  \(d.work.replacingOccurrences(of: "\n", with: " "))"
        }
        var detailSections = generationNotes
        if !successLines.isEmpty {
            detailSections.append("成功提交（\(result.succeeded.count) 条，共 \(hoursText(totalHours))h）：\n" + successLines.joined(separator: "\n"))
        }
        if !result.failures.isEmpty {
            detailSections.append("提交失败（\(result.failures.count) 条）：\n" + result.failures.joined(separator: "\n"))
        }

        if result.failures.isEmpty {
            return .succeeded(
                summary: "已自动提交 \(result.succeeded.count) 条今日日志（共 \(hoursText(totalHours))h）",
                detail: detailSections.joined(separator: "\n\n"),
                actionTitle: "查看日志",
                actionPluginID: ZentaoLogPlugin.pluginID
            )
        } else {
            return .failed(
                summary: "自动提交失败（成功 \(result.succeeded.count) 条，失败 \(result.failures.count) 条）",
                detail: detailSections.joined(separator: "\n\n"),
                actionTitle: "去处理",
                actionPluginID: ZentaoLogPlugin.pluginID
            )
        }
    }

    func refreshTodaySubmitted() {
        let today = WorkCalendar.dayString(Date())
        todaySubmitted = !(recordedByDate[today]?.isEmpty ?? true) || !store.submissions(on: today).isEmpty
    }

    // MARK: 首页一句话记日志

    /// 用 AI 把一句话解析成今天的一条手动日志，加进今天的草稿。返回给用户看的结果。
    func addFromSentence(_ text: String) async -> String {
        guard isConfigured else { return "❌ 先在设置里填写禅道账号" }
        if tasks.isEmpty { await loadTasks() }
        guard !openTasks.isEmpty else { return "❌ 没拉到禅道任务，先在设置里测试连接" }
        let provider = context.providers.config(context.providers.defaultKind)
        var prompt = """
        把我的一句话解析成一条禅道工时记录。从下面的任务里挑最贴近的 taskId（挑不出来就用兜底任务）；
        hours 是小时数（0.5 的倍数，没说时长就填 1）；work 是中文工作内容，一句话，写业务不写技术细节。

        我说：\(text)

        ## 可选任务

        """
        for t in openTasks { prompt += "- taskId=\(t.id) [\(t.projectName)] \(t.name)\n" }
        if let fb = settings[LogKeys.fallbackTaskID] { prompt += "\n兜底任务：taskId=\(fb)\n" }
        let schema = #"{"type":"object","additionalProperties":false,"required":["taskId","hours","work"],"properties":{"taskId":{"type":"integer"},"hours":{"type":"number"},"work":{"type":"string"}}}"#
        struct R: Decodable { let taskId: Int; let hours: Double; let work: String }
        do {
            let result = try await AIRunner.run(config: provider, prompt: prompt, schema: schema)
            let r = try JSONDecoder().decode(R.self, from: result.json)
            let taskID = openTasks.contains { $0.id == r.taskId } ? r.taskId : settings[LogKeys.fallbackTaskID]
            let hours = max(0.5, (r.hours * 2).rounded() / 2)
            if !Calendar.current.isDateInToday(date) { await select(date: Date()) }
            drafts.append(DraftEntry(taskID: taskID, hours: hours, left: 0, work: r.work,
                                     isFallback: taskID == settings[LogKeys.fallbackTaskID], isManual: true))
            recomputeLefts()
            let name = task(taskID).map { "#\($0.id) \($0.name)" } ?? "未选任务"
            return "已加到今天的草稿：\(name)，\(hoursText(hours)) 小时。去禅道日志页确认后提交。"
        } catch {
            return "❌ \(error.localizedDescription)"
        }
    }

    // MARK: 映射

    func setMapping(repo: String, project: (id: Int, name: String)?) {
        var m = mappings[repo] ?? RepoMapping(repoPath: repo, projectID: nil, projectName: "", excluded: false, sendDiff: false)
        m.projectID = project?.id
        m.projectName = project?.name ?? ""
        store.save(m)
        mappings[repo] = m
    }

    func updateMapping(repo: String, _ change: (inout RepoMapping) -> Void) {
        var m = mappings[repo] ?? RepoMapping(repoPath: repo, projectID: nil, projectName: "", excluded: false, sendDiff: false)
        change(&m)
        store.save(m)
        mappings[repo] = m
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
        let keys = DraftGenerator.repoKeys(for: Array(repos.keys))
        let nameCounts = Dictionary(grouping: repos.keys) { ($0 as NSString).lastPathComponent }.mapValues(\.count)
        var prompt = "把我的本地 git 仓库对应到禅道项目。根据仓库标识和最近的提交信息判断；判断不了的 projectId 填 0。输出 JSON 的 repo 字段请原样返回下面列表里的仓库标识。\n\n## 仓库\n"
        for (repo, subjects) in repos.sorted(by: { $0.key < $1.key }) {
            let key = keys[repo] ?? (repo as NSString).lastPathComponent
            prompt += "- \(key)：\(subjects.prefix(6).joined(separator: "；"))\n"
        }
        prompt += "\n## 禅道项目\n" + projects.map { "- projectId=\($0.id) \($0.name)" }.joined(separator: "\n")
        let schema = #"{"type":"object","additionalProperties":false,"required":["mappings"],"properties":{"mappings":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["repo","projectId"],"properties":{"repo":{"type":"string"},"projectId":{"type":"integer"}}}}}}"#
        struct R: Decodable { struct M: Decodable { let repo: String; let projectId: Int }; let mappings: [M] }
        do {
            let result = try await AIRunner.run(config: provider, prompt: prompt, schema: schema)
            let r = try JSONDecoder().decode(R.self, from: result.json)
            var out: [String: Int] = [:]
            for m in r.mappings where m.projectId != 0 {
                if let repo = repos.keys.first(where: {
                    keys[$0] == m.repo
                        || $0 == m.repo
                        || (nameCounts[($0 as NSString).lastPathComponent] == 1 && ($0 as NSString).lastPathComponent == m.repo)
                }) {
                    out[repo] = m.projectId
                }
            }
            return out
        } catch {
            errorMessage = error.localizedDescription
            return [:]
        }
    }
}
