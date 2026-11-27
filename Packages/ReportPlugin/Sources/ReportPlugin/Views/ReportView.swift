import IronBowlKit
import SwiftUI
import ZentaoLogPlugin

struct ReportView: View {
    @Bindable var model: WeeklyReportModel
    @Environment(\.isPageActive) private var isPageActive
    @State private var showHistory = false
    @State private var previewMode: PreviewMode = .preview
    @State private var confirmClear = false
    @State private var showTitaSubmit = false
    @State private var showFeishuExport = false
    @State private var notesExpanded = true
    @State private var okrExpanded = true
    @State private var titaStampToken = 0

    enum PreviewMode: Hashable {
        case preview
        case edit
    }

    private var palette: JournalPalette {
        JournalPalette(preset: model.settings[JournalKeys.paperPreset])
    }

    private var currentChapter: JournalChapter {
        model.periodKind == .weekly ? .weekly : .monthly
    }

    private var reportStatusState: JournalStatusState {
        if !model.hasReportContent {
            return .unwritten
        }
        if model.isTitaConfigured, model.titaStatus?.state.isSubmitted == false {
            return .draft
        }
        return .completed
    }

    private var reportStatusBadgeText: String {
        let periodWord = model.periodKind == .weekly ? "本周" : "本月"
        switch reportStatusState {
        case .unwritten:
            return model.isCurrentPeriod ? "\(periodWord)未写" : "\(model.activePeriodTitle)未写"
        case .draft:
            return "Tita 未交"
        case .completed:
            return model.isCurrentPeriod ? "\(periodWord)已写" : "已完成"
        case .offDay:
            return ""
        }
    }

    var body: some View {
        JournalSpreadShell(
            chapter: currentChapter,
            settings: model.settings,
            statusState: reportStatusState,
            statusBadgeText: reportStatusBadgeText,
            showHistoryTab: true,
            onSelectChapter: { target in
                switch target {
                case .daily:
                    model.context.openPlugin(ZentaoLogPlugin.pluginID)
                case .weekly:
                    if model.lockedPeriodKind != nil {
                        model.context.openPlugin(ReportPlugin.pluginID)
                    } else {
                        Task { await model.switchPeriodKind(.weekly) }
                    }
                case .monthly:
                    if model.lockedPeriodKind != nil {
                        model.context.openPlugin(MonthlyReportPlugin.pluginID)
                    } else {
                        Task { await model.switchPeriodKind(.monthly) }
                    }
                }
            },
            onOpenHistory: {
                showHistory.toggle()
            }
        ) {
            headerActions
        } leftPage: {
            leftJournalPage
        } rightPage: {
            rightJournalPage
        }
        .task(id: "\(model.periodKind.rawValue)-\(model.activePeriodKey)") {
            await syncPeriodIfNeeded()
        }
        .onChange(of: isPageActive) { _, active in
            if active {
                Task { await syncPeriodIfNeeded() }
            } else {
                model.saveEditsIfNeeded()
            }
        }
        .onChange(of: model.titaStatus?.state) { _, _ in
            titaStampToken += 1
        }
        .onDisappear {
            model.saveEditsIfNeeded()
        }
        .sheet(isPresented: $showTitaSubmit) {
            TitaSubmitSheet(model: model)
        }
        .sheet(isPresented: $showFeishuExport) {
            FeishuDocExportSheet(model: model)
        }
        .alert("清空\(model.periodKind.displayName)？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                model.clearReport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本地保存的「\(model.activePeriodTitle)」\(model.periodKind.displayName)内容，不影响每日禅道日报。")
        }
    }

    private func syncPeriodIfNeeded() async {
        if model.days.isEmpty {
            model.loadLocalLogs()
        }
        if model.isZentaoConfigured && (!model.syncedFromZentao || model.shouldAutoSyncLogs()) {
            await model.refreshLogs()
        } else if model.periodKind == .monthly && model.includeGitStats && !model.monthGitStats.hasData {
            await model.refreshMonthGitStats()
        }
        if model.isTitaConfigured && (model.titaStatus == nil || model.shouldAutoSyncTita()) {
            await model.refreshTitaStatus()
        }
    }

    // MARK: - 顶栏右侧操作

    @ViewBuilder
    private var headerActions: some View {
        let p = palette
        let totalHistoryCount: Int = if let locked = model.lockedPeriodKind {
            locked == .weekly ? model.recentReports.count : model.recentMonthlyReports.count
        } else {
            model.recentReports.count + model.recentMonthlyReports.count
        }

        if model.lockedPeriodKind == nil {
            DSTabs(
                selection: Binding(
                    get: { model.periodKind },
                    set: { next in
                        Task<Void, Never> { await model.switchPeriodKind(next) }
                    }
                ),
                options: ReportPeriodKind.allCases.map { ($0, $0.displayName) }
            )
        }

        Button {
            showHistory.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                if totalHistoryCount > 0 {
                    Text("\(totalHistoryCount)")
                        .font(DS.font(11.5, .semibold).monospacedDigit())
                }
            }
        }
        .buttonStyle(.journalSecondary(p))
        .help("查看历史\(model.lockedPeriodKind?.displayName ?? "周报与月报")")
        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
            ReportHistoryPopover(model: model, isPresented: $showHistory)
        }

        Button {
            Task { await model.refreshLogs() }
        } label: {
            if model.isLoadingLogs {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.journalSecondary(p))
        .help("重新查询每日日报")
        .disabled(model.isLoadingLogs)

        DSPicker(
            selection: $model.providerKind,
            options: AIProviderKind.allCases.map {
                DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
            }
        )
        .help("选择用于生成\(model.periodKind.displayName)的 AI")
    }

    // MARK: - 左页：周期撕历、统计、便签补充说明与每日摘录

    @ViewBuilder
    private var leftJournalPage: some View {
        let p = palette
        let currentBadge = model.periodKind == .weekly ? "本周" : "本月"
        let backLabel = model.periodKind == .weekly ? "回本周" : "回本月"
        let periodHeading = model.periodKind == .weekly
            ? "第 \(model.week.weekOfYear) 周"
            : model.month.title
        let subRange = model.periodKind == .weekly ? model.week.shortRangeText : model.month.shortRangeText

        // 1. 周期撕历头
        HStack(spacing: 6) {
            Button {
                Task { await model.previousPeriod() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(DS.font(11.5, .bold))
            }
            .buttonStyle(.journalSecondary(p))
            .help(model.periodKind == .weekly ? "上一周" : "上一月")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(periodHeading)
                        .font(JournalPalette.serif(18, .bold))
                        .foregroundStyle(p.ink)
                    if let badge = model.activeRelativeBadge {
                        Tag(badge, color: badge == currentBadge ? p.stampGreen : p.inkSecondary)
                    }
                }
                Text(subRange)
                    .font(DS.font(11.5).monospacedDigit())
                    .foregroundStyle(p.inkSecondary)
            }

            Spacer(minLength: 4)

            if !model.isCurrentPeriod {
                Button(backLabel) {
                    Task { await model.goToCurrentPeriod() }
                }
                .buttonStyle(.plain)
                .font(DS.font(11.5, .semibold))
                .foregroundStyle(p.stampGreen)
            }

            Button {
                Task { await model.nextPeriod() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(DS.font(11.5, .bold))
            }
            .buttonStyle(.journalSecondary(p))
            .help(model.periodKind == .weekly ? "下一周" : "下一月")
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(p.borderStrong).frame(height: 1)
        }

        // 2. 周期统计三联卡
        JournalPeriodSummaryCards(model: model, palette: p)

        if model.periodKind == .monthly {
            JournalMonthlyGitCard(model: model, palette: p)
        }

        // 3. 7 天 / 月周分片筛选条
        if model.periodKind == .weekly {
            JournalWeekFilterStrip(days: model.days, selectedDate: $model.selectedDayFilter, palette: p)
        } else {
            JournalMonthWeekStrip(model: model, palette: p)
        }

        // 4. 每日手账摘录
        HStack(spacing: 6) {
            Text("每日摘录")
                .font(DS.font(12.5, .bold))
                .foregroundStyle(p.ink)

            if model.syncedFromZentao {
                Circle().fill(p.stampGreen).frame(width: 6, height: 6)
                Text("已同步")
                    .font(DS.font(11))
                    .foregroundStyle(p.inkSecondary)
            } else if model.isLoadingLogs {
                ProgressView().controlSize(.mini)
            }

            if model.hasActiveFilter {
                Button(model.periodKind == .weekly ? "全周" : "全月") {
                    model.clearActiveFilter()
                }
                .buttonStyle(.plain)
                .font(DS.font(11.5, .semibold))
                .foregroundStyle(p.stampGreen)
            }

            Spacer(minLength: 4)

            Toggle("含草稿", isOn: $model.includeDrafts)
                .toggleStyle(.checkbox)
                .font(DS.font(11.5))
                .foregroundStyle(p.inkSecondary)

            Button("写日报") {
                model.context.openPlugin(ZentaoLogPlugin.pluginID)
            }
            .buttonStyle(.plain)
            .font(DS.font(11.5, .semibold))
            .foregroundStyle(p.stampRed)
        }

        if model.totalLogCount == 0 {
            JournalPaperCard(palette: p, paperclip: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isLoadingLogs ? "正在查询每日日报…" : "该周期暂无每日日报")
                        .font(DS.font(13, .semibold))
                        .foregroundStyle(p.ink)
                    Text("可前往「日报」补全，或在上方黄色便利贴填写要点。")
                        .font(DS.font(12))
                        .foregroundStyle(p.inkSecondary)
                }
            }
        } else if model.filteredDays.isEmpty {
            JournalPaperCard(palette: p) {
                HStack {
                    Text(model.periodKind == .weekly ? "当天暂无日报" : "该周暂无日报")
                        .font(DS.font(12.5))
                        .foregroundStyle(p.inkSecondary)
                    Spacer()
                    Button("显示全部") { model.clearActiveFilter() }
                        .buttonStyle(.journalSecondary(p))
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(model.filteredDays) { day in
                    JournalDailyExcerptSlip(day: day, palette: p, settings: model.settings) { bullet in
                        appendToReport(bullet)
                    }
                }
            }
        }
    }

    // MARK: - 右页：Tita 印章、单行工具栏、手账正文

    @ViewBuilder
    private var rightJournalPage: some View {
        let p = palette
        let noun = model.periodKind.displayName
        let generateTitle = model.hasReportContent ? "重新生成" : "生成\(noun)"
        let titaStamp: (text: String, tone: JournalStampBadge.Tone) = {
            if let status = model.titaStatus {
                switch status.state {
                case .onTime: return ("Tita 按时提交", .done)
                case .delay: return ("Tita 逾期提交", .draft)
                case .unSubmit: return ("Tita 未提交", .pending)
                case .none: return ("Tita 未创建", .pending)
                }
            }
            return (model.hasReportContent ? "本地手账已存" : "待生成\(noun)", model.hasReportContent ? .neutral : .pending)
        }()

        // 标题 + Tita 印章
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                TextField("输入\(noun)标题…", text: $model.reportTitle)
                    .textFieldStyle(.plain)
                    .font(JournalPalette.serif(22, .bold))
                    .foregroundStyle(p.ink)
                    .onChange(of: model.reportTitle) {
                        model.scheduleAutoSave()
                    }

                HStack(spacing: 6) {
                    Text(model.activePeriodRangeText)
                    if model.totalHours > 0 {
                        Text("·")
                        Text("\(WorkCalendar.hoursText(model.totalHours))h")
                    }
                    if let updatedAt = model.activeUpdatedAt {
                        Text("·")
                        Text("更新于 \(CN.dateTime(updatedAt))")
                    }
                    if let providerName = model.activeProviderName, !providerName.isEmpty {
                        Text("·")
                        Text(providerName)
                    }
                }
                .font(DS.font(11.5))
                .foregroundStyle(p.inkTertiary)
            }

            Spacer(minLength: 8)

            Button {
                showTitaSubmit = true
            } label: {
                JournalStampBadge(
                    titaStamp.text,
                    tone: titaStamp.tone,
                    palette: p,
                    animationToken: titaStampToken
                )
            }
            .buttonStyle(.plain)
            .help("点击核对或推送到 Tita")
        }

        // 单行聚焦工具栏
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                leadingReportControls(palette: p)
                Spacer(minLength: 6)
                trailingReportActions(palette: p, generateTitle: generateTitle)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    leadingReportControls(palette: p)
                    Spacer()
                }
                HStack(spacing: 8) {
                    trailingReportActions(palette: p, generateTitle: generateTitle)
                    Spacer()
                }
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(p.border).frame(height: 1)
        }

        statusBanners

        reportStatusBanner(palette: p)

        if model.periodKind == .monthly {
            JournalMonthlyOKRCard(model: model, palette: p, expanded: $okrExpanded)
        }

        JournalExtraNotesSticky(model: model, palette: p, expanded: $notesExpanded)

        if model.hasReportContent || previewMode == .edit {
            if previewMode == .preview {
                JournalMarkdownReportView(markdown: model.reportContent, palette: p, chapterColor: currentChapter.tabColor(in: p))
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.reportContent)
                        .font(DS.mono(13.5))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 380)
                        .padding(12)
                        .background(p.paperCard, in: .rect(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(p.borderStrong) }
                        .onChange(of: model.reportContent) {
                            model.scheduleAutoSave()
                        }
                    Text("支持 Markdown 格式（# / ## / ### / 列表），内容自动保存。")
                        .font(DS.caption)
                        .foregroundStyle(p.inkTertiary)
                }
            }
        } else {
            emptyReportDocumentState(palette: p)
        }
    }

    @ViewBuilder
    private func leadingReportControls(palette p: JournalPalette) -> some View {
        DSTabs(selection: $previewMode, options: [
            (.preview, "阅读"),
            (.edit, "编辑"),
        ])

        DSPicker(
            selection: $model.style,
            options: WeeklyReportStyle.allCases.map {
                DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
            }
        )

        Toggle("附工时", isOn: $model.includeHours)
            .toggleStyle(.checkbox)
            .font(DS.font(12))
            .foregroundStyle(p.inkSecondary)
    }

    @ViewBuilder
    private func trailingReportActions(palette p: JournalPalette, generateTitle: String) -> some View {
        Button {
            Task { await model.generate() }
        } label: {
            if model.isGenerating {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("生成中")
                }
            } else {
                Label(generateTitle, systemImage: "sparkles")
            }
        }
        .buttonStyle(.journalSecondary(p))
        .disabled(model.isGenerating)

        if model.hasReportContent {
            Button {
                model.copyReport()
            } label: {
                Label(model.copied ? "已复制" : "复制", systemImage: model.copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.journalSecondary(p))

            Button {
                model.exportMarkdown()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.journalSecondary(p))
            .help("导出为 Markdown 文件")

            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(p.stampRed)
            }
            .buttonStyle(.journalSecondary(p))
            .help("清空当前\(model.periodKind.displayName)")

            Button {
                showFeishuExport = true
            } label: {
                Label("写飞书", systemImage: "doc.badge.arrow.up")
            }
            .buttonStyle(.journalSecondary(p))
            .help("通过 lark-cli 读取飞书子周报或覆盖写入目标飞书文档")

            Button {
                showTitaSubmit = true
            } label: {
                Label(
                    model.titaStatus?.state.isSubmitted == true ? "更新 Tita" : "推送 Tita",
                    systemImage: "paperplane.fill"
                )
            }
            .buttonStyle(.journalPrimary(tint: currentChapter.tabColor(in: p)))
            .help("打开 Tita 报送单，支持先存草稿或正式提交")
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if !model.isZentaoConfigured {
            DSBanner(
                .info,
                "未配置禅道账号，当前仅展示本地已提交记录与草稿。",
                actionTitle: "去填写账号"
            ) {
                model.context.openSettings(ZentaoLogPlugin.settingsAccountID)
            }
        }
        if let remoteError = model.remoteError {
            DSBanner(.warning, "禅道同步失败（当前展示本地数据）：\(remoteError)")
        }
        if let error = model.errorMessage {
            feedbackBanner(.danger, text: error)
        }
        if let message = model.message {
            feedbackBanner(.success, text: message)
        }
    }

    private func feedbackBanner(_ kind: DSBanner.Kind, text: String) -> some View {
        let color: Color = kind == .danger ? DS.danger : DS.success
        let icon = kind == .danger ? "xmark.octagon" : "checkmark.circle"
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                model.clearFeedback()
            } label: {
                Image(systemName: "xmark")
                    .font(DS.font(11, .semibold))
            }
            .buttonStyle(.plain)
            .opacity(0.7)
            .help("关闭提示")
        }
        .font(DS.body)
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.09), in: .rect(cornerRadius: 10))
    }

    private func emptyReportDocumentState(palette p: JournalPalette) -> some View {
        let noun = model.periodKind.displayName
        let periodLabel = model.periodKind == .weekly ? "本周" : "本月"
        let weeklyRefCount = model.monthWeeklySummaries.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let materialSummary: String = if model.totalLogCount > 0 {
            if model.periodKind == .monthly && weeklyRefCount > 0 {
                "已收集本月 \(model.loggedDaysCount) 天共 \(model.totalLogCount) 条日报（累计 \(WorkCalendar.hoursText(model.totalHours))h），并关联 \(weeklyRefCount) 份周报参考"
            } else {
                "已收集\(periodLabel) \(model.loggedDaysCount) 天共 \(model.totalLogCount) 条日报，累计 \(WorkCalendar.hoursText(model.totalHours))h"
            }
        } else {
            "\(periodLabel)暂无每日日报，可在左页黄色便利贴填写要点后直接生成"
        }

        return VStack(spacing: 14) {
            Image(systemName: "doc.badge.plus")
                .font(DS.font(28, .semibold))
                .foregroundStyle(p.stampRed)
            Text(model.isCurrentPeriod
                ? "\(model.periodKind == .weekly ? "本周" : "本月")\(noun)未写"
                : "「\(model.activePeriodTitle)」\(noun)未写")
                .font(JournalPalette.serif(20, .bold))
                .foregroundStyle(p.stampRed)
            Text(materialSummary)
                .font(DS.body)
                .foregroundStyle(p.inkSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    Task { await model.generate() }
                } label: {
                    Label("立即生成\(noun)", systemImage: "sparkles")
                }
                .buttonStyle(.journalPrimary(tint: p.stampRed))
                .disabled(model.isGenerating)

                Button("直接手写") {
                    previewMode = .edit
                }
                .buttonStyle(.journalSecondary(p))
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(p.stampRed.opacity(0.04), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(p.stampRed.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
    }

    @ViewBuilder
    private func reportStatusBanner(palette p: JournalPalette) -> some View {
        let noun = model.periodKind.displayName
        let periodLabel = model.periodKind == .weekly ? "本周" : "本月"
        let scopePrefix = model.isCurrentPeriod ? "\(periodLabel)\(noun)" : "「\(model.activePeriodTitle)」\(noun)"

        switch reportStatusState {
        case .unwritten:
            let detail = model.totalLogCount > 0
                ? "已收集 \(model.loggedDaysCount) 天共 \(model.totalLogCount) 条日报（\(WorkCalendar.hoursText(model.totalHours))h），可直接一键汇总。"
                : "\(periodLabel)暂无每日日报，可在左页黄色便利贴写要点后生成。"
            JournalStatusBanner(
                state: .unwritten,
                title: "\(scopePrefix)未写",
                detail: detail,
                palette: p,
                actionTitle: "✨ 立即生成\(noun)",
                actionDisabled: model.isGenerating
            ) {
                Task { await model.generate() }
            }
        case .draft:
            JournalStatusBanner(
                state: .draft,
                title: "\(scopePrefix)已写 · 尚未推送 Tita",
                detail: "正文已保存在本地，核对四模块后即可提交。",
                palette: p,
                actionTitle: "✉️ 立即推送 Tita"
            ) {
                showTitaSubmit = true
            }
        case .completed:
            let titaInfo = model.titaStatus.map { "Tita \($0.state.displayName)" } ?? "已保存本地"
            JournalStatusBanner(
                state: .completed,
                title: "\(scopePrefix)已写",
                detail: titaInfo,
                palette: p
            )
        case .offDay:
            EmptyView()
        }
    }

    private func appendToReport(_ bullet: String) {
        let trimmed = model.reportContent.trimmingCharacters(in: .whitespacesAndNewlines)
        model.reportContent = trimmed.isEmpty ? bullet : "\(trimmed)\n\(bullet)"
        model.scheduleAutoSave()
        model.message = "已引用该条日报到右侧正文"
    }
}

// MARK: - 左页手账素材组件

private struct JournalPeriodSummaryCards: View {
    let model: WeeklyReportModel
    let palette: JournalPalette

    var body: some View {
        let projects = model.involvedProjects
        HStack(spacing: 8) {
            statCard(
                label: "累计工时",
                value: model.totalHours > 0 ? "\(WorkCalendar.hoursText(model.totalHours))h" : (model.isLoadingLogs ? "…" : "0h"),
                color: model.totalHours > 0 ? palette.ink : palette.inkTertiary
            )
            statCard(
                label: "日报覆盖",
                value: "\(model.loggedDaysCount)/\(max(model.workdayCount, model.loggedDaysCount))天",
                color: model.loggedDaysCount > 0 ? palette.stampGreen : palette.inkTertiary
            )
            statCard(
                label: "涉及项目",
                value: "\(projects.count)个",
                color: projects.isEmpty ? palette.inkTertiary : palette.ink
            )
        }
    }

    private func statCard(label: String, value: String, color: Color) -> some View {
        JournalPaperCard(palette: palette, padding: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DS.font(11))
                    .foregroundStyle(palette.inkSecondary)
                Text(value)
                    .font(DS.font(14.5, .bold).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
    }
}

private struct JournalWeekFilterStrip: View {
    let days: [DailyReportDay]
    @Binding var selectedDate: String?
    let palette: JournalPalette

    var body: some View {
        HStack(spacing: 3) {
            ForEach(days) { day in
                let selected = selectedDate == day.dateString
                let isToday = Calendar.current.isDateInToday(day.date)
                let shortWeekday = day.weekdayText.replacingOccurrences(of: "周", with: "")
                let dayNumber = Calendar.current.component(.day, from: day.date)
                let allDrafts = day.totalHours > 0 && day.items.allSatisfy(\.isDraft)

                Button {
                    selectedDate = selected ? nil : day.dateString
                } label: {
                    VStack(spacing: 2) {
                        Text(isToday ? "今" : shortWeekday)
                            .font(DS.font(10.5, selected || isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? palette.stampRed : palette.inkSecondary)
                        Text("\(dayNumber)")
                            .font(DS.font(11.5, selected ? .bold : .medium).monospacedDigit())
                            .foregroundStyle(selected ? palette.ink : palette.inkSecondary)
                        Text(day.totalHours > 0 ? "\(WorkCalendar.hoursText(day.totalHours))h" : (day.isWorkday ? "—" : "休"))
                            .font(DS.font(10, .semibold).monospacedDigit())
                            .foregroundStyle(day.totalHours > 0 ? (allDrafts ? palette.stampAmber : palette.stampGreen) : palette.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(selected ? palette.paperCard : .clear, in: .rect(cornerRadius: 7))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(palette.borderStrong)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(CN.monthDay(day.date)) \(day.weekdayText)")
            }
        }
        .padding(4)
        .background(palette.paperCard.opacity(0.85), in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border) }
    }
}

private struct JournalMonthWeekStrip: View {
    @Bindable var model: WeeklyReportModel
    let palette: JournalPalette

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)], spacing: 4) {
            ForEach(model.month.weeks) { slice in
                let selected = model.selectedWeekFilter == slice.id
                let hours = model.monthWeekSliceHours(slice)
                let hasWeekly = model.hasWeeklyReport(forSlice: slice)

                Button {
                    model.selectedWeekFilter = selected ? nil : slice.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(slice.label)
                                .font(DS.font(11.5, selected ? .bold : .medium))
                                .foregroundStyle(selected ? palette.ink : palette.inkSecondary)
                            Spacer(minLength: 2)
                            if hasWeekly {
                                Circle()
                                    .fill(palette.stampGreen)
                                    .frame(width: 5, height: 5)
                                    .help("该周已有周报")
                            }
                        }
                        Text(slice.shortRangeText)
                            .font(DS.font(10).monospacedDigit())
                            .foregroundStyle(palette.inkTertiary)
                            .lineLimit(1)
                        Text(hours > 0 ? "\(WorkCalendar.hoursText(hours))h" : "—")
                            .font(DS.font(11, .semibold).monospacedDigit())
                            .foregroundStyle(hours > 0 ? palette.stampGreen : palette.inkTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? palette.paperCard : .clear, in: .rect(cornerRadius: 7))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(palette.borderStrong)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(slice.label)（\(slice.shortRangeText)）")
            }
        }
        .padding(4)
        .background(palette.paperCard.opacity(0.85), in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border) }
    }
}

private struct JournalMonthlyGitCard: View {
    @Bindable var model: WeeklyReportModel
    let palette: JournalPalette

    var body: some View {
        let stats = model.monthGitStats
        JournalPaperCard(palette: palette, padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(DS.font(11, .semibold))
                        .foregroundStyle(palette.stampGreen)
                    Text("本月 Git 统计")
                        .font(DS.font(12, .bold))
                        .foregroundStyle(palette.ink)

                    Spacer(minLength: 4)

                    Toggle("附 Git", isOn: $model.includeGitStats)
                        .toggleStyle(.checkbox)
                        .font(DS.font(11))
                        .foregroundStyle(palette.inkSecondary)

                    Button {
                        Task { await model.refreshMonthGitStats() }
                    } label: {
                        if model.isLoadingGitStats {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(DS.font(11))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.inkSecondary)
                    .disabled(model.isLoadingGitStats)
                    .help("重新扫描本月 Git 提交统计")
                }

                if !model.includeGitStats {
                    Text("已关闭 Git 统计注入（可勾选「附 Git」启用）")
                        .font(DS.font(11))
                        .foregroundStyle(palette.inkTertiary)
                } else if model.isLoadingGitStats && !stats.hasData {
                    Text("正在扫描本地仓库本月提交…")
                        .font(DS.font(11.5))
                        .foregroundStyle(palette.inkSecondary)
                } else if !stats.hasData {
                    Text("暂未扫到本月提交，点右上角刷新可重新扫描")
                        .font(DS.font(11))
                        .foregroundStyle(palette.inkTertiary)
                } else {
                    HStack(spacing: 10) {
                        Text("净提交 \(stats.netCommits)（总 \(stats.totalCommits) / 合并 \(stats.mergeCommits)）")
                        Text("·")
                        Text("活跃 \(stats.activeRepoCount)/\(stats.totalReposScanned) 仓")
                    }
                    .font(DS.font(11.5, .medium).monospacedDigit())
                    .foregroundStyle(palette.ink)

                    HStack(spacing: 8) {
                        Text("Bug修复 \(stats.bugFixCommits)")
                        Text("·")
                        Text("接口联调 \(stats.apiIntegrationCommits)")
                        Text("·")
                        Text("部署配置 \(stats.deployConfigCommits)")
                        if let peak = stats.peakDay, stats.peakDayCommits > 0 {
                            Text("·")
                            Text("高峰 \(peak.suffix(5))(\(stats.peakDayCommits))")
                        }
                    }
                    .font(DS.font(11).monospacedDigit())
                    .foregroundStyle(palette.inkSecondary)
                    .lineLimit(1)
                }
            }
        }
    }
}

private struct JournalMonthlyOKRCard: View {
    @Bindable var model: WeeklyReportModel
    let palette: JournalPalette
    @Binding var expanded: Bool

    var body: some View {
        let trimmed = model.monthlyOKR.trimmingCharacters(in: .whitespacesAndNewlines)
        JournalPaperCard(palette: palette, padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "target")
                                .font(DS.font(12))
                                .foregroundStyle(palette.stampRed)
                            Text("本月 OKR")
                                .font(DS.font(13.5, .bold))
                                .foregroundStyle(palette.ink)
                            Text("生成月报时逐条量化对照完成度与偏差原因")
                                .font(DS.font(11.5))
                                .foregroundStyle(palette.inkTertiary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(expanded ? "收起" : "展开")
                                .font(DS.font(11.5, .medium))
                                .foregroundStyle(palette.inkSecondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if expanded && !trimmed.isEmpty {
                        Button("清空") {
                            model.monthlyOKR = ""
                            model.scheduleAutoSave()
                        }
                        .buttonStyle(.plain)
                        .font(DS.font(11.5, .medium))
                        .foregroundStyle(palette.stampRed)
                    }
                }

                if expanded {
                    ZStack(alignment: .topLeading) {
                        if model.monthlyOKR.isEmpty {
                            Text("例如：\n1. 完成固废溯源平台管理端及 APP 全量交付（目标 100%）\n2. 推进三维模型跨端鸿蒙适配与性能优化（目标完成核心场景验证）")
                                .font(DS.body)
                                .foregroundStyle(palette.inkTertiary)
                                .padding(.top, 2)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $model.monthlyOKR)
                            .font(DS.body)
                            .lineSpacing(5)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: DS.s(90), maxHeight: DS.s(170))
                            .onChange(of: model.monthlyOKR) {
                                model.scheduleAutoSave()
                            }
                    }
                    .padding(10)
                    .background(palette.paper.opacity(0.65), in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(palette.borderStrong)
                    }
                } else {
                    Text(trimmed.isEmpty ? "点击填写本月个人 OKR…" : trimmed)
                        .font(DS.font(12.5))
                        .foregroundStyle(trimmed.isEmpty ? palette.inkTertiary : palette.inkSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.18)) {
                                expanded = true
                            }
                        }
                }
            }
        }
    }
}

private struct JournalExtraNotesSticky: View {
    @Bindable var model: WeeklyReportModel
    let palette: JournalPalette
    @Binding var expanded: Bool

    var body: some View {
        let trimmed = model.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = model.periodKind == .weekly
            ? "非代码事项、会议评审、风险或下周计划，生成时自动融入"
            : "里程碑成果、跨团队协作、风险或下月计划，生成时自动融入"
        let placeholder = model.periodKind == .weekly
            ? "例如：周三参加产品评审并确定二期排期；下周重点联调导出与权限模块…"
            : "例如：本月完成核心模块上线并牵头跨团队联调；下月重点推进性能优化与新版本规划…"

        JournalStickyNote(palette: palette) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            expanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "pin.fill")
                                .font(DS.font(12))
                                .foregroundStyle(palette.stampAmber)
                            Text("补充说明便利贴")
                                .font(DS.font(13.5, .bold))
                                .foregroundStyle(palette.ink)
                            Text(hint)
                                .font(DS.font(11.5))
                                .foregroundStyle(palette.inkTertiary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(expanded ? "收起" : "展开")
                                .font(DS.font(11.5, .medium))
                                .foregroundStyle(palette.inkSecondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)

                    if expanded && !trimmed.isEmpty {
                        Button("清空") {
                            model.extraNotes = ""
                            model.scheduleAutoSave()
                        }
                        .buttonStyle(.plain)
                        .font(DS.font(11.5, .medium))
                        .foregroundStyle(palette.stampRed)
                    }
                }

                if expanded {
                    ZStack(alignment: .topLeading) {
                        if model.extraNotes.isEmpty {
                            Text(placeholder)
                                .font(DS.body)
                                .foregroundStyle(palette.inkTertiary)
                                .padding(.top, 2)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $model.extraNotes)
                            .font(DS.body)
                            .lineSpacing(5)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: DS.s(130), maxHeight: DS.s(220))
                            .onChange(of: model.extraNotes) {
                                model.scheduleAutoSave()
                            }
                    }
                    .padding(10)
                    .background(palette.paper.opacity(0.65), in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(palette.stickyBorder)
                    }
                } else {
                    Text(trimmed.isEmpty ? placeholder : trimmed)
                        .font(DS.font(12.5))
                        .foregroundStyle(trimmed.isEmpty ? palette.inkTertiary : palette.inkSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.18)) {
                                expanded = true
                            }
                        }
                }
            }
        }
    }
}

private struct JournalDailyExcerptSlip: View {
    let day: DailyReportDay
    let palette: JournalPalette
    let settings: SettingsStore
    let onInsert: (String) -> Void

    var body: some View {
        JournalPaperCard(palette: palette, paperclip: true, padding: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("\(CN.monthDay(day.date)) \(day.weekdayText)")
                        .font(DS.font(12.5, .bold))
                        .foregroundStyle(palette.ink)
                    if Calendar.current.isDateInToday(day.date) {
                        Tag("今天", color: palette.stampGreen)
                    }
                    Spacer()
                    Text("\(WorkCalendar.hoursText(day.totalHours))h")
                        .font(DS.font(12, .bold).monospacedDigit())
                        .foregroundStyle(palette.stampGreen)
                }

                ForEach(day.items) { item in
                    let isHighlighted = JournalHighlight.isHighlighted(date: day.dateString, work: item.work, in: settings)
                    let projectPrefix = (item.projectName?.isEmpty == false) ? "**\(item.projectName!)**：" : ""
                    let insertText = "- \(projectPrefix)\(item.work)"

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            if let project = item.projectName, !project.isEmpty {
                                Tag(project, color: palette.inkSecondary)
                            }
                            if item.isOvertime { Tag("加班", color: palette.stampPurple) }
                            if item.isDraft { Tag("草稿", color: palette.stampAmber) }
                            if isHighlighted { Tag("★ 重点", color: palette.stampAmber) }
                            Spacer()
                            Button("+ 引用") {
                                onInsert(insertText)
                            }
                            .buttonStyle(.plain)
                            .font(DS.font(11, .semibold))
                            .foregroundStyle(palette.stampGreen)
                            .disabled(item.work.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Text(item.work.isEmpty ? "（无工作内容说明）" : item.work)
                            .font(DS.font(12))
                            .foregroundStyle(item.work.isEmpty ? palette.inkTertiary : palette.ink)
                            .lineSpacing(3)
                            .padding(.horizontal, isHighlighted ? 4 : 0)
                            .padding(.vertical, isHighlighted ? 2 : 0)
                            .background(isHighlighted ? palette.highlightFill : .clear, in: .rect(cornerRadius: 4))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - 手账 Markdown 预览

private struct JournalMarkdownReportView: View {
    let markdown: String
    let palette: JournalPalette
    let chapterColor: Color

    private var blocks: [ReportMarkdownBlock] {
        ReportMarkdown.parseBlocks(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    if level == 2 {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(chapterColor)
                                .frame(width: 3.5, height: DS.s(16))
                            Text(ReportMarkdown.attributedInline(text))
                                .font(JournalPalette.serif(16.5, .bold))
                                .foregroundStyle(palette.ink)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    } else {
                        Text(ReportMarkdown.attributedInline(text))
                            .font(level == 1 ? JournalPalette.serif(19, .bold) : DS.font(14.5, .semibold))
                            .foregroundStyle(palette.ink)
                            .padding(.top, level == 1 ? 4 : 6)
                    }
                case .bullet(_, let indentLevel, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(DS.body.monospacedDigit())
                            .foregroundStyle(palette.inkSecondary)
                            .frame(minWidth: DS.s(18), alignment: .trailing)
                        Text(ReportMarkdown.attributedInline(text))
                            .font(DS.body)
                            .foregroundStyle(palette.ink)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(4 + indentLevel * 18))
                case .blockquote(_, let text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(palette.borderStrong)
                            .frame(width: 3)
                        Text(ReportMarkdown.attributedInline(text))
                            .font(DS.body)
                            .foregroundStyle(palette.inkSecondary)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                case .codeBlock(_, let code):
                    Text(code)
                        .font(DS.mono(12.5))
                        .foregroundStyle(palette.ink)
                        .lineSpacing(4)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.paperAlt, in: .rect(cornerRadius: 8))
                case .divider:
                    Divider()
                        .overlay(palette.borderStrong)
                        .padding(.vertical, 4)
                case .paragraph(_, let text):
                    Text(ReportMarkdown.attributedInline(text))
                        .font(DS.body)
                        .foregroundStyle(palette.ink)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 历史周报 / 月报弹层

private struct ReportHistoryPopover: View {
    let model: WeeklyReportModel
    @Binding var isPresented: Bool
    @State private var tab: ReportPeriodKind = .weekly
    @State private var syncFeedback: (isError: Bool, text: String)?

    var body: some View {
        let activeTab = model.lockedPeriodKind ?? tab
        return VStack(alignment: .leading, spacing: 0) {
            if let locked = model.lockedPeriodKind {
                let count = locked == .weekly ? model.recentReports.count : model.recentMonthlyReports.count
                HStack(spacing: 8) {
                    Text(locked == .weekly ? "历史周报" : "历史月报")
                        .font(DS.font(14, .semibold))
                    Text("共 \(count) 份")
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                    Spacer()
                    if model.isTitaConfigured {
                        syncHistoryButton(scope: locked == .weekly ? .weekly : .monthly)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 8) {
                    DSTabs(selection: $tab, options: [
                        (.weekly, "周报 (\(model.recentReports.count))"),
                        (.monthly, "月报 (\(model.recentMonthlyReports.count))"),
                    ])
                    Spacer()
                    if model.isTitaConfigured {
                        syncHistoryButton(scope: activeTab == .weekly ? .weekly : .monthly)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider().overlay(DS.border)

            if let syncFeedback {
                DSBanner(syncFeedback.isError ? .danger : .success, syncFeedback.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider().overlay(DS.border)
            }

            if activeTab == .weekly {
                weeklyList
            } else {
                monthlyList
            }
        }
        .frame(width: DS.s(376))
        .background(DS.canvas)
        .onAppear {
            tab = model.periodKind
            model.reloadSavedReportsFromStore()
        }
    }

    private func syncHistoryButton(scope: TitaSyncScope) -> some View {
        Button {
            Task {
                syncFeedback = nil
                do {
                    let result = try await model.syncTitaHistory(scope: scope, overwriteLocalEdits: false)
                    syncFeedback = (false, result.summaryText)
                } catch {
                    syncFeedback = (true, error.localizedDescription)
                }
            }
        } label: {
            if model.isSyncingTitaHistory {
                ProgressView().controlSize(.small)
            } else {
                Label("同步 Tita", systemImage: "arrow.triangle.2.circlepath")
                    .font(DS.caption)
            }
        }
        .buttonStyle(.dsGhost)
        .disabled(model.isSyncingTitaHistory)
        .help("从 Tita 拉取历史记录同步到本地数据库")
    }

    @ViewBuilder
    private var weeklyList: some View {
        if model.recentReports.isEmpty {
            emptyHistoryView("还没有保存过周报")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.recentReports.enumerated()), id: \.element.id) { index, record in
                        let isCurrent = model.periodKind == .weekly && record.weekStart == model.week.startDateString
                        historyRow(
                            title: record.title,
                            subtitle: "\(record.weekStart) ~ \(record.weekEnd) · \(WorkCalendar.hoursText(record.totalHours))h · \(record.providerName)",
                            isCurrent: isCurrent,
                            onOpen: {
                                isPresented = false
                                Task { await model.openHistoryRecord(record) }
                            },
                            onDelete: {
                                model.deleteHistoryRecord(weekStart: record.weekStart)
                            }
                        )
                        if index < model.recentReports.count - 1 {
                            Divider().overlay(DS.border).padding(.horizontal, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: DS.s(300))
        }
    }

    @ViewBuilder
    private var monthlyList: some View {
        if model.recentMonthlyReports.isEmpty {
            emptyHistoryView("还没有保存过月报")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.recentMonthlyReports.enumerated()), id: \.element.id) { index, record in
                        let isCurrent = model.periodKind == .monthly && record.monthKey == model.month.monthKey
                        historyRow(
                            title: record.title,
                            subtitle: "\(record.periodStart) ~ \(record.periodEnd) · \(WorkCalendar.hoursText(record.totalHours))h · \(record.providerName)",
                            isCurrent: isCurrent,
                            onOpen: {
                                isPresented = false
                                Task { await model.openMonthlyHistoryRecord(record) }
                            },
                            onDelete: {
                                model.deleteMonthlyHistoryRecord(monthKey: record.monthKey)
                            }
                        )
                        if index < model.recentMonthlyReports.count - 1 {
                            Divider().overlay(DS.border).padding(.horizontal, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: DS.s(300))
        }
    }

    private func emptyHistoryView(_ text: String) -> some View {
        Text(text)
            .font(DS.body)
            .foregroundStyle(DS.textTertiary)
            .frame(maxWidth: .infinity, minHeight: DS.s(120))
    }

    private func historyRow(
        title: String,
        subtitle: String,
        isCurrent: Bool,
        onOpen: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(DS.font(13, isCurrent ? .semibold : .medium))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        if isCurrent {
                            Tag("当前", color: DS.toggle)
                        }
                    }
                    Text(subtitle)
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(DS.font(12))
            }
            .buttonStyle(.dsGhost)
            .help("删除该份报告")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isCurrent ? DS.selected : .clear)
    }
}
