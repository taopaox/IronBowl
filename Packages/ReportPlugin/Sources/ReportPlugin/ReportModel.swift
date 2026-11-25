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

    var week: WeekRange
    var days: [DailyReportDay] = []
    var selectedDayFilter: String?
    var providerKind: AIProviderKind

    var extraNotes: String = ""
    var reportTitle: String = ""
    var reportContent: String = ""

    var currentRecord: WeeklyReportRecord?
    private(set) var recentReports: [WeeklyReportRecord] = []

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
        let currentWeek = WeekRange.containing(Date())
        self.week = currentWeek
        self.providerKind = context.providers.defaultKind
        self.recentReports = store.recentReports()
        loadSavedReport(for: currentWeek)
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

    var filteredDays: [DailyReportDay] {
        let nonEmpty = days.filter { !$0.isEmpty }
        guard let selectedDayFilter else { return nonEmpty }
        return nonEmpty.filter { $0.dateString == selectedDayFilter }
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

    // MARK: - 周切换与日报查询

    func selectWeek(_ newWeek: WeekRange) async {
        if newWeek.startDateString == week.startDateString {
            await refreshLogs()
            return
        }
        saveEditsIfNeeded()
        week = newWeek
        selectedDayFilter = nil
        syncedFromZentao = false
        remoteError = nil
        message = nil
        errorMessage = nil
        loadSavedReport(for: newWeek)
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

    func loadLocalLogs() {
        let localMap = dailyLogService.loadLocal(
            from: week.startDateString,
            to: week.endDateString,
            includeDrafts: includeDrafts
        )
        rawItemsByDate = localMap
        rebuildDays(using: localMap, for: week)
    }

    func refreshLogs() async {
        guard !isLoadingLogs else { return }
        isLoadingLogs = true
        let targetWeek = week
        let include = includeDrafts
        let result = await dailyLogService.fetch(
            from: targetWeek.startDateString,
            to: targetWeek.endDateString,
            includeDrafts: include
        )
        isLoadingLogs = false
        guard week.startDateString == targetWeek.startDateString else { return }

        rawItemsByDate = result.itemsByDate
        syncedFromZentao = result.syncedFromZentao
        remoteError = result.remoteError
        rebuildDays(using: result.itemsByDate, for: targetWeek)
    }

    private func rebuildDays(using map: [String: [DailyLogItem]], for targetWeek: WeekRange) {
        days = targetWeek.days.map { day in
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

    // MARK: - 生成周报

    func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        errorMessage = nil
        message = nil

        if isZentaoConfigured && !syncedFromZentao {
            await refreshLogs()
        } else {
            rebuildDays(using: rawItemsByDate, for: week)
        }

        let trimmedNotes = extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if totalLogCount == 0 && trimmedNotes.isEmpty {
            errorMessage = "本周暂未查到每日日报，请先刷新查询禅道记录，或在补充说明中填写本周工作要点后再生成。"
            return
        }

        let input = WeeklyReportInput(
            week: week,
            days: days,
            extraNotes: extraNotes,
            style: style,
            includeHours: includeHours,
            promptTemplate: settings[ReportKeys.prompt]
        )
        let provider = context.providers.config(providerKind)
        let activeProvider = provider.executablePath.isEmpty ? nil : provider
        let output = await WeeklyReportGenerator.generate(input, provider: activeProvider)

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

        if let aiError = output.aiError {
            errorMessage = "AI 生成失败，已改为本地汇总：\(aiError)"
        } else if output.usedAI, let sec = output.aiSeconds {
            message = "\(provider.kind.displayName) 生成周报完成，用时 \(Int(sec)) 秒"
        } else if activeProvider == nil {
            message = "未配置 AI 提供者，已按本地日报规则汇总周报"
        } else {
            message = "周报已生成并保存"
        }
    }

    // MARK: - 持久化、复制与导出

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
    }

    func clearReport() {
        autoSaveTask?.cancel()
        store.delete(weekStart: week.startDateString)
        currentRecord = nil
        reportTitle = WeeklyReportGenerator.defaultTitle(for: week)
        reportContent = ""
        extraNotes = ""
        recentReports = store.recentReports()
        message = "已清空本周周报"
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
        panel.nameFieldStringValue = (safeTitle.isEmpty ? week.title + "工作周报" : safeTitle) + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                message = "已导出周报到 \(url.lastPathComponent)"
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
        if week.startDateString == weekStart {
            currentRecord = nil
            reportTitle = WeeklyReportGenerator.defaultTitle(for: week)
            reportContent = ""
            extraNotes = ""
        }
        recentReports = store.recentReports()
    }
}
