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

    var periodKind: ReportPeriodKind
    var week: WeekRange
    var month: MonthRange
    var days: [DailyReportDay] = []
    var selectedDayFilter: String?
    var selectedWeekFilter: String?
    var providerKind: AIProviderKind

    var extraNotes: String = ""
    var reportTitle: String = ""
    var reportContent: String = ""

    var currentRecord: WeeklyReportRecord?
    var currentMonthlyRecord: MonthlyReportRecord?
    private(set) var recentReports: [WeeklyReportRecord] = []
    private(set) var recentMonthlyReports: [MonthlyReportRecord] = []
    private(set) var monthWeeklySummaries: [WeeklyReportRecord] = []

    var isLoadingLogs = false
    var isGenerating = false
    var syncedFromZentao = false
    var remoteError: String?
    var message: String?
    var errorMessage: String?
    var copied = false

    @ObservationIgnored private var rawItemsByDate: [String: [DailyLogItem]] = [:]
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?
    @ObservationIgnored private var copiedResetTask: Task<Void, Never>?

    init(context: PluginContext) {
        self.context = context
        self.store = ReportStore(db: context.database)
        self.dailyLogService = ZentaoDailyLogService(database: context.database, settings: context.settings)
        self.periodKind = context.settings[ReportKeys.lastPeriodKind]
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

    var isZentaoConfigured: Bool {
        dailyLogService.isZentaoConfigured
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
        guard kind != periodKind else { return }
        saveEditsIfNeeded()
        periodKind = kind
        settings[ReportKeys.lastPeriodKind] = kind
        clearActiveFilter()
        syncedFromZentao = false
        remoteError = nil
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
        settings[ReportKeys.lastPeriodKind] = .weekly
        week = newWeek
        clearActiveFilter()
        syncedFromZentao = false
        remoteError = nil
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
        settings[ReportKeys.lastPeriodKind] = .monthly
        month = newMonth
        clearActiveFilter()
        syncedFromZentao = false
        remoteError = nil
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
            monthWeeklySummaries = store.weeklyReports(matchingWeekStarts: month.weeks.map(\.id))
        } else {
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

        let result = await dailyLogService.fetch(
            from: start,
            to: end,
            includeDrafts: include
        )
        isLoadingLogs = false
        guard periodKind == targetKind && activePeriodKey == targetKey else { return }

        rawItemsByDate = result.itemsByDate
        syncedFromZentao = result.syncedFromZentao
        remoteError = result.remoteError
        rebuildDays(using: result.itemsByDate, periodKind: targetKind, week: targetWeek, month: targetMonth)
        if targetKind == .monthly {
            monthWeeklySummaries = store.weeklyReports(matchingWeekStarts: targetMonth.weeks.map(\.id))
        }
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
        let noun = periodKind.displayName
        let periodLabel = periodKind == .weekly ? "本周" : "本月"
        if totalLogCount == 0 && trimmedNotes.isEmpty {
            errorMessage = "\(periodLabel)暂未查到每日日报，请先刷新查询禅道记录，或在补充说明中填写工作要点后再生成。"
            return
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
                promptTemplate: settings[ReportKeys.monthlyPrompt]
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
                updatedAt: now
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
        } else {
            currentMonthlyRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: targetMonth)
            reportContent = ""
            extraNotes = ""
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
            guard currentMonthlyRecord != nil || !trimmedContent.isEmpty else { return }
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
                updatedAt: now
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
}
