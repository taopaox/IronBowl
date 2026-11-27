import AppKit
import Foundation
import IronBowlKit
import Observation
import UniformTypeIdentifiers
import ZentaoLogPlugin

@Observable
final class WeeklyReportModel {
    let context: PluginContext
    let store: ReportStore
    let dailyLogService: ZentaoDailyLogService
    let lockedPeriodKind: ReportPeriodKind?

    var periodKind: ReportPeriodKind
    var week: WeekRange
    var month: MonthRange
    var days: [DailyReportDay] = []
    var selectedDayFilter: String?
    var selectedWeekFilter: String?
    var providerKind: AIProviderKind

    var extraNotes: String = ""
    var monthlyOKR: String = ""
    var reportTitle: String = ""
    var reportContent: String = ""

    var currentRecord: WeeklyReportRecord?
    var currentMonthlyRecord: MonthlyReportRecord?
    private(set) var recentReports: [WeeklyReportRecord] = []
    private(set) var recentMonthlyReports: [MonthlyReportRecord] = []
    private(set) var monthWeeklySummaries: [WeeklyReportRecord] = []
    private(set) var monthGitStats: GitMonthlyStats = .empty
    var isLoadingGitStats = false

    var isLoadingLogs = false
    var isGenerating = false
    var syncedFromZentao = false
    var remoteError: String?
    var message: String?
    var errorMessage: String?
    var copied = false

    // MARK: - Tita 对接状态
    var titaStatus: TitaPeriodStatus?
    var isLoadingTitaStatus = false
    var titaStatusError: String?
    var isSyncingTita = false
    var isSyncingTitaHistory = false

    @ObservationIgnored private var rawItemsByDate: [String: [DailyLogItem]] = [:]
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?
    @ObservationIgnored private var copiedResetTask: Task<Void, Never>?
    @ObservationIgnored private var cachedTitaClient: (key: TitaClientCacheKey, client: TitaClient)?

    private struct TitaClientCacheKey: Equatable {
        let baseURL: String
        let cookie: String
        let tenantID: String
        let userID: String
    }

    init(context: PluginContext, lockedPeriodKind: ReportPeriodKind? = nil) {
        self.context = context
        self.store = ReportStore(db: context.database)
        self.dailyLogService = ZentaoDailyLogService(database: context.database, settings: context.settings)
        self.lockedPeriodKind = lockedPeriodKind
        self.periodKind = lockedPeriodKind ?? context.settings[ReportKeys.lastPeriodKind]
        self.week = WeekRange.containing(Date())
        self.month = MonthRange.containing(Date())
        self.providerKind = context.providers.defaultKind
        self.recentReports = store.recentReports()
        self.recentMonthlyReports = store.recentMonthlyReports()
        loadSavedReportForActivePeriod()
        loadLocalLogs()
    }

    var settings: SettingsStore { context.settings }

    var style: WeeklyReportStyle {
        get { settings[ReportKeys.style] }
        set { settings[ReportKeys.style] = newValue }
    }

    var includeDrafts: Bool {
        get { settings[ReportKeys.includeDrafts] }
        set {
            guard settings[ReportKeys.includeDrafts] != newValue else { return }
            settings[ReportKeys.includeDrafts] = newValue
            loadLocalLogs()
            if isZentaoConfigured {
                Task { await refreshLogs() }
            }
        }
    }

    var includeHours: Bool {
        get { settings[ReportKeys.includeHours] }
        set { settings[ReportKeys.includeHours] = newValue }
    }

    var includeGitStats: Bool {
        get { settings[ReportKeys.includeGitStats] }
        set {
            guard settings[ReportKeys.includeGitStats] != newValue else { return }
            settings[ReportKeys.includeGitStats] = newValue
            if newValue && periodKind == .monthly {
                Task { await refreshMonthGitStats() }
            }
        }
    }

    var feishuCLIPath: String {
        get { settings[ReportKeys.feishuCLIPath] }
        set { settings[ReportKeys.feishuCLIPath] = newValue }
    }

    var feishuMonthlyDocURL: String {
        get { settings[ReportKeys.feishuMonthlyDocURL] }
        set { settings[ReportKeys.feishuMonthlyDocURL] = newValue }
    }

    var isZentaoConfigured: Bool {
        dailyLogService.isZentaoConfigured
    }

    // MARK: - Tita 配置与当前周期编码

    var titaBaseURL: String {
        settings[ReportKeys.titaBaseURL]
    }

    var titaCookie: String {
        settings[ReportKeys.titaCookie]
    }

    var titaTenantID: String {
        settings[ReportKeys.titaTenantID]
    }

    var titaUserID: String {
        settings[ReportKeys.titaUserID]
    }

    var titaUserName: String {
        settings[ReportKeys.titaUserName]
    }

    var isTitaConfigured: Bool {
        !titaCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeTitaSummaryType: TitaSummaryType {
        TitaSummaryType(periodKind: periodKind)
    }

    var activeTitaSummaryDate: String {
        TitaPeriodCode.summaryDate(for: periodKind, week: week, month: month)
    }

    var activeTitaStatusDate: String {
        TitaPeriodCode.statusDate(for: periodKind, week: week, month: month)
    }

    var activeTitaTemplateID: Int {
        switch periodKind {
        case .weekly:
            let saved = settings[ReportKeys.titaWeeklyTemplateID]
            return saved > 0 ? saved : ReportKeys.titaWeeklyTemplateID.defaultValue
        case .monthly:
            let saved = settings[ReportKeys.titaMonthlyTemplateID]
            return saved > 0 ? saved : ReportKeys.titaMonthlyTemplateID.defaultValue
        }
    }

    // MARK: - 当前周期元信息

    var activePeriodKey: String {
        periodKind == .weekly ? week.startDateString : month.monthKey
    }

    var activeStartDateString: String {
        periodKind == .weekly ? week.startDateString : month.startDateString
    }

    var activeEndDateString: String {
        periodKind == .weekly ? week.endDateString : month.endDateString
    }

    var activePeriodTitle: String {
        periodKind == .weekly ? week.title : month.title
    }

    var activePeriodRangeText: String {
        periodKind == .weekly ? week.rangeText : month.rangeText
    }

    var activePeriodShortRangeText: String {
        periodKind == .weekly ? week.shortRangeText : month.shortRangeText
    }

    var activeRelativeBadge: String? {
        periodKind == .weekly ? week.relativeBadge() : month.relativeBadge()
    }

    var isCurrentPeriod: Bool {
        activeRelativeBadge == (periodKind == .weekly ? "本周" : "本月")
    }

    var activeUpdatedAt: Date? {
        periodKind == .weekly ? currentRecord?.updatedAt : currentMonthlyRecord?.updatedAt
    }

    var activeProviderName: String? {
        periodKind == .weekly ? currentRecord?.providerName : currentMonthlyRecord?.providerName
    }

    var totalHours: Double {
        days.reduce(0) { $0 + $1.totalHours }
    }

    var normalHours: Double {
        days.reduce(0) { $0 + $1.normalHours }
    }

    var overtimeHours: Double {
        days.reduce(0) { $0 + $1.overtimeHours }
    }

    var loggedDaysCount: Int {
        days.filter { !$0.isEmpty }.count
    }

    var workdayCount: Int {
        days.filter(\.isWorkday).count
    }

    func clearFeedback() {
        message = nil
        errorMessage = nil
    }

    var involvedProjects: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for day in days {
            for item in day.items {
                let raw = item.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = raw.isEmpty ? "其他工作" : raw
                if seen.insert(name).inserted {
                    result.append(name)
                }
            }
        }
        return result
    }

    var totalLogCount: Int {
        days.reduce(0) { $0 + $1.items.count }
    }

    var hasActiveFilter: Bool {
        periodKind == .weekly ? (selectedDayFilter != nil) : (selectedWeekFilter != nil)
    }

    func clearActiveFilter() {
        selectedDayFilter = nil
        selectedWeekFilter = nil
    }

    var filteredDays: [DailyReportDay] {
        let nonEmpty = days.filter { !$0.isEmpty }
        switch periodKind {
        case .weekly:
            guard let selectedDayFilter else { return nonEmpty }
            return nonEmpty.filter { $0.dateString == selectedDayFilter }
        case .monthly:
            guard let selectedWeekFilter,
                  let slice = month.weeks.first(where: { $0.id == selectedWeekFilter }) else {
                return nonEmpty
            }
            let set = Set(slice.dayStrings)
            return nonEmpty.filter { set.contains($0.dateString) }
        }
    }

    func monthWeekSliceHours(_ slice: MonthWeekSlice) -> Double {
        let set = Set(slice.dayStrings)
        return days.filter { set.contains($0.dateString) }.reduce(0) { $0 + $1.totalHours }
    }

    func hasWeeklyReport(forSlice slice: MonthWeekSlice) -> Bool {
        monthWeeklySummaries.contains {
            $0.weekStart == slice.id && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasReportContent: Bool {
        !reportContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCurrentWeekReport: Bool {
        let key = WeekRange.containing(Date()).startDateString
        return recentReports.contains { $0.weekStart == key && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var currentWeekSavedHours: Double? {
        let key = WeekRange.containing(Date()).startDateString
        return recentReports.first(where: { $0.weekStart == key })?.totalHours
    }

    var hasCurrentMonthReport: Bool {
        let key = MonthRange.containing(Date()).monthKey
        return recentMonthlyReports.contains { $0.monthKey == key && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var currentMonthSavedHours: Double? {
        let key = MonthRange.containing(Date()).monthKey
        return recentMonthlyReports.first(where: { $0.monthKey == key })?.totalHours
    }

    // MARK: - 周期切换与日报查询

    func switchPeriodKind(_ kind: ReportPeriodKind) async {
        if let lockedPeriodKind, kind != lockedPeriodKind { return }
        guard kind != periodKind else { return }
        saveEditsIfNeeded()
        periodKind = kind
        if lockedPeriodKind == nil {
            settings[ReportKeys.lastPeriodKind] = kind
        }
        clearActiveFilter()
        syncedFromZentao = false
        remoteError = nil
        monthGitStats = .empty
        titaStatus = nil
        titaStatusError = nil
        message = nil
        errorMessage = nil
        loadSavedReportForActivePeriod()
        loadLocalLogs()
        await refreshLogs()
    }

    func selectWeek(_ newWeek: WeekRange) async {
        if periodKind == .weekly && newWeek.startDateString == week.startDateString {
            await refreshLogs()
            return
        }
        saveEditsIfNeeded()
        periodKind = .weekly
        if lockedPeriodKind == nil {
            settings[ReportKeys.lastPeriodKind] = .weekly
        }
        week = newWeek
        clearActiveFilter()
        syncedFromZentao = false
        remoteError = nil
        monthGitStats = .empty
        titaStatus = nil
        titaStatusError = nil
        message = nil
        errorMessage = nil
        loadSavedReportForActivePeriod()
        loadLocalLogs()
        await refreshLogs()
    }

    func selectMonth(_ newMonth: MonthRange) async {
        if periodKind == .monthly && newMonth.monthKey == month.monthKey {
            await refreshLogs()
            return
        }
        saveEditsIfNeeded()
        periodKind = .monthly
        if lockedPeriodKind == nil {
            settings[ReportKeys.lastPeriodKind] = .monthly
        }
        month = newMonth
        clearActiveFilter()
        syncedFromZentao = false
        remoteError = nil
        monthGitStats = .empty
        titaStatus = nil
        titaStatusError = nil
        message = nil
        errorMessage = nil
        loadSavedReportForActivePeriod()
        loadLocalLogs()
        await refreshLogs()
    }

    func previousWeek() async {
        await selectWeek(week.shifted(byWeeks: -1))
    }

    func nextWeek() async {
        await selectWeek(week.shifted(byWeeks: 1))
    }

    func goToCurrentWeek() async {
        await selectWeek(WeekRange.containing(Date()))
    }

    func previousMonth() async {
        await selectMonth(month.shifted(byMonths: -1))
    }

    func nextMonth() async {
        await selectMonth(month.shifted(byMonths: 1))
    }

    func goToCurrentMonth() async {
        await selectMonth(MonthRange.containing(Date()))
    }

    func previousPeriod() async {
        switch periodKind {
        case .weekly: await previousWeek()
        case .monthly: await previousMonth()
        }
    }

    func nextPeriod() async {
        switch periodKind {
        case .weekly: await nextWeek()
        case .monthly: await nextMonth()
        }
    }

    func goToCurrentPeriod() async {
        switch periodKind {
        case .weekly: await goToCurrentWeek()
        case .monthly: await goToCurrentMonth()
        }
    }

    func loadLocalLogs() {
        let localMap = dailyLogService.loadLocal(
            from: activeStartDateString,
            to: activeEndDateString,
            includeDrafts: includeDrafts
        )
        rawItemsByDate = localMap
        rebuildDays(using: localMap, periodKind: periodKind, week: week, month: month)
        if periodKind == .monthly {
            recentMonthlyReports = store.recentMonthlyReports()
            monthWeeklySummaries = store.weeklyReports(matchingWeekStarts: month.weeks.map(\.id))
        } else {
            recentReports = store.recentReports()
            monthWeeklySummaries = []
        }
    }

    func refreshLogs() async {
        guard !isLoadingLogs else { return }
        isLoadingLogs = true
        let targetKind = periodKind
        let targetKey = activePeriodKey
        let targetWeek = week
        let targetMonth = month
        let start = activeStartDateString
        let end = activeEndDateString
        let include = includeDrafts
        let shouldFetchGit = (targetKind == .monthly && includeGitStats)

        if shouldFetchGit {
            isLoadingGitStats = true
        }

        async let logResult = dailyLogService.fetch(
            from: start,
            to: end,
            includeDrafts: include
        )
        async let gitResult: GitMonthlyStats? = shouldFetchGit
            ? fetchMonthGitStats(start: start, end: end)
            : nil

        let (result, fetchedGit) = await (logResult, gitResult)
        isLoadingLogs = false
        if shouldFetchGit {
            isLoadingGitStats = false
        }
        guard periodKind == targetKind && activePeriodKey == targetKey else { return }

        rawItemsByDate = result.itemsByDate
        syncedFromZentao = result.syncedFromZentao
        remoteError = result.remoteError
        if let fetchedGit {
            monthGitStats = fetchedGit
        }
        rebuildDays(using: result.itemsByDate, periodKind: targetKind, week: targetWeek, month: targetMonth)
        if targetKind == .monthly {
            recentMonthlyReports = store.recentMonthlyReports()
            monthWeeklySummaries = store.weeklyReports(matchingWeekStarts: targetMonth.weeks.map(\.id))
        } else {
            recentReports = store.recentReports()
        }
    }

    func refreshMonthGitStats() async {
        guard periodKind == .monthly, !isLoadingGitStats else { return }
        let targetKey = month.monthKey
        let start = month.startDateString
        let end = month.endDateString
        isLoadingGitStats = true
        defer { isLoadingGitStats = false }
        let stats = await fetchMonthGitStats(start: start, end: end)
        guard periodKind == .monthly && month.monthKey == targetKey else { return }
        monthGitStats = stats
    }

    private func fetchMonthGitStats(start: String, end: String) async -> GitMonthlyStats {
        let repos = GitScanner.configuredRepos(database: context.database, settings: settings)
        let email = await GitScanner.configuredAuthorEmail(settings: settings)
        return await GitScanner.monthlyStats(
            repos: repos,
            authorEmail: email,
            startDate: start,
            endDate: end
        )
    }

    private func rebuildDays(
        using map: [String: [DailyLogItem]],
        periodKind: ReportPeriodKind,
        week: WeekRange,
        month: MonthRange
    ) {
        let targetDays = periodKind == .weekly ? week.days : month.days
        days = targetDays.map { day in
            let ds = WorkCalendar.dayString(day)
            let info = context.workCalendar.dayInfo(day)
            return DailyReportDay(
                date: day,
                dateString: ds,
                weekdayText: CN.weekdayShort(day),
                isWorkday: info.isWorkday,
                holidayName: info.name,
                items: map[ds] ?? []
            )
        }
    }

    // MARK: - 生成周报 / 月报

    func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        message = nil

        if isZentaoConfigured && !syncedFromZentao {
            await refreshLogs()
        } else {
            rebuildDays(using: rawItemsByDate, periodKind: periodKind, week: week, month: month)
        }

        let trimmedNotes = extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOKR = periodKind == .monthly ? monthlyOKR.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let hasGit = periodKind == .monthly && includeGitStats && monthGitStats.totalCommits > 0
        let noun = periodKind.displayName
        let periodLabel = periodKind == .weekly ? "本周" : "本月"
        if totalLogCount == 0 && trimmedNotes.isEmpty && trimmedOKR.isEmpty && !hasGit {
            errorMessage = "\(periodLabel)暂未查到每日日报，请先刷新查询禅道记录，或在补充说明中填写工作要点后再生成。"
            return
        }

        if periodKind == .monthly && includeGitStats && !monthGitStats.hasData {
            await refreshMonthGitStats()
        }

        let provider = context.providers.config(providerKind)
        let activeProvider = provider.executablePath.isEmpty ? nil : provider

        let output: WeeklyReportOutput
        switch periodKind {
        case .weekly:
            let input = WeeklyReportInput(
                week: week,
                days: days,
                extraNotes: extraNotes,
                style: style,
                includeHours: includeHours,
                promptTemplate: settings[ReportKeys.prompt]
            )
            output = await WeeklyReportGenerator.generate(input, provider: activeProvider)

            reportTitle = output.title
            reportContent = output.content

            let now = Date()
            let record = WeeklyReportRecord(
                weekStart: week.startDateString,
                weekEnd: week.endDateString,
                title: output.title,
                content: output.content,
                extraNotes: extraNotes,
                style: style.rawValue,
                providerName: output.usedAI ? provider.kind.displayName : "本地规则汇总",
                totalHours: totalHours,
                generatedAt: currentRecord?.generatedAt ?? now,
                updatedAt: now
            )
            store.save(record)
            currentRecord = record
            recentReports = store.recentReports()

        case .monthly:
            monthWeeklySummaries = store.weeklyReports(matchingWeekStarts: month.weeks.map(\.id))
            let input = MonthlyReportInput(
                month: month,
                days: days,
                weeklySummaries: monthWeeklySummaries,
                extraNotes: extraNotes,
                style: style,
                includeHours: includeHours,
                promptTemplate: settings[ReportKeys.monthlyPrompt],
                monthlyOKR: monthlyOKR,
                gitStats: monthGitStats,
                includeGitStats: includeGitStats
            )
            output = await WeeklyReportGenerator.generate(input, provider: activeProvider)

            reportTitle = output.title
            reportContent = output.content

            let now = Date()
            let record = MonthlyReportRecord(
                monthKey: month.monthKey,
                periodStart: month.startDateString,
                periodEnd: month.endDateString,
                title: output.title,
                content: output.content,
                extraNotes: extraNotes,
                style: style.rawValue,
                providerName: output.usedAI ? provider.kind.displayName : "本地规则汇总",
                totalHours: totalHours,
                generatedAt: currentMonthlyRecord?.generatedAt ?? now,
                updatedAt: now,
                monthlyOKR: monthlyOKR
            )
            store.saveMonthly(record)
            currentMonthlyRecord = record
            recentMonthlyReports = store.recentMonthlyReports()
        }

        if let aiError = output.aiError {
            errorMessage = "AI 生成失败，已改为本地汇总：\(aiError)"
        } else if output.usedAI, let sec = output.aiSeconds {
            message = "\(provider.kind.displayName) 生成\(noun)完成，用时 \(Int(sec)) 秒"
        } else if activeProvider == nil {
            message = "未配置 AI 提供者，已按本地日报规则汇总\(noun)"
        } else {
            message = "\(noun)已生成并保存"
        }
    }

    // MARK: - 持久化、复制与导出

    func loadSavedReportForActivePeriod() {
        switch periodKind {
        case .weekly:
            loadSavedReport(for: week)
        case .monthly:
            loadSavedMonthlyReport(for: month)
        }
    }

    func loadSavedReport(for targetWeek: WeekRange) {
        monthlyOKR = ""
        if let saved = store.report(forWeekStart: targetWeek.startDateString) {
            currentRecord = saved
            reportTitle = saved.title
            reportContent = saved.content
            extraNotes = saved.extraNotes
        } else {
            currentRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: targetWeek)
            reportContent = ""
            extraNotes = ""
        }
    }

    func loadSavedMonthlyReport(for targetMonth: MonthRange) {
        if let saved = store.monthlyReport(forMonthKey: targetMonth.monthKey) {
            currentMonthlyRecord = saved
            reportTitle = saved.title
            reportContent = saved.content
            extraNotes = saved.extraNotes
            monthlyOKR = saved.monthlyOKR
        } else {
            currentMonthlyRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: targetMonth)
            reportContent = ""
            extraNotes = ""
            monthlyOKR = ""
        }
    }

    func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.saveEditsIfNeeded()
        }
    }

    func saveEditsIfNeeded() {
        autoSaveTask?.cancel()
        let trimmedContent = reportContent.trimmingCharacters(in: .whitespacesAndNewlines)

        switch periodKind {
        case .weekly:
            guard currentRecord != nil || !trimmedContent.isEmpty else { return }
            let now = Date()
            let resolvedTitle = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? WeeklyReportGenerator.defaultTitle(for: week)
                : reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = WeeklyReportRecord(
                weekStart: week.startDateString,
                weekEnd: week.endDateString,
                title: resolvedTitle,
                content: reportContent,
                extraNotes: extraNotes,
                style: style.rawValue,
                providerName: currentRecord?.providerName ?? "手动编辑",
                totalHours: totalHours > 0 ? totalHours : (currentRecord?.totalHours ?? 0),
                generatedAt: currentRecord?.generatedAt ?? now,
                updatedAt: now
            )
            store.save(record)
            currentRecord = record
            recentReports = store.recentReports()

        case .monthly:
            let trimmedOKR = monthlyOKR.trimmingCharacters(in: .whitespacesAndNewlines)
            guard currentMonthlyRecord != nil || !trimmedContent.isEmpty || !trimmedOKR.isEmpty else { return }
            let now = Date()
            let resolvedTitle = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? WeeklyReportGenerator.defaultTitle(for: month)
                : reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = MonthlyReportRecord(
                monthKey: month.monthKey,
                periodStart: month.startDateString,
                periodEnd: month.endDateString,
                title: resolvedTitle,
                content: reportContent,
                extraNotes: extraNotes,
                style: style.rawValue,
                providerName: currentMonthlyRecord?.providerName ?? "手动编辑",
                totalHours: totalHours > 0 ? totalHours : (currentMonthlyRecord?.totalHours ?? 0),
                generatedAt: currentMonthlyRecord?.generatedAt ?? now,
                updatedAt: now,
                monthlyOKR: monthlyOKR
            )
            store.saveMonthly(record)
            currentMonthlyRecord = record
            recentMonthlyReports = store.recentMonthlyReports()
        }
    }

    func clearReport() {
        autoSaveTask?.cancel()
        switch periodKind {
        case .weekly:
            store.delete(weekStart: week.startDateString)
            currentRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: week)
            recentReports = store.recentReports()
            message = "已清空本周周报"
        case .monthly:
            store.deleteMonthly(monthKey: month.monthKey)
            currentMonthlyRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: month)
            recentMonthlyReports = store.recentMonthlyReports()
            message = "已清空本月月报"
        }
        reportContent = ""
        extraNotes = ""
        monthlyOKR = ""
        errorMessage = nil
    }

    func formattedMarkdown() -> String {
        let cleanTitle = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = reportContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty else { return "" }
        if cleanTitle.isEmpty {
            return cleanContent
        }
        if cleanContent.hasPrefix("# ") {
            return cleanContent
        }
        return "# \(cleanTitle)\n\n\(cleanContent)"
    }

    func copyReport() {
        saveEditsIfNeeded()
        let text = formattedMarkdown()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func exportMarkdown() {
        saveEditsIfNeeded()
        let text = formattedMarkdown()
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safeTitle = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let fallbackName = periodKind == .weekly ? week.title + "工作周报" : month.title + "工作月报"
        panel.nameFieldStringValue = (safeTitle.isEmpty ? fallbackName : safeTitle) + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                message = "已导出\(periodKind.displayName)到 \(url.lastPathComponent)"
                errorMessage = nil
            } catch {
                errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    func openHistoryRecord(_ record: WeeklyReportRecord) async {
        guard let target = WeekRange.fromStartDateString(record.weekStart) else { return }
        await selectWeek(target)
    }

    func deleteHistoryRecord(weekStart: String) {
        store.delete(weekStart: weekStart)
        if periodKind == .weekly && week.startDateString == weekStart {
            currentRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: week)
            reportContent = ""
            extraNotes = ""
        }
        recentReports = store.recentReports()
    }

    func openMonthlyHistoryRecord(_ record: MonthlyReportRecord) async {
        guard let target = MonthRange.fromMonthKey(record.monthKey) else { return }
        await selectMonth(target)
    }

    func deleteMonthlyHistoryRecord(monthKey: String) {
        store.deleteMonthly(monthKey: monthKey)
        if periodKind == .monthly && month.monthKey == monthKey {
            currentMonthlyRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: month)
            reportContent = ""
            extraNotes = ""
        }
        recentMonthlyReports = store.recentMonthlyReports()
    }

    // MARK: - Tita 直连对接

    struct TitaPreparedEditor: Sendable {
        let detail: TitaReportDetail?
        let templateID: Int
        let modules: [TitaEditableModule]
        let mood: TitaMood
        let remoteState: TitaSubmitState
        let delayDate: String?
    }

    func makeTitaClient() throws -> TitaClient {
        let key = TitaClientCacheKey(
            baseURL: titaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            cookie: titaCookie.trimmingCharacters(in: .whitespacesAndNewlines),
            tenantID: titaTenantID.trimmingCharacters(in: .whitespacesAndNewlines),
            userID: titaUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let cached = cachedTitaClient, cached.key == key {
            return cached.client
        }
        cachedTitaClient?.client.invalidate()
        cachedTitaClient = nil
        let client = try TitaClient(
            baseURL: key.baseURL,
            cookie: key.cookie,
            tenantID: key.tenantID,
            userID: key.userID
        )
        cachedTitaClient = (key, client)
        return client
    }

    private func invalidateCachedTitaClient() {
        cachedTitaClient?.client.invalidate()
        cachedTitaClient = nil
    }

    @discardableResult
    func applyTitaCredentialInput(_ raw: String) -> TitaCredentialParser.ParsedCredential {
        invalidateCachedTitaClient()
        let parsed = TitaCredentialParser.parse(raw)
        if !parsed.cookie.isEmpty {
            settings[ReportKeys.titaCookie] = parsed.cookie
        }
        if let base = parsed.baseURL, !base.isEmpty {
            settings[ReportKeys.titaBaseURL] = base
        }
        if let tid = parsed.tenantID, !tid.isEmpty {
            settings[ReportKeys.titaTenantID] = tid
        }
        if let uid = parsed.userID, !uid.isEmpty {
            settings[ReportKeys.titaUserID] = uid
        }
        titaStatus = nil
        titaStatusError = nil
        return parsed
    }

    func clearTitaSession() {
        invalidateCachedTitaClient()
        settings[ReportKeys.titaCookie] = ""
        settings[ReportKeys.titaTenantID] = ""
        settings[ReportKeys.titaUserID] = ""
        settings[ReportKeys.titaUserName] = ""
        titaStatus = nil
        titaStatusError = nil
    }

    @discardableResult
    func verifyTitaAccount() async throws -> TitaAccountInfo {
        let client = try makeTitaClient()
        let info = try await client.verifySession()
        settings[ReportKeys.titaTenantID] = info.tenantID
        settings[ReportKeys.titaUserID] = info.userID
        if !info.userName.isEmpty {
            settings[ReportKeys.titaUserName] = info.userName
        }

        // 尽力自动探测当前企业的默认周报/月报模板 ID。
        if let weeklyTemplates = try? await client.fetchTemplates(summaryType: .weekly),
           let firstWeekly = weeklyTemplates.first {
            settings[ReportKeys.titaWeeklyTemplateID] = firstWeekly.templateID
        }
        if let monthlyTemplates = try? await client.fetchTemplates(summaryType: .monthly),
           let firstMonthly = monthlyTemplates.first {
            settings[ReportKeys.titaMonthlyTemplateID] = firstMonthly.templateID
        }

        return info
    }

    func refreshTitaStatus() async {
        guard isTitaConfigured, !isLoadingTitaStatus else { return }
        isLoadingTitaStatus = true
        titaStatusError = nil

        let targetKind = periodKind
        let targetKey = activePeriodKey
        let summaryType = activeTitaSummaryType
        let summaryDate = activeTitaSummaryDate
        let statusDate = activeTitaStatusDate

        defer { isLoadingTitaStatus = false }

        do {
            if titaTenantID.isEmpty || titaUserID.isEmpty {
                _ = try await verifyTitaAccount()
            }
            let client = try makeTitaClient()
            let status = try await client.fetchStatus(
                summaryType: summaryType,
                statusDate: statusDate,
                summaryDate: summaryDate
            )
            guard periodKind == targetKind && activePeriodKey == targetKey else { return }
            titaStatus = status
            if let remoteTid = status.templateID, remoteTid > 0 {
                switch targetKind {
                case .weekly: settings[ReportKeys.titaWeeklyTemplateID] = remoteTid
                case .monthly: settings[ReportKeys.titaMonthlyTemplateID] = remoteTid
                }
            }
        } catch {
            guard periodKind == targetKind && activePeriodKey == targetKey else { return }
            titaStatusError = error.localizedDescription
        }
    }

    nonisolated static func resolveTitaTemplateID(
        detailTemplateID: Int?,
        statusTemplateID: Int?,
        savedTemplateID: Int,
        matchedTemplateID: Int?,
        summaryType: TitaSummaryType
    ) -> Int {
        if let detailTemplateID, detailTemplateID > 0 {
            return detailTemplateID
        }
        if let matchedTemplateID, matchedTemplateID > 0 {
            return matchedTemplateID
        }
        if let statusTemplateID, statusTemplateID > 0 {
            return statusTemplateID
        }
        if savedTemplateID > 0 {
            return savedTemplateID
        }
        return summaryType == .weekly ? 1006 : 1007
    }

    func prepareTitaEditor() async throws -> TitaPreparedEditor {
        if titaTenantID.isEmpty || titaUserID.isEmpty {
            _ = try await verifyTitaAccount()
        }
        let client = try makeTitaClient()
        let summaryType = activeTitaSummaryType
        let summaryDate = activeTitaSummaryDate
        let statusDate = activeTitaStatusDate

        let status = try? await client.fetchStatus(
            summaryType: summaryType,
            statusDate: statusDate,
            summaryDate: summaryDate
        )
        if let status {
            titaStatus = status
        }

        let detail = try await client.fetchDetail(summaryType: summaryType, summaryDate: summaryDate)
        let preferredTemplateID = Self.resolveTitaTemplateID(
            detailTemplateID: detail?.templateID,
            statusTemplateID: status?.templateID,
            savedTemplateID: activeTitaTemplateID,
            matchedTemplateID: nil,
            summaryType: summaryType
        )
        var resolvedTemplateID = preferredTemplateID

        let moduleNames: [String]
        let existingTexts: [String]
        let moduleIDs: [Int?]
        let sortIndices: [Int]

        if let detail, !detail.richtextModules.isEmpty {
            let richModules = detail.richtextModules
            moduleNames = richModules.map(\.moduleName)
            existingTexts = richModules.map(\.plainText)
            moduleIDs = richModules.map { Optional($0.moduleId) }
            sortIndices = richModules.map(\.sortIndex)
        } else {
            let templates = (try? await client.fetchTemplates(summaryType: summaryType)) ?? []
            let matchedTemplate = templates.first { $0.templateID == preferredTemplateID } ?? templates.first
            if let matchedTemplate {
                resolvedTemplateID = Self.resolveTitaTemplateID(
                    detailTemplateID: detail?.templateID,
                    statusTemplateID: status?.templateID,
                    savedTemplateID: activeTitaTemplateID,
                    matchedTemplateID: matchedTemplate.templateID,
                    summaryType: summaryType
                )
                switch periodKind {
                case .weekly: settings[ReportKeys.titaWeeklyTemplateID] = resolvedTemplateID
                case .monthly: settings[ReportKeys.titaMonthlyTemplateID] = resolvedTemplateID
                }
            }
            let names = (matchedTemplate?.richtextModuleNames.isEmpty == false)
                ? matchedTemplate!.richtextModuleNames
                : TitaContentMapper.defaultModuleNames
            moduleNames = names
            existingTexts = Array(repeating: "", count: names.count)
            moduleIDs = Array(repeating: nil, count: names.count)
            sortIndices = Array(0..<names.count)
        }

        let localMapped = TitaContentMapper.map(markdown: reportContent, toModules: moduleNames)
        let editableModules = moduleNames.enumerated().map { idx, name in
            let localText = idx < localMapped.count ? localMapped[idx] : ""
            let remoteText = idx < existingTexts.count ? existingTexts[idx] : ""
            let prefill = localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? remoteText : localText
            return TitaEditableModule(
                id: "\(idx)-\(name)",
                moduleId: idx < moduleIDs.count ? moduleIDs[idx] : nil,
                moduleName: name,
                sortIndex: idx < sortIndices.count ? sortIndices[idx] : idx,
                text: prefill,
                existingRemoteText: remoteText
            )
        }

        let defaultMood = TitaMood(rawValue: settings[ReportKeys.titaDefaultMood]) ?? .unset
        let mood = detail?.currentMood ?? defaultMood
        let remoteState = detail?.submitState ?? status?.state ?? .none

        return TitaPreparedEditor(
            detail: detail,
            templateID: resolvedTemplateID,
            modules: editableModules,
            mood: mood,
            remoteState: remoteState,
            delayDate: detail?.delayDate ?? status?.delayDate
        )
    }

    @discardableResult
    func saveDraftToTita(
        templateID: Int,
        modules: [TitaEditableModule],
        mood: TitaMood
    ) async throws -> TitaPeriodStatus {
        saveEditsIfNeeded()
        isSyncingTita = true
        defer { isSyncingTita = false }

        if titaTenantID.isEmpty || titaUserID.isEmpty {
            _ = try await verifyTitaAccount()
        }
        let client = try makeTitaClient()
        let summaryType = activeTitaSummaryType
        let summaryDate = activeTitaSummaryDate
        let statusDate = activeTitaStatusDate

        let detail = try await client.saveDraft(
            summaryType: summaryType,
            summaryDate: summaryDate,
            templateID: templateID,
            moduleTexts: modules.map(\.text),
            mood: mood
        )
        let latestStatus = (try? await client.fetchStatus(
            summaryType: summaryType,
            statusDate: statusDate,
            summaryDate: summaryDate
        )) ?? TitaPeriodStatus(
            summaryDate: summaryDate,
            summaryType: summaryType,
            state: detail.submitState,
            dailyID: detail.dailyID,
            templateID: detail.templateID,
            delayDate: detail.delayDate
        )
        titaStatus = latestStatus
        titaStatusError = nil
        errorMessage = nil
        message = "已将「\(activePeriodTitle)」\(periodKind.displayName)存为 Tita 草稿"
        return latestStatus
    }

    @discardableResult
    func submitToTita(
        templateID: Int,
        modules: [TitaEditableModule],
        mood: TitaMood
    ) async throws -> TitaPeriodStatus {
        saveEditsIfNeeded()
        isSyncingTita = true
        defer { isSyncingTita = false }

        if titaTenantID.isEmpty || titaUserID.isEmpty {
            _ = try await verifyTitaAccount()
        }
        let client = try makeTitaClient()
        let summaryType = activeTitaSummaryType
        let summaryDate = activeTitaSummaryDate
        let statusDate = activeTitaStatusDate

        let status = try await client.submitReport(
            summaryType: summaryType,
            summaryDate: summaryDate,
            statusDate: statusDate,
            templateID: templateID,
            moduleTexts: modules.map(\.text),
            mood: mood
        )
        titaStatus = status
        titaStatusError = nil
        errorMessage = nil
        message = "已成功提交「\(activePeriodTitle)」\(periodKind.displayName)到 Tita（\(status.state.displayName)）"
        return status
    }

    func openActiveTitaInBrowser() {
        let state = titaStatus?.state ?? TitaSubmitState.none
        let isCreate = state == TitaSubmitState.none
        if let url = TitaPeriodCode.webEditorURL(
            baseURL: titaBaseURL,
            userID: titaUserID,
            periodKind: periodKind,
            summaryDate: activeTitaSummaryDate,
            templateID: activeTitaTemplateID,
            isCreate: isCreate
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    func reloadSavedReportsFromStore() {
        recentReports = store.recentReports()
        recentMonthlyReports = store.recentMonthlyReports()
        loadSavedReportForActivePeriod()
        if periodKind == .monthly {
            monthWeeklySummaries = store.weeklyReports(matchingWeekStarts: month.weeks.map(\.id))
        }
    }

    @discardableResult
    func syncTitaHistory(
        scope: TitaSyncScope,
        overwriteLocalEdits: Bool = false
    ) async throws -> TitaHistorySyncResult {
        guard !isSyncingTitaHistory else {
            return TitaHistorySyncResult(scope: scope)
        }
        isSyncingTitaHistory = true
        defer { isSyncingTitaHistory = false }

        let result = try await TitaHistorySyncService.syncUsingSavedSettings(
            database: context.database,
            settings: settings,
            scope: scope,
            overwriteLocalEdits: overwriteLocalEdits
        )
        reloadSavedReportsFromStore()
        errorMessage = nil
        message = "Tita 历史同步完成：\(result.summaryText)"
        return result
    }

    // MARK: - 定时自动生成与 Tita 未交提醒

    func runScheduledAutoGenerate(
        overwriteExisting: Bool,
        remindIfTitaUnsubmitted: Bool,
        notifyStyle: ReminderStyle,
        now: Date = Date()
    ) async -> ScheduledTaskOutcome {
        let targetPluginID = periodKind == .weekly ? ReportPlugin.pluginID : MonthlyReportPlugin.pluginID
        let noun = periodKind.displayName

        switch periodKind {
        case .weekly:
            await selectWeek(WeekRange.containing(now))
        case .monthly:
            await selectMonth(MonthRange.containing(now))
        }

        let hasExtra = !extraNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard totalLogCount > 0 || hasExtra else {
            return .skipped(
                summary: "本周期暂无日报记录，跳过生成\(noun)",
                detail: "区间 \(activePeriodRangeText) 暂未查到已提交工时或草稿记录。",
                shouldNotifyOverride: false,
                actionTitle: "打开\(noun)",
                actionPluginID: targetPluginID
            )
        }

        let hadExisting = hasReportContent
        if !hadExisting || overwriteExisting {
            await generate()
            if !hasReportContent, let err = errorMessage {
                return .failed(
                    summary: "自动生成\(noun)失败",
                    detail: err,
                    actionTitle: "打开\(noun)",
                    actionPluginID: targetPluginID
                )
            }
        }

        var titaHint = ""
        if remindIfTitaUnsubmitted && isTitaConfigured {
            await refreshTitaStatus()
            if let status = titaStatus, !status.state.isSubmitted {
                titaHint = "，Tita 尚未提交"
                let reminder = ReminderContent(
                    id: "report.tita.unsubmitted.\(periodKind.rawValue)",
                    title: "「\(activePeriodTitle)」\(noun)尚未提交 Tita",
                    message: "本地\(noun)草稿已备好（\(loggedDaysCount) 天 · \(WorkCalendar.hoursText(totalHours))h），点击即可预览并推送 Tita。",
                    systemImage: "paperplane.fill",
                    source: .scheduler,
                    targetPluginID: targetPluginID,
                    actions: [
                        ReminderAction(id: "later", title: "稍后处理") {},
                        ReminderAction(id: "push", title: "去预览并推送 Tita", isPrimary: true) { [weak self] in
                            self?.context.openPlugin(targetPluginID)
                        },
                    ]
                )
                context.reminders.show(reminder, style: notifyStyle)
            } else if titaStatus?.state.isSubmitted == true {
                titaHint = "，Tita 已提交"
            }
        }

        let verb = (hadExisting && !overwriteExisting) ? "已保留既有\(noun)草稿" : "已自动生成\(noun)草稿"
        return .succeeded(
            summary: "\(verb)（\(loggedDaysCount) 天 · \(WorkCalendar.hoursText(totalHours))h\(titaHint)）",
            detail: "\(activePeriodTitle)（\(activePeriodRangeText)）",
            actionTitle: "查看\(noun)",
            actionPluginID: targetPluginID
        )
    }
}
