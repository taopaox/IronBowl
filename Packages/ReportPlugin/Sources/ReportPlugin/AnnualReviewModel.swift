import AppKit
import Foundation
import IronBowlKit
import Observation
import UniformTypeIdentifiers
import ZentaoLogPlugin

struct AnnualPosterData: Equatable {
    let title: String
    let periodRange: String
    let userName: String
    let totalHours: Double
    let normalHours: Double
    let overtimeHours: Double
    let overtimeDaysCount: Int
    let loggedDaysCount: Int
    let expectedWorkdaysCount: Int
    let commitCount: Int
    let addedLines: Int
    let deletedLines: Int
    let topProjects: [LedgerProjectStat]
    let busiestMonth: String?
    let averageClockIn: String?
    let earliestClockIn: String?
    let latestOffWork: String?
    let badgeTitle: String
    let badgeSubtitle: String
}

@Observable
final class AnnualReviewModel {
    let context: PluginContext
    let store: ReportStore
    let dailyLogService: ZentaoDailyLogService

    var scopeKind: ReviewScopeKind = .yearly
    var range: ReviewRange
    var providerKind: AIProviderKind

    var extraNotes: String = ""
    var reportTitle: String = ""
    var reportContent: String = ""
    var currentRecord: ReviewReportRecord?
    private(set) var recentReviews: [ReviewReportRecord] = []

    var ledgerSummary: WorkLedgerSummary = .empty
    var monthlyReports: [MonthlyReportRecord] = []
    var gitStats: GitPeriodStats = .empty

    var isLoading = false
    var isGenerating = false
    var syncedFromZentao = false
    var remoteError: String?
    var message: String?
    var errorMessage: String?
    var copied = false

    @ObservationIgnored private var rawItemsByDate: [String: [DailyLogItem]] = [:]
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?
    @ObservationIgnored private var copiedResetTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoadedPeriodKey: String?
    @ObservationIgnored private var lastRefreshedAtByKey: [String: Date] = [:]

    init(context: PluginContext) {
        self.context = context
        self.store = ReportStore(db: context.database)
        self.dailyLogService = ZentaoDailyLogService(database: context.database, settings: context.settings)
        self.range = ReviewRange.containing(Date(), scopeKind: .yearly)
        self.providerKind = context.providers.defaultKind
        self.recentReviews = store.recentReviews()
        loadSavedReview()
    }

    var hasLoadedCurrentPeriod: Bool {
        lastLoadedPeriodKey == range.periodKey
    }

    func shouldAutoRefresh(cooldown: TimeInterval = 120) -> Bool {
        guard let last = lastRefreshedAtByKey[range.periodKey] else { return true }
        return Date().timeIntervalSince(last) >= cooldown
    }

    var settings: SettingsStore { context.settings }

    var style: AnnualReviewStyle {
        get { settings[ReportKeys.annualStyle] }
        set { settings[ReportKeys.annualStyle] = newValue }
    }

    var hasContent: Bool {
        !reportContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCurrentYearReview: Bool {
        let key = ReviewRange.containing(Date(), scopeKind: .yearly).periodKey
        return recentReviews.contains { $0.periodKey == key && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isZentaoConfigured: Bool {
        dailyLogService.isZentaoConfigured
    }

    func switchScope(_ next: ReviewScopeKind) {
        guard next != scopeKind else { return }
        saveEditsIfNeeded()
        scopeKind = next
        range = ReviewRange(scopeKind: next, year: range.year, periodIndex: 1)
        syncedFromZentao = false
        remoteError = nil
        message = nil
        errorMessage = nil
        loadSavedReview()
        loadLocal()
    }

    func shiftPeriod(_ delta: Int) {
        saveEditsIfNeeded()
        range = range.shifted(by: delta)
        syncedFromZentao = false
        remoteError = nil
        message = nil
        errorMessage = nil
        loadSavedReview()
        loadLocal()
    }

    func selectRange(_ target: ReviewRange) {
        saveEditsIfNeeded()
        scopeKind = target.scopeKind
        range = target
        syncedFromZentao = false
        remoteError = nil
        message = nil
        errorMessage = nil
        loadSavedReview()
        loadLocal()
    }

    func goToCurrentPeriod() {
        selectRange(ReviewRange.containing(Date(), scopeKind: scopeKind))
    }

    func loadSavedReview() {
        if let saved = store.reviewReport(forPeriodKey: range.periodKey) {
            currentRecord = saved
            reportTitle = saved.title
            reportContent = saved.content
            extraNotes = saved.extraNotes
        } else {
            currentRecord = nil
            reportTitle = AnnualReviewGenerator.defaultTitle(for: range)
            reportContent = ""
            extraNotes = ""
        }
    }

    func loadLocal() {
        let items = dailyLogService.loadLocal(from: range.startDateString, to: range.endDateString, includeDrafts: true)
        rawItemsByDate = items
        lastLoadedPeriodKey = range.periodKey
        monthlyReports = store.monthlyReports(matchingMonthKeys: range.monthKeys)
        recomputeSummary(with: items)
    }

    func refreshAll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let targetKey = range.periodKey
        let start = range.startDateString
        let end = range.endDateString

        async let logResult = dailyLogService.fetch(from: start, to: end, includeDrafts: true)
        let repos = GitScanner.configuredRepos(database: context.database, settings: settings)
        let email = await GitScanner.configuredAuthorEmail(settings: settings)
        async let fetchedGit = GitScanner.periodStats(repos: repos, authorEmail: email, startDate: start, endDate: end)

        let (logs, git) = await (logResult, fetchedGit)
        guard range.periodKey == targetKey else { return }

        rawItemsByDate = logs.itemsByDate
        syncedFromZentao = logs.syncedFromZentao
        remoteError = logs.remoteError
        gitStats = git
        lastLoadedPeriodKey = targetKey
        lastRefreshedAtByKey[targetKey] = Date()
        monthlyReports = store.monthlyReports(matchingMonthKeys: range.monthKeys)
        recomputeSummary(with: logs.itemsByDate)
    }

    private func recomputeSummary(with itemsByDate: [String: [DailyLogItem]]) {
        let dates = range.days
        let cal = context.workCalendar
        let now = Date()
        var workdayFlags: [String: Bool] = [:]
        var clockIns: [String: Date] = [:]
        var clockOuts: [String: Date] = [:]
        var stayHours: [String: Double] = [:]
        var anomalies: [String: [String]] = [:]
        var plannedOT: [String: Double] = [:]
        var offTexts: [String: String] = [:]

        for d in dates {
            let ds = WorkCalendar.dayString(d)
            workdayFlags[ds] = cal.isWorkday(d)
            if let ci = cal.clockIn(on: d) { clockIns[ds] = ci }
            if let co = cal.clockOut(on: d) { clockOuts[ds] = co }
            if let stay = cal.actualStayHours(on: d) { stayHours[ds] = stay }
            let dayAnom = cal.attendanceAnomalies(on: d, now: now).map(\.displayName)
            if !dayAnom.isEmpty { anomalies[ds] = dayAnom }
            let ot = cal.overtimeHours(on: d)
            if ot > 0 { plannedOT[ds] = ot }
            if let off = cal.offWorkTimeText(on: d) { offTexts[ds] = off }
        }

        ledgerSummary = WorkLedgerSummary.computeSummary(
            year: range.year,
            dates: dates,
            workdayFlags: workdayFlags,
            itemsByDate: itemsByDate,
            clockInsByDate: clockIns,
            clockOutsByDate: clockOuts,
            stayHoursByDate: stayHours,
            anomaliesByDate: anomalies,
            plannedOvertimeByDate: plannedOT,
            offWorkTextByDate: offTexts
        )
    }

    func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        message = nil

        await refreshAll()

        let hasAnyData = ledgerSummary.totalHours > 0
            || !monthlyReports.isEmpty
            || gitStats.commitCount > 0
            || !extraNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard hasAnyData else {
            errorMessage = "当前周期暂无工时、月报或代码提交数据，请先补充亮点后再生成。"
            return
        }

        let provider = context.providers.config(providerKind)
        let activeProvider = provider.executablePath.isEmpty ? nil : provider

        let input = AnnualReviewInput(
            range: range,
            style: style,
            ledgerSummary: ledgerSummary,
            monthlyReports: monthlyReports,
            gitStats: gitStats,
            extraNotes: extraNotes,
            promptTemplate: settings[ReportKeys.annualPrompt]
        )
        let output = await AnnualReviewGenerator.generate(input, provider: activeProvider)
        reportTitle = output.title
        reportContent = output.content

        let now = Date()
        let record = ReviewReportRecord(
            periodKey: range.periodKey,
            scopeKind: range.scopeKind.rawValue,
            periodStart: range.startDateString,
            periodEnd: range.endDateString,
            title: output.title,
            content: output.content,
            extraNotes: extraNotes,
            style: style.rawValue,
            providerName: output.usedAI ? provider.kind.displayName : "本地规则汇总",
            totalHours: ledgerSummary.totalHours,
            overtimeHours: ledgerSummary.overtimeHours,
            commitCount: gitStats.commitCount,
            generatedAt: currentRecord?.generatedAt ?? now,
            updatedAt: now
        )
        store.saveReview(record)
        currentRecord = record
        recentReviews = store.recentReviews()

        if let aiErr = output.aiError {
            errorMessage = "AI 生成失败，已改为本地规则整理：\(aiErr)"
        } else if output.usedAI, let sec = output.aiSeconds {
            message = "\(provider.kind.displayName) 生成\(range.scopeKind.displayName)完成，用时 \(Int(sec)) 秒"
        } else {
            message = "已汇总生成\(range.title)述职报告"
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
        let trimmed = reportContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentRecord != nil || !trimmed.isEmpty else { return }
        let now = Date()
        let resolvedTitle = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AnnualReviewGenerator.defaultTitle(for: range)
            : reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ReviewReportRecord(
            periodKey: range.periodKey,
            scopeKind: range.scopeKind.rawValue,
            periodStart: range.startDateString,
            periodEnd: range.endDateString,
            title: resolvedTitle,
            content: reportContent,
            extraNotes: extraNotes,
            style: style.rawValue,
            providerName: currentRecord?.providerName ?? "手动编辑",
            totalHours: ledgerSummary.totalHours,
            overtimeHours: ledgerSummary.overtimeHours,
            commitCount: gitStats.commitCount,
            generatedAt: currentRecord?.generatedAt ?? now,
            updatedAt: now
        )
        store.saveReview(record)
        currentRecord = record
        recentReviews = store.recentReviews()
    }

    func clearReview() {
        store.deleteReview(periodKey: range.periodKey)
        currentRecord = nil
        reportTitle = AnnualReviewGenerator.defaultTitle(for: range)
        reportContent = ""
        extraNotes = ""
        recentReviews = store.recentReviews()
    }

    func deleteHistoryRecord(_ periodKey: String) {
        store.deleteReview(periodKey: periodKey)
        if range.periodKey == periodKey {
            currentRecord = nil
            reportTitle = AnnualReviewGenerator.defaultTitle(for: range)
            reportContent = ""
            extraNotes = ""
        }
        recentReviews = store.recentReviews()
    }

    func copyMarkdown() {
        let md = fullMarkdown()
        guard !md.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func exportMarkdown() {
        let md = fullMarkdown()
        guard !md.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "\(range.periodKey)-述职总结.md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                message = "已导出至 \(url.lastPathComponent)"
            } catch {
                errorMessage = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    func fullMarkdown() -> String {
        let title = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = reportContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "" }
        return title.isEmpty ? body : "# \(title)\n\n\(body)"
    }

    var posterData: AnnualPosterData {
        let rawName = settings[UserProfileKeys.displayName].trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = !rawName.isEmpty ? rawName : (!fallbackName.isEmpty ? fallbackName : "饭碗打工人")

        let (badgeTitle, badgeSubtitle): (String, String) = {
            if ledgerSummary.overtimeHours >= 80 || gitStats.commitCount >= 500 {
                return ("硬核攻坚主力", "工时与代码双在线，项目推进的中流砥柱")
            }
            if let avg = ledgerSummary.averageClockInMinutes, avg <= 8 * 60 + 45 {
                return ("晨光早鸟先锋", "平均 \(ledgerSummary.averageClockInText ?? "08:45") 前到岗，效率稳健拉满")
            }
            if ledgerSummary.overtimeDaysCount >= 10 {
                return ("深夜守夜星人", "多次加班扛住上线节点，辛苦了")
            }
            if ledgerSummary.loggedDaysCount > 0 {
                return ("稳健交付达人", "把饭碗端稳，步履不停")
            }
            return ("蓄力启航中", "记录每一天，沉淀每一次交付")
        }()

        return AnnualPosterData(
            title: "\(range.title)工作账单",
            periodRange: range.rangeText,
            userName: userName,
            totalHours: ledgerSummary.totalHours,
            normalHours: ledgerSummary.normalHours,
            overtimeHours: ledgerSummary.overtimeHours,
            overtimeDaysCount: ledgerSummary.overtimeDaysCount,
            loggedDaysCount: ledgerSummary.loggedDaysCount,
            expectedWorkdaysCount: ledgerSummary.expectedWorkdaysCount,
            commitCount: gitStats.commitCount,
            addedLines: gitStats.addedLines,
            deletedLines: gitStats.deletedLines,
            topProjects: Array(ledgerSummary.projectBreakdown.prefix(4)),
            busiestMonth: gitStats.busiestMonth,
            averageClockIn: ledgerSummary.averageClockInText,
            earliestClockIn: ledgerSummary.earliestClockInText,
            latestOffWork: ledgerSummary.latestOffWorkText,
            badgeTitle: badgeTitle,
            badgeSubtitle: badgeSubtitle
        )
    }
}
