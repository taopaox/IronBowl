import IronBowlKit
import SwiftUI
import ZentaoLogPlugin

struct ReportView: View {
    @Bindable var model: WeeklyReportModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    @State private var showHistory = false
    @State private var dailyLogsExpanded = true
    @State private var previewMode: PreviewMode = .preview
    @State private var confirmClear = false
    @State private var showExtraNotes = false

    enum PreviewMode: Hashable {
        case preview
        case edit
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusBanners
                    overviewMetrics
                    dailyLogsSection
                    reportSection
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .background(DS.canvas)
        .task(id: model.week.startDateString) {
            model.loadLocalLogs()
            if model.isZentaoConfigured && !model.syncedFromZentao {
                await model.refreshLogs()
            }
        }
        .onDisappear {
            model.saveEditsIfNeeded()
        }
        .alert("清空本周周报？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                model.clearReport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本地保存的「\(model.week.title)」周报内容，不影响每日禅道日报。")
        }
    }

    private var headerBar: some View {
        DSPageHeader("周报", topPadding: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Button {
                        Task { await model.previousWeek() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.dsGhost)
                    .help("上一周")

                    HStack(spacing: 6) {
                        Text("\(model.week.title) · \(model.week.shortRangeText)")
                            .font(DS.font(13, .medium))
                            .monospacedDigit()
                            .foregroundStyle(DS.text)
                        if let badge = model.week.relativeBadge() {
                            Tag(badge, color: badge == "本周" ? DS.toggle : DS.textSecondary)
                        }
                    }
                    .padding(.horizontal, 8)

                    Button {
                        Task { await model.nextWeek() }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.dsGhost)
                    .help("下一周")
                }
                .padding(.horizontal, 2)
                .frame(height: DS.s(30))
                .background(DS.well, in: .rect(cornerRadius: DS.controlRadius))

                if model.week.relativeBadge() != "本周" {
                    Button("本周") {
                        Task { await model.goToCurrentWeek() }
                    }
                    .buttonStyle(.dsGhost)
                    .help("回到本周")
                }
            }
            .padding(.leading, sidebarCollapsed ? 38 : 0)
        } actions: {
            Button {
                showHistory.toggle()
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.dsSecondary)
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                WeeklyReportHistoryPopover(model: model, isPresented: $showHistory)
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
            .help("重新查询本周每日日报")
            .disabled(model.isLoadingLogs)

            DSPicker(
                selection: $model.providerKind,
                options: AIProviderKind.allCases.map {
                    DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                }
            )
            .help("选择用于生成周报的 AI")

            Button {
                Task { await model.generate() }
            } label: {
                if model.isGenerating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(DS.onPrimary)
                        Text("生成中")
                    }
                } else {
                    Label(model.hasReportContent ? "重新生成" : "生成周报", systemImage: "sparkles")
                }
            }
            .buttonStyle(.dsPrimary)
            .disabled(model.isGenerating)
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if !model.isZentaoConfigured {
            DSBanner(
                .info,
                "未配置禅道账号，当前仅查询本地已记录的日报与草稿。",
                actionTitle: "去填写禅道账号"
            ) {
                model.context.openSettings(ZentaoLogPlugin.settingsAccountID)
            }
        }
        if let remoteError = model.remoteError {
            DSBanner(.warning, "禅道日报同步失败（当前展示本地数据）：\(remoteError)")
        }
        if let error = model.errorMessage {
            DSBanner(.danger, error)
        }
        if let message = model.message {
            DSBanner(.success, message)
        }
    }

    private var overviewMetrics: some View {
        let otSuffix = model.overtimeHours > 0 ? "（含加班 \(WorkCalendar.hoursText(model.overtimeHours))h）" : ""
        let hoursDetail: String = model.totalHours > 0
            ? "正常 \(WorkCalendar.hoursText(model.normalHours))h\(otSuffix)"
            : "暂无工时记录"
        let projects = model.involvedProjects
        let projectDetail = projects.isEmpty ? "暂无涉及项目" : projects.prefix(3).joined(separator: "、") + (projects.count > 3 ? " 等" : "")
        let statusDetail: String = if let record = model.currentRecord {
            "更新于 \(CN.dateTime(record.updatedAt))"
        } else {
            "点击右上角「生成周报」"
        }

        return HStack(spacing: 12) {
            DSMetric(
                "本周工时",
                value: model.totalHours > 0 ? "\(WorkCalendar.hoursText(model.totalHours)) h" : (model.isLoadingLogs ? "查询中" : "0 h"),
                detail: hoursDetail,
                valueColor: model.totalHours > 0 ? DS.text : DS.textTertiary
            )
            DSMetric(
                "日报覆盖",
                value: "\(model.loggedDaysCount) 天",
                detail: model.totalLogCount > 0 ? "共 \(model.totalLogCount) 条日报" : "未查到日报",
                valueColor: model.loggedDaysCount > 0 ? DS.success : DS.textTertiary
            )
            DSMetric(
                "涉及项目",
                value: "\(projects.count) 个",
                detail: projectDetail,
                valueColor: projects.isEmpty ? DS.textTertiary : DS.text
            )
            DSMetric(
                "周报状态",
                value: model.hasReportContent ? "已生成" : "未生成",
                detail: statusDetail,
                valueColor: model.hasReportContent ? DS.success : DS.warning
            )
        }
    }

    private var dailyLogsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        dailyLogsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: dailyLogsExpanded ? "chevron.down" : "chevron.right")
                            .font(DS.font(11, .semibold))
                            .foregroundStyle(DS.textTertiary)
                        Text("本周每日日报")
                            .font(DS.font(15, .semibold))
                            .foregroundStyle(DS.text)
                        if model.totalLogCount > 0 {
                            Text("\(model.loggedDaysCount) 天 · \(model.totalLogCount) 条")
                                .font(DS.caption.monospacedDigit())
                                .foregroundStyle(DS.textSecondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if model.syncedFromZentao {
                    Tag("已同步禅道", color: DS.success)
                } else if model.isLoadingLogs {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("正在查询禅道…")
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }

                Spacer()

                Toggle("包含未提交草稿", isOn: $model.includeDrafts)
                    .toggleStyle(.checkbox)
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)

                Button("去写禅道日志") {
                    model.context.openPlugin(ZentaoLogPlugin.pluginID)
                }
                .buttonStyle(.dsGhost)
            }

            if dailyLogsExpanded {
                WeekDayStrip(days: model.days, selectedDate: $model.selectedDayFilter)

                if model.totalLogCount == 0 {
                    DSCard {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.isLoadingLogs ? "正在查询 \(model.week.rangeText) 的每日日报…" : "\(model.week.rangeText) 暂未查到每日日报")
                                    .font(DS.rowTitle)
                                Text("可先到「禅道日志」补全每日日报，或展开下方「补充说明」直接填写要点后生成周报。")
                                    .font(DS.caption)
                                    .foregroundStyle(DS.textSecondary)
                            }
                            Spacer()
                            if model.isLoadingLogs {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("重新查询") {
                                    Task { await model.refreshLogs() }
                                }
                                .buttonStyle(.dsSecondary)
                                Button("去写日报") {
                                    model.context.openPlugin(ZentaoLogPlugin.pluginID)
                                }
                                .buttonStyle(.dsSecondary)
                            }
                        }
                    }
                } else if model.filteredDays.isEmpty {
                    DSCard {
                        HStack {
                            Text("所选日期当天没有日报记录")
                                .font(DS.body)
                                .foregroundStyle(DS.textSecondary)
                            Spacer()
                            Button("查看全周") {
                                model.selectedDayFilter = nil
                            }
                            .buttonStyle(.dsSecondary)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.filteredDays) { day in
                            DailyReportDayCard(day: day)
                        }
                    }
                }
            }
        }
    }

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("周报正文")
                    .font(DS.font(15, .semibold))
                    .foregroundStyle(DS.text)

                DSTabs(selection: $previewMode, options: [
                    (.preview, "预览"),
                    (.edit, "编辑"),
                ])

                DSPicker(
                    selection: $model.style,
                    options: WeeklyReportStyle.allCases.map {
                        DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                    }
                )

                Toggle("附工时统计", isOn: $model.includeHours)
                    .toggleStyle(.checkbox)
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)

                Spacer(minLength: 8)

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

                    Button("清空") {
                        confirmClear = true
                    }
                    .buttonStyle(.dsGhost)
                }
            }

            // 补充说明（可选）
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        showExtraNotes.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showExtraNotes || !model.extraNotes.isEmpty ? "chevron.down" : "chevron.right")
                            .font(DS.font(10.5, .semibold))
                            .foregroundStyle(DS.textTertiary)
                        Text("补充说明（可选）")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                        if !model.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Tag("已填写", color: DS.toggle)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if showExtraNotes || !model.extraNotes.isEmpty {
                    TextField(
                        "补充未体现在代码提交里的事项（如需求评审、跨团队协调、下周计划等），生成周报时会自动融合",
                        text: $model.extraNotes,
                        axis: .vertical
                    )
                    .textFieldStyle(.ds)
                    .lineLimit(2...4)
                    .onChange(of: model.extraNotes) {
                        model.scheduleAutoSave()
                    }
                }
            }

            if model.hasReportContent || previewMode == .edit {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("周报标题", text: $model.reportTitle)
                        .textFieldStyle(.ds)
                        .font(DS.font(15, .semibold))
                        .onChange(of: model.reportTitle) {
                            model.scheduleAutoSave()
                        }

                    if previewMode == .preview {
                        DSCard(padding: 18) {
                            MarkdownReportPreview(markdown: model.reportContent)
                        }
                    } else {
                        DSCard(padding: 10) {
                            TextEditor(text: $model.reportContent)
                                .font(DS.mono(13.5))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 300)
                                .onChange(of: model.reportContent) {
                                    model.scheduleAutoSave()
                                }
                        }
                    }
                }
            } else {
                DSCard(padding: 20) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("尚未生成「\(model.week.title)」周报")
                                .font(DS.rowTitle)
                            Text("系统会自动汇总本周周一至周日的每日日报（含禅道已写与可选草稿），按选定风格提炼成结构化周报。")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                        Spacer()
                        Button {
                            Task { await model.generate() }
                        } label: {
                            Label("根据本周日报生成周报", systemImage: "sparkles")
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(model.isGenerating)
                    }
                }
            }
        }
    }
}

private struct WeekDayStrip: View {
    let days: [DailyReportDay]
    @Binding var selectedDate: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(days) { day in
                let selected = selectedDate == day.dateString
                let isToday = Calendar.current.isDateInToday(day.date)
                Button {
                    selectedDate = selected ? nil : day.dateString
                } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Text(isToday ? "今天" : day.weekdayText)
                                .font(DS.font(12.5, selected ? .semibold : .medium))
                            Text(CN.slash(day.date))
                                .font(DS.font(11).monospacedDigit())
                                .foregroundStyle(DS.textSecondary)
                        }
                        dayStatusLabel(day)
                    }
                    .foregroundStyle(selected ? DS.text : DS.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.s(46))
                    .background(selected ? DS.card : .clear, in: .rect(cornerRadius: 8))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(DS.borderStrong)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(DS.well, in: .rect(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(DS.border) }
    }

    @ViewBuilder
    private func dayStatusLabel(_ day: DailyReportDay) -> some View {
        if day.totalHours > 0 {
            HStack(spacing: 3) {
                Image(systemName: day.hasDrafts && day.items.allSatisfy(\.isDraft) ? "doc.text" : "checkmark.circle.fill")
                Text("\(WorkCalendar.hoursText(day.totalHours))h").monospacedDigit()
            }
            .font(DS.font(11.5, .semibold))
            .foregroundStyle(day.items.allSatisfy(\.isDraft) ? DS.brand : DS.success)
        } else if !day.isWorkday {
            Text(day.holidayName.map { String($0.prefix(3)) } ?? "休息")
                .font(DS.font(11))
                .foregroundStyle(DS.textTertiary)
        } else {
            Text("无记录")
                .font(DS.font(11))
                .foregroundStyle(DS.textTertiary)
        }
    }
}

private struct DailyReportDayCard: View {
    let day: DailyReportDay

    var body: some View {
        DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("\(CN.monthDay(day.date)) \(day.weekdayText)")
                        .font(DS.rowTitle)
                    if Calendar.current.isDateInToday(day.date) {
                        Tag("今天", color: DS.toggle)
                    }
                    if !day.isWorkday {
                        Tag(day.holidayName ?? "休息日", color: DS.danger)
                    }
                    Spacer()
                    Text("\(day.items.count) 条 · \(WorkCalendar.hoursText(day.totalHours)) h")
                        .font(DS.caption.monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                }

                VStack(spacing: 8) {
                    ForEach(day.items) { item in
                        DailyReportItemRow(item: item)
                    }
                }
            }
        }
    }
}

private struct DailyReportItemRow: View {
    let item: DailyLogItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let project = item.projectName, !project.isEmpty {
                        Tag(project, color: DS.textSecondary)
                    }
                    if let taskTitle = item.taskTitle, !taskTitle.isEmpty {
                        Text(item.taskID.map { "#\($0) \(taskTitle)" } ?? taskTitle)
                            .font(DS.font(12.5, .medium))
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    } else if let taskID = item.taskID {
                        Text("#\(taskID)")
                            .font(DS.font(12.5, .medium))
                            .foregroundStyle(DS.textSecondary)
                    }
                    if item.isOvertime {
                        Tag("加班", color: .purple)
                    }
                    if item.isDraft {
                        Tag("草稿", color: DS.brand)
                    }
                }

                Text(item.work.isEmpty ? "（无工作内容说明）" : item.work)
                    .font(DS.body)
                    .foregroundStyle(item.work.isEmpty ? DS.textTertiary : DS.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Text("\(WorkCalendar.hoursText(item.hours)) h")
                .font(DS.font(13, .semibold).monospacedDigit())
                .foregroundStyle(item.isOvertime ? .purple : (item.isDraft ? DS.brand : DS.success))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background((item.isOvertime ? Color.purple : (item.isDraft ? DS.brand : DS.success)).opacity(0.12), in: .rect(cornerRadius: 7))
        }
        .padding(10)
        .background(DS.well, in: .rect(cornerRadius: DS.controlRadius))
    }
}

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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    Text(inlineMarkdown(text))
                        .font(headingFont(level))
                        .foregroundStyle(DS.text)
                        .padding(.top, level == 1 ? 2 : 6)
                case .bullet(_, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(DS.body.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                            .frame(minWidth: DS.s(14), alignment: .trailing)
                        Text(inlineMarkdown(text))
                            .font(DS.body)
                            .foregroundStyle(DS.text)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 4)
                case .paragraph(_, let text):
                    Text(inlineMarkdown(text))
                        .font(DS.body)
                        .foregroundStyle(DS.text)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: DS.font(18, .bold)
        case 2: DS.font(15.5, .semibold)
        default: DS.font(14, .semibold)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct WeeklyReportHistoryPopover: View {
    let model: WeeklyReportModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("历史周报")
                    .font(DS.font(14, .semibold))
                Spacer()
                Text("共 \(model.recentReports.count) 份")
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(DS.border)

            if model.recentReports.isEmpty {
                Text("还没有保存过周报")
                    .font(DS.body)
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: DS.s(120))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.recentReports.enumerated()), id: \.element.id) { index, record in
                            let isCurrent = record.weekStart == model.week.startDateString
                            HStack(spacing: 10) {
                                Button {
                                    isPresented = false
                                    Task { await model.openHistoryRecord(record) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(record.title)
                                                .font(DS.font(13, isCurrent ? .semibold : .medium))
                                                .foregroundStyle(DS.text)
                                                .lineLimit(1)
                                            if isCurrent {
                                                Tag("当前", color: DS.toggle)
                                            }
                                        }
                                        Text("\(record.weekStart) ~ \(record.weekEnd) · \(WorkCalendar.hoursText(record.totalHours))h · \(record.providerName)")
                                            .font(DS.font(11.5))
                                            .foregroundStyle(DS.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model.deleteHistoryRecord(weekStart: record.weekStart)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(DS.font(12))
                                }
                                .buttonStyle(.dsGhost)
                                .help("删除该周周报")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(isCurrent ? DS.selected : .clear)

                            if index < model.recentReports.count - 1 {
                                Divider().overlay(DS.border).padding(.horizontal, 14)
                            }
                        }
                    }
                }
                .frame(maxHeight: DS.s(300))
            }
        }
        .frame(width: DS.s(360))
        .background(DS.canvas)
    }
}
