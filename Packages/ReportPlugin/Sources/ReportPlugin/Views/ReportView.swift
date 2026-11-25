import IronBowlKit
import SwiftUI
import ZentaoLogPlugin

struct ReportView: View {
    @Bindable var model: WeeklyReportModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    @State private var showHistory = false
    @State private var previewMode: PreviewMode = .preview
    @State private var confirmClear = false
    @FocusState private var extraNotesFocused: Bool

    enum PreviewMode: Hashable {
        case preview
        case edit
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().overlay(DS.border)

            GeometryReader { geo in
                if geo.size.width >= 820 {
                    HStack(spacing: 0) {
                        ScrollView {
                            leftDailyLogsPane
                                .padding(20)
                        }
                        .scrollIndicators(.never)
                        .frame(width: min(380, max(320, geo.size.width * 0.36)))
                        .background(DS.sidebar)

                        Rectangle()
                            .fill(DS.border)
                            .frame(width: 1)

                        ScrollView {
                            rightReportPane
                                .padding(24)
                                .frame(maxWidth: 820, alignment: .leading)
                                .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.never)
                        .background(DS.canvas)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            rightReportPane
                            Divider().overlay(DS.border)
                            leftDailyLogsPane
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .background(DS.canvas)
                }
            }
        }
        .background(DS.canvas)
        .task(id: "\(model.periodKind.rawValue)-\(model.activePeriodKey)") {
            model.loadLocalLogs()
            if model.isZentaoConfigured && !model.syncedFromZentao {
                await model.refreshLogs()
            }
        }
        .onDisappear {
            model.saveEditsIfNeeded()
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

    // MARK: - 顶栏

    private var headerBar: some View {
        let totalHistoryCount = model.recentReports.count + model.recentMonthlyReports.count
        let periodLabel = model.periodKind == .weekly
            ? "第 \(model.week.weekOfYear) 周 · \(model.week.shortRangeText)"
            : model.month.title
        let currentBadge = model.periodKind == .weekly ? "本周" : "本月"
        let backLabel = model.periodKind == .weekly ? "回本周" : "回本月"
        let generateTitle = model.hasReportContent ? "重新生成" : "生成\(model.periodKind.displayName)"

        return HStack(spacing: 12) {
            DSTabs(
                selection: Binding(
                    get: { model.periodKind },
                    set: { next in
                        Task<Void, Never> { await model.switchPeriodKind(next) }
                    }
                ),
                options: ReportPeriodKind.allCases.map { ($0, $0.displayName) }
            )

            HStack(spacing: 2) {
                Button {
                    Task { await model.previousPeriod() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(DS.font(12, .semibold))
                }
                .buttonStyle(.dsGhost)
                .help(model.periodKind == .weekly ? "上一周" : "上一月")

                HStack(spacing: 6) {
                    Text(periodLabel)
                        .font(DS.font(13, .medium))
                        .monospacedDigit()
                        .foregroundStyle(DS.text)
                    if let badge = model.activeRelativeBadge {
                        Tag(badge, color: badge == currentBadge ? DS.toggle : DS.textSecondary)
                    }
                }
                .padding(.horizontal, 6)

                Button {
                    Task { await model.nextPeriod() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(DS.font(12, .semibold))
                }
                .buttonStyle(.dsGhost)
                .help(model.periodKind == .weekly ? "下一周" : "下一月")
            }
            .padding(.horizontal, 2)
            .frame(height: DS.s(30))
            .background(DS.well, in: .rect(cornerRadius: DS.controlRadius))
            .help("\(model.activePeriodTitle)（\(model.activePeriodRangeText)）")

            if !model.isCurrentPeriod {
                Button(backLabel) {
                    Task { await model.goToCurrentPeriod() }
                }
                .buttonStyle(.dsGhost)
                .help(model.periodKind == .weekly ? "回到本周" : "回到本月")
            }

            Spacer(minLength: 8)

            Button {
                showHistory.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    if totalHistoryCount > 0 {
                        Text("\(totalHistoryCount)")
                            .font(DS.font(12, .medium).monospacedDigit())
                    }
                }
            }
            .buttonStyle(.dsGhost)
            .help("查看历史周报与月报")
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
            .buttonStyle(.dsGhost)
            .help("重新查询每日日报")
            .disabled(model.isLoadingLogs)

            DSPicker(
                selection: $model.providerKind,
                options: AIProviderKind.allCases.map {
                    DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                }
            )
            .help("选择用于生成\(model.periodKind.displayName)的 AI")

            Button {
                Task { await model.generate() }
            } label: {
                if model.isGenerating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(DS.onPrimary)
                        Text("生成中")
                    }
                } else {
                    Label(generateTitle, systemImage: "sparkles")
                }
            }
            .buttonStyle(.dsPrimary)
            .disabled(model.isGenerating)
        }
        .padding(.leading, sidebarCollapsed ? 120 : 28)
        .padding(.trailing, 28)
        .frame(height: 52)
        .padding(.top, 8)
        .windowTitleBar()
    }

    // MARK: - 左栏：周期每日日报

    private var leftDailyLogsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            PeriodSummaryBar(model: model)

            if model.periodKind == .weekly {
                WeekDayStrip(days: model.days, selectedDate: $model.selectedDayFilter)
            } else {
                MonthWeekStrip(model: model)
            }

            HStack(spacing: 6) {
                Text("每日日报")
                    .font(DS.font(13.5, .semibold))
                    .foregroundStyle(DS.text)

                if model.syncedFromZentao {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DS.success)
                            .frame(width: 6, height: 6)
                        Text("已同步禅道")
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.textSecondary)
                    }
                } else if model.isLoadingLogs {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("同步中")
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.textTertiary)
                    }
                }

                if model.hasActiveFilter {
                    Button(model.periodKind == .weekly ? "全周" : "全月") {
                        model.clearActiveFilter()
                    }
                    .buttonStyle(.dsGhost)
                    .font(DS.caption)
                }

                Spacer(minLength: 4)

                Toggle("含草稿", isOn: $model.includeDrafts)
                    .toggleStyle(.checkbox)
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)

                Button("写日志") {
                    model.context.openPlugin(ZentaoLogPlugin.pluginID)
                }
                .buttonStyle(.dsGhost)
                .help("前往禅道日志页补充日报")
            }

            if model.totalLogCount == 0 {
                emptyLogsCard
            } else if model.filteredDays.isEmpty {
                emptyFilteredDayCard
            } else {
                VStack(spacing: 10) {
                    ForEach(model.filteredDays) { day in
                        DailyReportDayCard(day: day)
                    }
                }
            }
        }
    }

    private var emptyLogsCard: some View {
        let rangeDesc = model.periodKind == .weekly ? model.week.shortRangeText : model.month.title
        return VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(DS.font(24))
                .foregroundStyle(DS.textTertiary)
            Text(model.isLoadingLogs ? "正在查询每日日报…" : "\(rangeDesc) 暂无日报")
                .font(DS.rowTitle)
                .foregroundStyle(DS.text)
            Text("可前往禅道日志补全日报，或直接在右侧「补充说明」填写\(model.periodKind == .weekly ? "本周" : "本月")要点。")
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if model.isLoadingLogs {
                ProgressView().controlSize(.small)
                    .padding(.top, 2)
            } else {
                HStack(spacing: 8) {
                    Button("重新查询") {
                        Task { await model.refreshLogs() }
                    }
                    .buttonStyle(.dsSecondary)
                    Button("去写日报") {
                        model.context.openPlugin(ZentaoLogPlugin.pluginID)
                    }
                    .buttonStyle(.dsSecondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
    }

    private var emptyFilteredDayCard: some View {
        HStack {
            Text(model.periodKind == .weekly ? "当天没有日报记录" : "该周内没有日报记录")
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
            Spacer()
            Button(model.periodKind == .weekly ? "查看全周" : "查看全月") {
                model.clearActiveFilter()
            }
            .buttonStyle(.dsSecondary)
        }
        .padding(14)
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
    }

    // MARK: - 右栏：补充说明 + 报告正文

    private var rightReportPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBanners
            extraNotesCard
            reportDocumentCard
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

    /// 常驻展示的补充说明输入框。
    private var extraNotesCard: some View {
        let hasNotes = !model.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let placeholder = model.periodKind == .weekly
            ? "例如：周三参加产品评审并确定二期排期；下周重点联调导出与权限模块…"
            : "例如：本月完成核心模块上线并牵头跨团队联调；下月重点推进性能优化与新版本规划…"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(DS.font(13, .medium))
                    .foregroundStyle(DS.textSecondary)
                Text("补充说明")
                    .font(DS.font(13.5, .semibold))
                    .foregroundStyle(DS.text)
                Text(model.periodKind == .weekly
                    ? "非代码事项、会议评审、风险或下周计划，生成时自动融入"
                    : "里程碑成果、跨团队协作、风险或下月计划，生成时自动融入")
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hasNotes {
                    Button("清空") {
                        model.extraNotes = ""
                        model.scheduleAutoSave()
                    }
                    .buttonStyle(.dsGhost)
                    .font(DS.caption)
                }
            }

            ZStack(alignment: .topLeading) {
                if model.extraNotes.isEmpty {
                    Text(placeholder)
                        .font(DS.body)
                        .foregroundStyle(DS.textTertiary)
                        .padding(.top, 2)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.extraNotes)
                    .font(DS.body)
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .focused($extraNotesFocused)
                    .frame(minHeight: DS.s(120), maxHeight: DS.s(220))
                    .onChange(of: model.extraNotes) {
                        model.scheduleAutoSave()
                    }
            }
            .padding(10)
            .background(DS.well.opacity(0.55), in: .rect(cornerRadius: DS.controlRadius))
        }
        .padding(14)
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radius)
                .strokeBorder(extraNotesFocused ? DS.borderStrong : DS.border)
        }
    }

    /// 文档纸张式报告卡片。
    private var reportDocumentCard: some View {
        let noun = model.periodKind.displayName
        let periodLabel = model.periodKind == .weekly ? "本周" : "本月"

        return VStack(alignment: .leading, spacing: 0) {
            documentToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(DS.well.opacity(0.45))

            Rectangle()
                .fill(DS.border)
                .frame(height: 1)

            if model.hasReportContent || previewMode == .edit {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("输入\(noun)标题…", text: $model.reportTitle)
                            .textFieldStyle(.plain)
                            .font(DS.font(20, .bold))
                            .foregroundStyle(DS.text)
                            .onChange(of: model.reportTitle) {
                                model.scheduleAutoSave()
                            }

                        HStack(spacing: 8) {
                            Text(model.activePeriodRangeText)
                            if let updatedAt = model.activeUpdatedAt {
                                Text("·")
                                Text("更新于 \(CN.dateTime(updatedAt))")
                                if let providerName = model.activeProviderName, !providerName.isEmpty {
                                    Text("·")
                                    Text(providerName)
                                }
                            }
                            if model.totalHours > 0 {
                                Text("·")
                                Text("\(periodLabel)工时 \(WorkCalendar.hoursText(model.totalHours))h")
                            }
                        }
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                    }

                    Divider().overlay(DS.border)

                    if previewMode == .preview {
                        MarkdownReportPreview(markdown: model.reportContent)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $model.reportContent)
                                .font(DS.mono(13.5))
                                .lineSpacing(4)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 360)
                                .onChange(of: model.reportContent) {
                                    model.scheduleAutoSave()
                                }
                            Text("支持 Markdown 格式（# / ## / ### / 列表），修改内容将自动保存。")
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                }
                .padding(22)
            } else {
                emptyReportDocumentState
            }
        }
        .background(DS.card, in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(DS.border)
        }
    }

    private var documentToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                toolbarLeadingControls
                Spacer(minLength: 8)
                toolbarTrailingActions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    toolbarLeadingControls
                    Spacer(minLength: 0)
                }
                if model.hasReportContent {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        toolbarTrailingActions
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var toolbarLeadingControls: some View {
        DSTabs(selection: $previewMode, options: [
            (.preview, "预览"),
            (.edit, "编辑"),
        ])

        Rectangle()
            .fill(DS.borderStrong)
            .frame(width: 1, height: 16)

        DSPicker(
            selection: $model.style,
            options: WeeklyReportStyle.allCases.map {
                DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
            }
        )

        Toggle("附工时", isOn: $model.includeHours)
            .toggleStyle(.checkbox)
            .font(DS.caption)
            .foregroundStyle(DS.textSecondary)
    }

    @ViewBuilder
    private var toolbarTrailingActions: some View {
        if model.hasReportContent {
            Button {
                model.copyReport()
            } label: {
                Label(model.copied ? "已复制" : "复制", systemImage: model.copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.dsSecondary)

            Button {
                model.exportMarkdown()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.dsSecondary)

            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.dsGhost)
            .help("清空当前\(model.periodKind.displayName)")
        }
    }

    private var emptyReportDocumentState: some View {
        let noun = model.periodKind.displayName
        let periodLabel = model.periodKind == .weekly ? "本周" : "本月"
        let weeklyRefCount = model.monthWeeklySummaries.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let materialSummary: String = if model.totalLogCount > 0 {
            if model.periodKind == .monthly && weeklyRefCount > 0 {
                "已收集本月 \(model.loggedDaysCount) 天共 \(model.totalLogCount) 条日报（累计 \(WorkCalendar.hoursText(model.totalHours))h），并关联 \(weeklyRefCount) 份周报作为参考"
            } else {
                "已收集\(periodLabel) \(model.loggedDaysCount) 天共 \(model.totalLogCount) 条日报，累计 \(WorkCalendar.hoursText(model.totalHours))h"
            }
        } else {
            "\(periodLabel)暂无每日日报，可在上方填写「补充说明」后直接生成"
        }

        return VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(DS.font(24))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 50, height: 50)
                .background(DS.well, in: .rect(cornerRadius: 12))

            Text("准备好生成「\(model.activePeriodTitle)」\(noun)")
                .font(DS.font(16, .semibold))
                .foregroundStyle(DS.text)

            Text(materialSummary)
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    Task { await model.generate() }
                } label: {
                    Label("生成\(noun)", systemImage: "sparkles")
                }
                .buttonStyle(.dsSecondary)
                .disabled(model.isGenerating)

                Button("直接手写") {
                    previewMode = .edit
                }
                .buttonStyle(.dsGhost)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 左侧汇总与日报组件

private struct PeriodSummaryBar: View {
    let model: WeeklyReportModel

    var body: some View {
        let projects = model.involvedProjects
        let otSuffix = model.overtimeHours > 0 ? "+\(WorkCalendar.hoursText(model.overtimeHours))h" : nil
        let hoursDetail: String = if model.totalHours > 0 {
            otSuffix.map { "正常 \(WorkCalendar.hoursText(model.normalHours))h / 加班 \($0)" } ?? "正常工时"
        } else {
            "暂无记录"
        }
        let daysTarget = model.workdayCount > 0 ? " / \(model.workdayCount) 天" : " 天"
        let projectDetail = projects.isEmpty ? "暂无项目" : projects.joined(separator: "、")

        HStack(spacing: 0) {
            summaryColumn(
                label: "总工时",
                value: model.totalHours > 0 ? "\(WorkCalendar.hoursText(model.totalHours)) h" : (model.isLoadingLogs ? "…" : "0 h"),
                detail: hoursDetail,
                valueColor: model.totalHours > 0 ? DS.text : DS.textTertiary
            )

            Rectangle().fill(DS.border).frame(width: 1)

            summaryColumn(
                label: "日报覆盖",
                value: "\(model.loggedDaysCount)\(daysTarget)",
                detail: model.totalLogCount > 0 ? "共 \(model.totalLogCount) 条" : "暂无日报",
                valueColor: model.loggedDaysCount > 0 ? DS.success : DS.textTertiary
            )

            Rectangle().fill(DS.border).frame(width: 1)

            summaryColumn(
                label: "涉及项目",
                value: "\(projects.count) 个",
                detail: projectDetail,
                valueColor: projects.isEmpty ? DS.textTertiary : DS.text
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
    }

    private func summaryColumn(label: String, value: String, detail: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(DS.font(11.5))
                .foregroundStyle(DS.textSecondary)
            Text(value)
                .font(DS.font(16, .bold).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(detail)
                .font(DS.font(11))
                .foregroundStyle(DS.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WeekDayStrip: View {
    let days: [DailyReportDay]
    @Binding var selectedDate: String?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(days) { day in
                let selected = selectedDate == day.dateString
                let isToday = Calendar.current.isDateInToday(day.date)
                let shortWeekday = day.weekdayText.replacingOccurrences(of: "周", with: "")
                let dayNumber = Calendar.current.component(.day, from: day.date)

                Button {
                    selectedDate = selected ? nil : day.dateString
                } label: {
                    VStack(spacing: 2) {
                        Text(isToday ? "今" : shortWeekday)
                            .font(DS.font(11, selected || isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? DS.toggle : (selected ? DS.text : DS.textSecondary))
                        Text("\(dayNumber)")
                            .font(DS.font(12, selected ? .semibold : .medium).monospacedDigit())
                            .foregroundStyle(selected ? DS.text : DS.textSecondary)
                        statusIndicator(day)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.s(46))
                    .background(selected ? DS.card : .clear, in: .rect(cornerRadius: 7))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(DS.borderStrong)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(CN.monthDay(day.date)) \(day.weekdayText)")
            }
        }
        .padding(3)
        .background(DS.well, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }
    }

    @ViewBuilder
    private func statusIndicator(_ day: DailyReportDay) -> some View {
        if day.totalHours > 0 {
            let allDrafts = day.items.allSatisfy(\.isDraft)
            Text("\(WorkCalendar.hoursText(day.totalHours))h")
                .font(DS.font(10.5, .semibold).monospacedDigit())
                .foregroundStyle(allDrafts ? DS.brand : DS.success)
        } else if !day.isWorkday {
            Text(day.holidayName.map { String($0.prefix(2)) } ?? "休")
                .font(DS.font(10))
                .foregroundStyle(DS.textTertiary)
        } else {
            Text("—")
                .font(DS.font(10))
                .foregroundStyle(DS.textTertiary)
        }
    }
}

private struct MonthWeekStrip: View {
    @Bindable var model: WeeklyReportModel

    var body: some View {
        let slices = model.month.weeks
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)], spacing: 4) {
            ForEach(slices) { slice in
                let selected = model.selectedWeekFilter == slice.id
                let hours = model.monthWeekSliceHours(slice)
                let hasWeekly = model.hasWeeklyReport(forSlice: slice)

                Button {
                    model.selectedWeekFilter = selected ? nil : slice.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(slice.label)
                                .font(DS.font(11.5, selected ? .semibold : .medium))
                                .foregroundStyle(selected ? DS.text : DS.textSecondary)
                            Spacer(minLength: 2)
                            if hasWeekly {
                                Circle()
                                    .fill(DS.toggle)
                                    .frame(width: 5, height: 5)
                                    .help("该周已有周报")
                            }
                        }
                        Text(slice.shortRangeText)
                            .font(DS.font(10.5).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                        Text(hours > 0 ? "\(WorkCalendar.hoursText(hours))h" : "—")
                            .font(DS.font(11, .semibold).monospacedDigit())
                            .foregroundStyle(hours > 0 ? DS.success : DS.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? DS.card : .clear, in: .rect(cornerRadius: 7))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(DS.borderStrong)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(slice.label)（\(slice.shortRangeText)）")
            }
        }
        .padding(4)
        .background(DS.well, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }
    }
}

private struct DailyReportDayCard: View {
    let day: DailyReportDay

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("\(CN.monthDay(day.date)) \(day.weekdayText)")
                    .font(DS.font(13, .semibold))
                    .foregroundStyle(DS.text)
                if Calendar.current.isDateInToday(day.date) {
                    Tag("今天", color: DS.toggle)
                }
                if !day.isWorkday {
                    Tag(day.holidayName ?? "休息日", color: DS.danger)
                }
                Spacer()
                Text("\(WorkCalendar.hoursText(day.totalHours)) h")
                    .font(DS.font(12, .semibold).monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DS.well.opacity(0.45))

            Rectangle().fill(DS.border).frame(height: 1)

            ForEach(Array(day.items.enumerated()), id: \.element.id) { index, item in
                DailyReportItemRow(item: item)
                if index < day.items.count - 1 {
                    Divider().overlay(DS.border).padding(.horizontal, 12)
                }
            }
        }
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .clipShape(.rect(cornerRadius: DS.radius))
        .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
    }
}

private struct DailyReportItemRow: View {
    let item: DailyLogItem

    private var accentColor: Color {
        if item.isOvertime { return .purple }
        if item.isDraft { return DS.brand }
        return DS.success
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accentColor)
                .frame(width: 2.5)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let project = item.projectName, !project.isEmpty {
                        Tag(project, color: DS.textSecondary)
                    }
                    if item.isOvertime {
                        Tag("加班", color: .purple)
                    }
                    if item.isDraft {
                        Tag("草稿", color: DS.brand)
                    }
                    Spacer(minLength: 4)
                    Text("\(WorkCalendar.hoursText(item.hours))h")
                        .font(DS.font(12, .semibold).monospacedDigit())
                        .foregroundStyle(accentColor)
                }

                if let taskTitle = item.taskTitle, !taskTitle.isEmpty {
                    Text(item.taskID.map { "#\($0) \(taskTitle)" } ?? taskTitle)
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                } else if let taskID = item.taskID {
                    Text("#\(taskID)")
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.textSecondary)
                }

                Text(item.work.isEmpty ? "（无工作内容说明）" : item.work)
                    .font(DS.font(13))
                    .foregroundStyle(item.work.isEmpty ? DS.textTertiary : DS.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Markdown 预览

private struct MarkdownReportPreview: View {
    let markdown: String

    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case bullet(id: Int, marker: String, text: String)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _), .bullet(let id, _, _), .paragraph(let id, _): id
            }
        }
    }

    private var blocks: [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        var out: [Block] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                out.append(.paragraph(id: out.count, text: joined))
            }
            paragraphBuffer.removeAll()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("### ") {
                flushParagraph()
                out.append(.heading(id: out.count, level: 3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                out.append(.heading(id: out.count, level: 2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                out.append(.heading(id: out.count, level: 1, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                out.append(.bullet(id: out.count, marker: "•", text: String(line.dropFirst(2))))
            } else if let dotRange = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                flushParagraph()
                let num = line[..<dotRange.upperBound].trimmingCharacters(in: .whitespaces)
                let content = String(line[dotRange.upperBound...])
                out.append(.bullet(id: out.count, marker: num, text: content))
            } else {
                paragraphBuffer.append(line)
            }
        }
        flushParagraph()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    if level == 2 {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(DS.toggle)
                                .frame(width: 3, height: DS.s(15))
                            Text(inlineMarkdown(text))
                                .font(DS.font(16, .semibold))
                                .foregroundStyle(DS.text)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    } else {
                        Text(inlineMarkdown(text))
                            .font(level == 1 ? DS.font(18, .bold) : DS.font(14.5, .semibold))
                            .foregroundStyle(DS.text)
                            .padding(.top, level == 1 ? 4 : 6)
                    }
                case .bullet(_, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(DS.body.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                            .frame(minWidth: DS.s(18), alignment: .trailing)
                        Text(inlineMarkdown(text))
                            .font(DS.body)
                            .foregroundStyle(DS.text)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                case .paragraph(_, let text):
                    Text(inlineMarkdown(text))
                        .font(DS.body)
                        .foregroundStyle(DS.text)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - 历史周报 / 月报弹层

private struct ReportHistoryPopover: View {
    let model: WeeklyReportModel
    @Binding var isPresented: Bool
    @State private var tab: ReportPeriodKind = .weekly

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DSTabs(selection: $tab, options: [
                    (.weekly, "周报 (\(model.recentReports.count))"),
                    (.monthly, "月报 (\(model.recentMonthlyReports.count))"),
                ])
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(DS.border)

            if tab == .weekly {
                weeklyList
            } else {
                monthlyList
            }
        }
        .frame(width: DS.s(376))
        .background(DS.canvas)
        .onAppear {
            tab = model.periodKind
        }
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
