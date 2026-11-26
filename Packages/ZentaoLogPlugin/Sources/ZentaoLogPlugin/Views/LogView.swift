import IronBowlKit
import SwiftUI

struct LogView: View {
    @Bindable var model: LogModel
    @State private var showOvertime = false
    @State private var confirmSubmit = false
    @State private var stampToken = 0

    private var palette: JournalPalette {
        JournalPalette(preset: model.settings[JournalKeys.paperPreset])
    }

    private var dailyStatusState: JournalStatusState {
        let dayInfo = model.context.workCalendar.dayInfo(model.date)
        if !dayInfo.isWorkday && model.targetHours <= 0 && model.drafts.isEmpty {
            return .offDay
        }
        if model.recordedHours == 0 && model.pendingDrafts.isEmpty {
            return .unwritten
        }
        if !model.pendingDrafts.isEmpty || model.remainingTargetHours > 0 {
            return .draft
        }
        return .completed
    }

    private var dailyStatusBadgeText: String {
        let isToday = Calendar.current.isDateInToday(model.date)
        switch dailyStatusState {
        case .offDay:
            return "休息日"
        case .unwritten:
            return isToday ? "今日未写" : "\(CN.monthDay(model.date))未写"
        case .draft:
            if !model.pendingDrafts.isEmpty {
                return "草稿待交"
            }
            return "还差 \(hoursText(model.remainingTargetHours))h"
        case .completed:
            return isToday ? "今日已写" : "已写满"
        }
    }

    var body: some View {
        Group {
            if model.isConfigured {
                JournalSpreadShell(
                    chapter: .daily,
                    settings: model.settings,
                    statusState: dailyStatusState,
                    statusBadgeText: dailyStatusBadgeText,
                    showHistoryTab: false,
                    onSelectChapter: { chapter in
                        switch chapter {
                        case .daily:
                            break
                        case .weekly:
                            model.context.openPlugin("report")
                        case .monthly:
                            model.context.openPlugin("report.monthly")
                        }
                    }
                ) {
                    headerActions
                } leftPage: {
                    leftJournalPage
                } rightPage: {
                    rightJournalPage
                }
            } else {
                notConfigured
            }
        }
        .task {
            if model.lastScan == nil || model.settings[LogKeys.scanMode] != .manualOnly {
                await model.refresh()
            }
        }
        .sheet(isPresented: $showOvertime) { OvertimeSheet(model: model) }
        .alert("盖章提交到禅道？", isPresented: $confirmSubmit) {
            Button("确认提交 \(model.pendingDrafts.count) 条") {
                Task {
                    await model.submit()
                    stampToken += 1
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(model.dateString) 共 \(hoursText(model.pendingDrafts.reduce(0) { $0 + $1.hours })) 小时，将逐条写入禅道任务工时并回查确认。")
        }
    }

    private var notConfigured: some View {
        let p = palette
        return ZStack(alignment: .top) {
            p.desk.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "book.closed")
                    .font(DS.font(32))
                    .foregroundStyle(p.stampRed)
                Text("先连上禅道，开启每日手账")
                    .font(JournalPalette.serif(20, .bold))
                    .foregroundStyle(p.ink)
                Text("填写禅道地址、账号和密码后，就能从 Git 提交自动生成草稿并盖章写入工时。")
                    .font(DS.body)
                    .foregroundStyle(p.inkSecondary)
                    .multilineTextAlignment(.center)
                Button("去填写禅道账号") {
                    model.context.openSettings(ZentaoLogPlugin.settingsAccountID)
                }
                .buttonStyle(.journalPrimary(tint: p.stampRed))
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(p.paper, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(p.borderStrong) }
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            WindowTitleBarArea(height: 52)
        }
    }

    // MARK: - 顶栏右侧操作

    @ViewBuilder
    private var headerActions: some View {
        let p = palette
        Button {
            Task { await model.refresh() }
        } label: {
            if model.isScanning || model.isLoadingTasks {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.journalSecondary(p))
        .help("重新扫描提交、拉取禅道任务")

        DSPicker(
            selection: $model.providerKind,
            options: AIProviderKind.allCases.map {
                DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
            }
        )
        .help("选择生成草稿的 AI")

        Button("记加班") { showOvertime = true }
            .buttonStyle(.journalSecondary(p))
    }

    // MARK: - 左页：撕历、7 天圆环、工时与 Git 小票

    @ViewBuilder
    private var leftJournalPage: some View {
        let p = palette
        let dayInfo = model.context.workCalendar.dayInfo(model.date)
        let dayNumber = Calendar.current.component(.day, from: model.date)
        let ymText = "\(Calendar.current.component(.year, from: model.date))年\(Calendar.current.component(.month, from: model.date))月"
        let isToday = Calendar.current.isDateInToday(model.date)
        let remaining = model.remainingTargetHours

        // 1. 手账撕历头
        HStack(alignment: .center, spacing: 10) {
            Text("\(dayNumber)")
                .font(JournalPalette.serif(36, .heavy))
                .monospacedDigit()
                .foregroundStyle(p.stampRed)
                .frame(minWidth: DS.s(44), alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("\(ymText) · \(CN.weekdayShort(model.date))")
                        .font(DS.font(13.5, .bold))
                        .foregroundStyle(p.ink)
                    if isToday {
                        Tag("今天", color: p.stampGreen)
                    }
                }
                let dayTag = dayInfo.isWorkday ? "工作日" : (dayInfo.name ?? "休息日")
                let offText = dayInfo.isWorkday ? (model.context.workCalendar.offWorkTimeText(on: model.date).map { "\($0) 下班" } ?? "") : ""
                Text(offText.isEmpty ? dayTag : "\(dayTag) · \(offText)")
                    .font(DS.font(11.5))
                    .foregroundStyle(p.inkSecondary)
            }

            Spacer(minLength: 4)

            if model.targetHours > 0 {
                Tag(
                    remaining > 0 ? "还差 \(hoursText(remaining))h" : "已满 ✓",
                    color: remaining > 0 ? p.stampRed : p.stampGreen
                )
            } else {
                Tag("休息", color: p.inkTertiary)
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(p.borderStrong).frame(height: 1)
        }

        // 2. 7 天圆环打卡条
        JournalDayRingStrip(model: model, palette: p)

        // 3. 工时刻度与加班卡
        JournalWorkHoursCard(model: model, palette: p)

        // 4. Git 提交小票
        let commitCount = model.activities.reduce(0) { $0 + $1.commits.count }
        HStack(spacing: 6) {
            Text("Git 提交小票（\(commitCount)）")
                .font(DS.font(12.5, .bold))
                .foregroundStyle(p.ink)
            Spacer()
            if let lastScan = model.lastScan {
                Text("扫描于 \(CN.time(lastScan))")
                    .font(DS.font(11))
                    .foregroundStyle(p.inkTertiary)
            }
        }
        .padding(.top, 2)

        let unmapped = model.activities.filter { model.mappings[$0.repoPath]?.projectID == nil }
        if !unmapped.isEmpty {
            DSBanner(
                .warning,
                "\(unmapped.map(\.repoName).joined(separator: "、")) 还没关联禅道项目，AI 会记到兜底任务",
                actionTitle: "去关联"
            ) {
                model.context.openSettings(ZentaoLogPlugin.settingsReposID)
            }
        }

        if model.activities.isEmpty {
            JournalPaperCard(palette: p, paperclip: true) {
                Text(model.isScanning ? "正在扫描本地 Git 提交…" : "这一天没有扫描到提交，可以在右页直接手写。")
                    .font(DS.font(12.5))
                    .foregroundStyle(p.inkSecondary)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(model.activities) { act in
                    JournalCommitSlipCard(model: model, activity: act, palette: p)
                }
            }
        }
    }

    // MARK: - 右页：印章、主操作栏、草稿手写与已入账归档

    @ViewBuilder
    private var rightJournalPage: some View {
        let p = palette
        let pendingHours = model.pendingDrafts.reduce(0) { $0 + $1.hours }
        let stampInfo: (text: String, tone: JournalStampBadge.Tone) = {
            if !model.pendingDrafts.isEmpty {
                return ("待交禅道 · \(hoursText(pendingHours))h", .pending)
            }
            if model.recordedHours > 0 {
                if model.remainingTargetHours > 0 {
                    return ("还差 \(hoursText(model.remainingTargetHours))h", .draft)
                }
                return ("禅道已入账 · \(hoursText(model.recordedHours))h", .done)
            }
            if model.targetHours <= 0 {
                return ("休息日", .neutral)
            }
            return ("今日待填报", .pending)
        }()

        // 页头 + 印章
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(CN.monthDay(model.date)) · 禅道手账")
                    .font(JournalPalette.serif(21, .bold))
                    .foregroundStyle(p.ink)
                Text("目标 \(hoursText(model.targetHours))h · 已写入 \(hoursText(model.recordedHours))h · 草稿 \(hoursText(pendingHours))h")
                    .font(DS.font(12).monospacedDigit())
                    .foregroundStyle(p.inkSecondary)
            }
            Spacer(minLength: 8)
            JournalStampBadge(stampInfo.text, tone: stampInfo.tone, palette: p, animationToken: stampToken)
        }

        // 单一聚焦操作栏
        HStack(spacing: 8) {
            Button {
                Task { await model.generate() }
            } label: {
                if model.isGenerating {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("生成中")
                    }
                } else {
                    Label("生成草稿", systemImage: "sparkles")
                }
            }
            .buttonStyle(.journalSecondary(p))
            .disabled(model.isGenerating)

            Button {
                model.addManual()
            } label: {
                Label("手写一条", systemImage: "plus")
            }
            .buttonStyle(.journalSecondary(p))

            Spacer(minLength: 4)

            Button {
                confirmSubmit = true
            } label: {
                if model.isSubmitting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("写入中…")
                    }
                } else {
                    Label(
                        model.pendingDrafts.isEmpty ? "提交到禅道" : "盖章提交禅道 (\(hoursText(pendingHours))h)",
                        systemImage: "checkmark.seal.fill"
                    )
                }
            }
            .buttonStyle(.journalPrimary(tint: p.stampRed))
            .disabled(model.pendingDrafts.isEmpty || model.isSubmitting)
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(p.border).frame(height: 1)
        }

        if let error = model.errorMessage { DSBanner(.danger, error) }
        if let message = model.message { DSBanner(.success, message) }

        dailyStatusBanner(palette: p, pendingHours: pendingHours)

        if model.drafts.isEmpty {
            let isUnwritten = dailyStatusState == .unwritten
            let emptyAccent = isUnwritten ? p.stampRed : p.borderStrong
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: isUnwritten ? "square.and.pencil" : "cup.and.saucer")
                        .font(DS.font(18, .semibold))
                        .foregroundStyle(isUnwritten ? p.stampRed : p.inkSecondary)
                    Text(model.isLoadingRecorded
                        ? "正在同步禅道工时记录…"
                        : (isUnwritten ? "\(dailyStatusBadgeText)，先生成或手写一条吧" : "今天是休息日，暂无需填报"))
                        .font(JournalPalette.serif(16, .bold))
                        .foregroundStyle(isUnwritten ? p.stampRed : p.ink)
                }
                Text(model.plannedOvertimeHours > 0 && model.baseWorkHours > 0
                    ? "点击「生成草稿」将按正常 \(hoursText(model.baseWorkHours))h 与加班 \(hoursText(model.plannedOvertimeHours))h 分别拆条生成。"
                    : "可以点击「生成草稿」、从左侧 Git 小票摘录，或「手写一条」直接记录。")
                    .font(DS.font(12.5))
                    .foregroundStyle(p.inkSecondary)
                HStack(spacing: 8) {
                    Button("✨ 生成草稿") { Task { await model.generate() } }
                        .buttonStyle(.journalPrimary(tint: isUnwritten ? p.stampRed : p.inkSecondary))
                        .disabled(model.isGenerating)
                    Button("+ 手写一条") { model.addManual() }
                        .buttonStyle(.journalSecondary(p))
                }
                .padding(.top, 2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUnwritten ? p.stampRed.opacity(0.04) : p.paperCard, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(emptyAccent.opacity(isUnwritten ? 0.55 : 1), style: StrokeStyle(lineWidth: 1.4, dash: [6, 4]))
            }
        } else {
            if !model.pendingDrafts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("待提交草稿")
                            .font(DS.font(13.5, .bold))
                            .foregroundStyle(p.stampAmber)
                        Text("· \(model.pendingDrafts.count) 条 · 用荧光笔标重点可在周报自动高亮")
                            .font(DS.font(12))
                            .foregroundStyle(p.inkSecondary)
                    }

                    ForEach($model.drafts) { $entry in
                        if !$entry.wrappedValue.isRecorded {
                            JournalDraftCard(model: model, entry: $entry, palette: p) {
                                model.removeDraft(id: entry.id)
                            }
                        }
                    }
                }
            }

            if !model.recordedDrafts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(p.stampGreen)
                        Text("已入账禅道")
                            .font(DS.font(13.5, .bold))
                            .foregroundStyle(p.ink)
                        Text("· \(model.recordedDrafts.count) 条 · 共 \(hoursText(model.recordedHours))h")
                            .font(DS.font(12).monospacedDigit())
                            .foregroundStyle(p.stampGreen)
                    }

                    ForEach(model.recordedDrafts) { entry in
                        JournalRecordedCard(model: model, entry: entry, palette: p)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dailyStatusBanner(palette p: JournalPalette, pendingHours: Double) -> some View {
        let isToday = Calendar.current.isDateInToday(model.date)
        let commitCount = model.activities.reduce(0) { $0 + $1.commits.count }
        let dayLabel = isToday ? "今日" : CN.monthDay(model.date)

        switch dailyStatusState {
        case .unwritten:
            JournalStatusBanner(
                state: .unwritten,
                title: "\(dayLabel)未写 · 需填 \(hoursText(model.targetHours))h",
                detail: commitCount > 0 ? "已扫描到 \(commitCount) 次 Git 提交，点右侧一键生成草稿。" : "暂未扫描到提交，可点左侧或上方手写记录。",
                palette: p,
                actionTitle: "✨ 立即生成草稿",
                actionDisabled: model.isGenerating
            ) {
                Task { await model.generate() }
            }
        case .draft:
            if !model.pendingDrafts.isEmpty {
                JournalStatusBanner(
                    state: .draft,
                    title: "\(dayLabel)有 \(model.pendingDrafts.count) 条草稿待提交（\(hoursText(pendingHours))h）",
                    detail: model.recordedHours > 0 ? "已写 \(hoursText(model.recordedHours))h，提交后即可完成目标 \(hoursText(model.targetHours))h。" : "核对工作内容后即可盖章写入禅道。",
                    palette: p,
                    actionTitle: "盖章提交禅道",
                    actionDisabled: model.isSubmitting
                ) {
                    confirmSubmit = true
                }
            } else {
                JournalStatusBanner(
                    state: .draft,
                    title: "\(dayLabel)已写 \(hoursText(model.recordedHours))h · 还差 \(hoursText(model.remainingTargetHours))h",
                    detail: "未达到当日目标 \(hoursText(model.targetHours))h，可继续补全草稿或记加班。",
                    palette: p,
                    actionTitle: "✨ 补全草稿",
                    actionDisabled: model.isGenerating
                ) {
                    Task { await model.generate() }
                }
            }
        case .completed:
            JournalStatusBanner(
                state: .completed,
                title: "\(dayLabel)已写满 \(hoursText(model.recordedHours))h",
                detail: "全部工时已入账禅道",
                palette: p
            )
        case .offDay:
            JournalStatusBanner(
                state: .offDay,
                title: "休息日 · 默认无需填报",
                detail: "如需记录加班，请在左页点击 +1h ~ +4h",
                palette: p
            )
        }
    }
}

func hoursText(_ h: Double) -> String {
    h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h)
}

// MARK: - 7 天圆环打卡条

private struct JournalDayRingStrip: View {
    let model: LogModel
    let palette: JournalPalette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.recentDays, id: \.self) { day in
                let info = model.context.workCalendar.dayInfo(day)
                let selected = Calendar.current.isDate(day, inSameDayAs: model.date)
                let recordedH = model.recordedHours(on: day)
                let pendingH = model.pendingHours(on: day)
                let overtimeH = model.overtimeHours(on: day)
                let targetH = model.targetHours(on: day)
                let isToday = Calendar.current.isDateInToday(day)
                let dayNum = Calendar.current.component(.day, from: day)

                let ring: (symbol: String, color: Color) = {
                    if pendingH > 0 { return ("•", palette.stampAmber) }
                    if recordedH > 0 && recordedH >= max(targetH, 0.1) { return ("✓", palette.stampGreen) }
                    if recordedH > 0 { return ("◐", palette.stampAmber) }
                    if overtimeH > 0 { return ("月", palette.stampPurple) }
                    if !info.isWorkday { return ("休", palette.inkTertiary) }
                    return ("!", palette.stampRed)
                }()

                Button {
                    Task { await model.select(date: day) }
                } label: {
                    VStack(spacing: 3) {
                        Text(isToday ? "今" : CN.weekdayShort(day).replacingOccurrences(of: "周", with: ""))
                            .font(DS.font(10.5, selected || isToday ? .bold : .medium))
                            .foregroundStyle(isToday ? palette.stampRed : palette.inkSecondary)

                        ZStack {
                            Circle()
                                .fill(ring.color.opacity(0.12))
                            Circle()
                                .strokeBorder(ring.color, lineWidth: selected ? 2 : 1.4)
                            Text(ring.symbol)
                                .font(DS.font(10, .bold))
                                .foregroundStyle(ring.color)
                        }
                        .frame(width: DS.s(22), height: DS.s(22))

                        Text("\(dayNum)")
                            .font(DS.font(10).monospacedDigit())
                            .foregroundStyle(selected ? palette.ink : palette.inkTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(selected ? palette.paperCard : .clear, in: .rect(cornerRadius: 8))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(palette.borderStrong)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("\(CN.monthDay(day)) \(CN.weekdayShort(day))")
            }
        }
        .padding(4)
        .background(palette.paperCard.opacity(0.85), in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border) }
    }
}

// MARK: - 工时刻度与快捷加班卡

private struct JournalWorkHoursCard: View {
    @Bindable var model: LogModel
    let palette: JournalPalette
    private let presets: [Double] = [1, 2, 3, 4]

    var body: some View {
        let dayInfo = model.context.workCalendar.dayInfo(model.date)
        let recorded = model.recordedHours
        let pendingNormal = model.pendingDrafts.filter { !$0.isOvertime }.reduce(0) { $0 + $1.hours }
        let pendingOT = model.pendingDrafts.filter(\.isOvertime).reduce(0) { $0 + $1.hours }
        let pendingTotal = pendingNormal + pendingOT
        let target = model.targetHours

        JournalPaperCard(palette: palette) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("工时刻度")
                        .font(DS.font(12, .bold))
                        .foregroundStyle(palette.inkSecondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("已记 \(hoursText(recorded))h")
                            .foregroundStyle(palette.stampGreen)
                        if pendingTotal > 0 {
                            Text("+ 草稿 \(hoursText(pendingTotal))h")
                                .foregroundStyle(palette.stampAmber)
                        }
                        Text("/ 目标 \(hoursText(target))h")
                            .foregroundStyle(palette.ink)
                    }
                    .font(DS.font(12, .bold).monospacedDigit())
                }

                JournalProgressBar(
                    recorded: recorded,
                    draftNormal: pendingNormal,
                    draftOvertime: pendingOT,
                    target: target,
                    palette: palette
                )

                HStack(spacing: 5) {
                    Text("加班")
                        .font(DS.font(11.5, .medium))
                        .foregroundStyle(palette.inkSecondary)

                    ForEach(presets, id: \.self) { h in
                        let active = abs(model.plannedOvertimeHours - h) < 0.01
                        Button("+\(hoursText(h))h") {
                            model.toggleOvertimeHours(h)
                        }
                        .buttonStyle(.plain)
                        .font(DS.font(11.5, active ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(active ? palette.stampPurple : palette.ink)
                        .padding(.horizontal, 8)
                        .frame(height: DS.s(24))
                        .background(active ? palette.stampPurple.opacity(0.14) : palette.paperAlt, in: .capsule)
                        .overlay {
                            Capsule().strokeBorder(active ? palette.stampPurple : palette.borderStrong)
                        }
                    }

                    Spacer(minLength: 2)

                    if model.plannedOvertimeHours > 0 {
                        Button("清除") {
                            model.plannedOvertimeHours = 0
                        }
                        .buttonStyle(.plain)
                        .font(DS.font(11.5))
                        .foregroundStyle(palette.inkTertiary)
                    }
                }

                if !dayInfo.isWorkday && model.plannedOvertimeHours <= 0 {
                    Text("休息日默认目标 0h；如需填报加班，点上方 +1h~+4h 或右上角「记加班」。")
                        .font(DS.font(11))
                        .foregroundStyle(palette.inkTertiary)
                }
            }
        }
    }
}

// MARK: - 回形针 Git 提交小票

private struct JournalCommitSlipCard: View {
    let model: LogModel
    let activity: RepoActivity
    let palette: JournalPalette

    var body: some View {
        JournalPaperCard(palette: palette, paperclip: true, padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(activity.repoName)
                        .font(DS.font(12.5, .bold))
                        .foregroundStyle(palette.ink)
                    if let m = model.mappings[activity.repoPath], m.projectID != nil {
                        Tag(m.projectName, color: palette.inkSecondary)
                    } else {
                        Tag("未关联项目", color: palette.stampAmber)
                    }
                    Spacer()
                    Text("\(activity.commits.count) 次")
                        .font(DS.font(11))
                        .foregroundStyle(palette.inkTertiary)
                }

                ForEach(activity.commits) { commit in
                    HStack(alignment: .top, spacing: 6) {
                        Text(CN.time(commit.date))
                            .font(DS.font(11).monospacedDigit())
                            .foregroundStyle(palette.inkTertiary)
                            .frame(width: 36, alignment: .leading)
                        Text(commit.subject)
                            .font(DS.font(12))
                            .foregroundStyle(palette.ink)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("+ 摘录") {
                            model.addDraftFromCommit(activity: activity, commit: commit)
                        }
                        .buttonStyle(.plain)
                        .font(DS.font(11, .semibold))
                        .foregroundStyle(palette.stampRed)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.stampRed.opacity(0.10), in: .rect(cornerRadius: 5))
                        .help("摘录为右页待提交草稿")
                    }
                }
            }
        }
    }
}

// MARK: - 右页草稿卡与已入账卡

private struct JournalDraftCard: View {
    let model: LogModel
    @Binding var entry: DraftEntry
    let palette: JournalPalette
    let onDelete: () -> Void

    private var isHighlighted: Bool {
        JournalHighlight.isHighlighted(date: model.dateString, work: entry.work, in: model.settings)
    }

    var body: some View {
        let accent = entry.isOvertime ? palette.stampPurple : palette.stampAmber
        JournalPaperCard(palette: palette, accent: accent, highlighted: isHighlighted) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    DSPicker(selection: $entry.taskID, options: taskOptions, width: 240)
                        .onChange(of: entry.taskID) { recompute() }
                    if entry.isFallback { Tag("兜底", color: palette.stampAmber) }
                    if entry.isOvertime { Tag("加班", color: palette.stampPurple) }
                    if entry.isManual { Tag("手写", color: palette.inkSecondary) }
                    Spacer(minLength: 4)

                    Button {
                        JournalHighlight.toggle(date: model.dateString, work: entry.work, in: model.settings)
                    } label: {
                        Label(isHighlighted ? "已标重点" : "标重点", systemImage: "highlighter")
                            .font(DS.font(11.5, .semibold))
                            .foregroundStyle(isHighlighted ? palette.stampAmber : palette.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isHighlighted ? palette.highlightFill : palette.paperAlt,
                                in: .rect(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.work.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("用荧光笔标重点，周报/月报将自动高亮显示")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(DS.font(12))
                            .foregroundStyle(palette.stampRed)
                    }
                    .buttonStyle(.plain)
                    .help("删除这一条")
                }

                if let task = model.task(entry.taskID) {
                    Text("\(task.projectName)" + (entry.repoPaths.isEmpty ? "" : " · " + entry.repoPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")))
                        .font(DS.font(11.5))
                        .foregroundStyle(palette.inkTertiary)
                        .lineLimit(1)
                }

                TextEditor(text: $entry.work)
                    .font(DS.font(13.5))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 68)
                    .padding(9)
                    .background(
                        isHighlighted ? palette.paper.opacity(0.65) : palette.paperAlt,
                        in: .rect(cornerRadius: 8)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border)
                    }

                HStack(spacing: 10) {
                    Text("消耗")
                        .font(DS.font(12))
                        .foregroundStyle(palette.inkSecondary)
                    DSStepper(value: $entry.hours, in: 0...24, step: 0.5) { "\(hoursText($0)) h" }
                        .onChange(of: entry.hours) { recompute() }

                    Text("剩余")
                        .font(DS.font(12))
                        .foregroundStyle(palette.inkSecondary)
                    TextField("", value: $entry.left, format: .number)
                        .textFieldStyle(.ds)
                        .frame(width: 56)

                    Spacer()

                    Toggle("加班", isOn: $entry.isOvertime)
                        .toggleStyle(.checkbox)
                        .font(DS.font(12))
                        .foregroundStyle(palette.inkSecondary)
                }
            }
        }
    }

    private var taskOptions: [DSPickerOption<Int?>] {
        [DSPickerOption(nil, title: "选择任务…")] + model.projects.flatMap { p in
            model.openTasks.filter { $0.projectID == p.id }.map {
                DSPickerOption(
                    Int?.some($0.id),
                    title: "#\($0.id) \($0.name)",
                    subtitle: p.name,
                    triggerTitle: "\(p.name) · #\($0.id) \($0.name)"
                )
            }
        }
    }

    private func recompute() {
        if let i = model.drafts.firstIndex(where: { $0.id == entry.id }) {
            model.recomputeLeft(for: i)
        }
    }
}

private struct JournalRecordedCard: View {
    let model: LogModel
    let entry: DraftEntry
    let palette: JournalPalette

    private var accent: Color {
        entry.isOvertime ? palette.stampPurple : palette.stampGreen
    }

    private var isHighlighted: Bool {
        JournalHighlight.isHighlighted(date: model.dateString, work: entry.work, in: model.settings)
    }

    private var recordedTitle: String {
        if let task = model.task(entry.taskID) { return "#\(task.id) \(task.name)" }
        if let id = entry.taskID, let title = entry.taskTitle { return "#\(id) \(title)" }
        if let title = entry.taskTitle { return title }
        if let id = entry.taskID { return "#\(id)" }
        return "禅道日志"
    }

    var body: some View {
        let trimmed = entry.work.trimmingCharacters(in: .whitespacesAndNewlines)
        JournalPaperCard(palette: palette, accent: accent, highlighted: isHighlighted) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(trimmed.isEmpty ? "（无工作内容说明）" : trimmed)
                        .font(DS.font(14, .medium))
                        .foregroundStyle(trimmed.isEmpty ? palette.inkTertiary : palette.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, isHighlighted ? 4 : 0)
                        .background(isHighlighted ? palette.highlightFill : .clear, in: .rect(cornerRadius: 4))

                    Spacer(minLength: 8)

                    Text("\(hoursText(entry.hours))h")
                        .font(DS.font(18, .bold).monospacedDigit())
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.11), in: .rect(cornerRadius: 8))
                }

                HStack(spacing: 7) {
                    Tag("✓ 已入账", color: palette.stampGreen)
                    if entry.isOvertime { Tag("加班", color: palette.stampPurple) }
                    if entry.isFallback { Tag("兜底", color: palette.stampAmber) }
                    Text(recordedTitle)
                        .font(DS.font(12))
                        .foregroundStyle(palette.inkSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text("剩余 \(hoursText(entry.left))h")
                        .font(DS.font(11.5).monospacedDigit())
                        .foregroundStyle(palette.inkTertiary)

                    Button {
                        JournalHighlight.toggle(date: model.dateString, work: entry.work, in: model.settings)
                    } label: {
                        Image(systemName: "highlighter")
                            .font(DS.font(11.5))
                            .foregroundStyle(isHighlighted ? palette.stampAmber : palette.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty)
                    .help(isHighlighted ? "取消荧光笔重点" : "标为荧光笔重点")
                }
            }
        }
    }
}

/// 任务下拉（加班弹框用）。
struct TaskPicker: View {
    let model: LogModel
    @Binding var selection: Int?

    var body: some View {
        DSPicker(
            selection: $selection,
            options: [DSPickerOption(nil, title: "选择任务…")] + model.openTasks.map {
                DSPickerOption(
                    Int?.some($0.id),
                    title: "#\($0.id) \($0.name)",
                    subtitle: $0.projectName,
                    triggerTitle: "\($0.projectName) · #\($0.id) \($0.name)"
                )
            },
            width: 300
        )
    }
}

struct OvertimeSheet: View {
    let model: LogModel
    @Environment(\.dismiss) private var dismiss
    @State private var hours: Double = 2
    @State private var taskID: Int?
    @State private var work = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("记一笔加班").font(DS.pageTitle)
            VStack(spacing: 0) {
                DSRow("时长") { DSStepper(value: $hours, in: 0.5...12, step: 0.5) { "\(hoursText($0)) 小时" } }
                Divider().overlay(DS.border).padding(.horizontal, 16)
                DSRow("任务") { TaskPicker(model: model, selection: $taskID) }
                Divider().overlay(DS.border).padding(.horizontal, 16)
                DSBlockRow {
                    TextField("做了什么（可留空）", text: $work, axis: .vertical).textFieldStyle(.plain).font(DS.body).lineLimit(2...4)
                }
            }
            .background(DS.card, in: .rect(cornerRadius: DS.radius))
            .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.dsSecondary)
                Button("加上") {
                    model.addOvertime(hours: hours, taskID: taskID, work: work)
                    dismiss()
                }
                .buttonStyle(.dsPrimary)
                .disabled(taskID == nil)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(DS.groupBackground)
        .onAppear {
            hours = model.settings[LogKeys.overtimeDefaultHours]
            taskID = model.busiestTaskID
        }
    }
}
