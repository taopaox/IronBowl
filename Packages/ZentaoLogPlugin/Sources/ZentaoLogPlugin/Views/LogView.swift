import IronBowlKit
import SwiftUI

struct LogView: View {
    @Bindable var model: LogModel
    @State private var showOvertime = false
    @State private var confirmSubmit = false

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("禅道日志", topPadding: 8) {
                EmptyView()
            } actions: {
                Button { Task { await model.refresh() } } label: {
                    if model.isScanning || model.isLoadingTasks { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.dsGhost)
                .help("重新扫描提交、拉取禅道任务")
                DSPicker(
                    selection: $model.providerKind,
                    options: AIProviderKind.allCases.map { DSPickerOption($0, title: $0.displayName, subtitle: $0.detail) }
                )
                    .help("这次用哪个 AI 生成")
                Button("记加班") { showOvertime = true }.buttonStyle(.dsSecondary)
                Button {
                    Task { await model.generate() }
                } label: {
                    if model.isGenerating {
                        HStack(spacing: 6) { ProgressView().controlSize(.small).tint(DS.onPrimary); Text("生成中") }
                    } else {
                        Label("生成草稿", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.dsPrimary)
                .disabled(model.isGenerating || !model.isConfigured)
            }

            if model.isConfigured {
                content
            } else {
                notConfigured
            }
        }
        .background(DS.canvas)
        .task {
            if model.lastScan == nil || model.settings[LogKeys.scanMode] != .manualOnly {
                await model.refresh()
            }
        }
        .sheet(isPresented: $showOvertime) { OvertimeSheet(model: model) }
        .alert("提交到禅道？", isPresented: $confirmSubmit) {
            Button("提交 \(model.pendingDrafts.count) 条") { Task { await model.submit() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(model.dateString) 共 \(hoursText(model.pendingDrafts.reduce(0) { $0 + $1.hours })) 小时，会逐条写入任务工时。")
        }
    }

    private var notConfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "link").font(DS.font(30)).foregroundStyle(DS.textTertiary)
            Text("先连上禅道").font(DS.pageTitle)
            Text("填写禅道地址、账号和密码后，就能从 git 提交生成工作日志。").font(DS.body).foregroundStyle(DS.textSecondary)
            Button("去填写禅道账号") { model.context.openSettings(ZentaoLogPlugin.settingsAccountID) }
                .buttonStyle(.dsPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DayTabs(model: model)
                WorkHoursCard(model: model)
                Metrics(model: model)

                if let error = model.errorMessage { DSBanner(.danger, error) }
                if let message = model.message { DSBanner(.success, message) }
                let unmapped = model.activities.filter { model.mappings[$0.repoPath]?.projectID == nil }
                if !unmapped.isEmpty {
                    HStack {
                        DSBanner(.warning, "\(unmapped.map(\.repoName).joined(separator: "、")) 还没对应禅道项目，AI 只能记到兜底任务")
                        Button("去关联") { model.context.openSettings(ZentaoLogPlugin.settingsReposID) }.buttonStyle(.dsSecondary)
                    }
                }

                if model.drafts.isEmpty {
                    DSCard {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.isLoadingRecorded ? "正在同步禅道工时记录…" : "当天暂未填写禅道日志（0 小时）")
                                    .font(DS.rowTitle)
                                Text(model.plannedOvertimeHours > 0 && model.baseWorkHours > 0
                                    ? "点右上角「生成草稿」将按正常 \(hoursText(model.baseWorkHours))h 与加班 \(hoursText(model.plannedOvertimeHours))h 分别生成日志。"
                                    : "可点右上角「生成草稿」或右侧「手动添加」补写。")
                                    .font(DS.caption)
                                    .foregroundStyle(DS.textSecondary)
                            }
                            Spacer()
                            if model.isLoadingRecorded {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("手动添加", systemImage: "plus") { model.addManual() }.buttonStyle(.dsSecondary)
                            }
                        }
                    }
                    sectionTitle("当天的提交")
                    ActivityList(model: model)
                } else {
                    if !model.recordedDrafts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(DS.font(13))
                                    .foregroundStyle(DS.success)
                                Text("已写日志")
                                    .font(DS.font(14, .semibold))
                                    .foregroundStyle(DS.text)
                                Text("\(model.recordedDrafts.count) 条 · 共 \(hoursText(model.recordedHours)) h")
                                    .font(DS.font(12, .semibold).monospacedDigit())
                                    .foregroundStyle(DS.success)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2.5)
                                    .background(DS.success.opacity(0.12), in: .capsule)
                                Spacer()
                                if model.pendingDrafts.isEmpty {
                                    Button("补充一条", systemImage: "plus") { model.addManual() }
                                        .buttonStyle(.dsSecondary)
                                }
                            }
                            VStack(spacing: 10) {
                                ForEach(model.recordedDrafts) { entry in
                                    RecordedLogCard(model: model, entry: entry)
                                }
                            }
                        }
                    }

                    if !model.pendingDrafts.isEmpty {
                        let pendingHours = model.pendingDrafts.reduce(0) { $0 + $1.hours }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("待提交草稿")
                                    .font(DS.font(14, .semibold))
                                    .foregroundStyle(DS.text)
                                Text("\(model.pendingDrafts.count) 条 · \(hoursText(pendingHours)) h")
                                    .font(DS.font(12.5, .medium).monospacedDigit())
                                    .foregroundStyle(DS.textSecondary)
                                Spacer()
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14, alignment: .top)], spacing: 14) {
                                ForEach($model.drafts) { $entry in
                                    if !$entry.wrappedValue.isRecorded {
                                        DraftCard(model: model, entry: $entry) {
                                            model.removeDraft(id: entry.id)
                                        }
                                    }
                                }
                                Button { model.addManual() } label: {
                                    DSCard(dashed: true) {
                                        Label("手动添加一条", systemImage: "plus").font(DS.body).foregroundStyle(DS.textSecondary)
                                            .frame(maxWidth: .infinity, minHeight: 80)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    DisclosureGroup {
                        ActivityList(model: model).padding(.top, 8)
                    } label: {
                        Text("当天的提交（\(model.activities.reduce(0) { $0 + $1.commits.count }) 次）").font(DS.sectionTitle).foregroundStyle(DS.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(DS.sectionTitle).foregroundStyle(DS.textSecondary)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("手动添加", systemImage: "plus") { model.addManual() }.buttonStyle(.dsGhost)
            Spacer()
            let target = model.targetHours
            let otSuffix = model.plannedOvertimeHours > 0 ? "（含加班 \(hoursText(model.plannedOvertimeHours))h）" : ""
            if model.pendingDrafts.isEmpty && !model.recordedDrafts.isEmpty {
                if model.recordedHours >= target {
                    Text("当天已记录 \(hoursText(model.recordedHours)) / \(hoursText(target)) 小时\(otSuffix)")
                        .font(DS.body.monospacedDigit())
                        .foregroundStyle(DS.success)
                } else {
                    Text("已记录 \(hoursText(model.recordedHours)) / \(hoursText(target)) 小时，还需 \(hoursText(model.remainingTargetHours)) 小时\(otSuffix)")
                        .font(DS.body.monospacedDigit())
                        .foregroundStyle(DS.warning)
                }
            } else {
                Text("合计 \(hoursText(model.totalHours)) / \(hoursText(target)) 小时\(otSuffix)")
                    .font(DS.body.monospacedDigit())
                    .foregroundStyle(target > 0 && model.totalHours > target ? DS.warning : DS.textSecondary)
            }
            Button {
                confirmSubmit = true
            } label: {
                if model.isSubmitting {
                    HStack(spacing: 6) { ProgressView().controlSize(.small).tint(DS.onPrimary); Text("提交中") }
                } else {
                    Text("提交到禅道")
                }
            }
            .buttonStyle(.dsPrimary)
            .disabled(model.pendingDrafts.isEmpty || model.isSubmitting)
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
        .background(DS.canvas)
        .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
    }
}

func hoursText(_ h: Double) -> String {
    h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h)
}

/// 最近 7 天标签。
struct DayTabs: View {
    let model: LogModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.recentDays, id: \.self) { day in
                let info = model.context.workCalendar.dayInfo(day)
                let selected = Calendar.current.isDate(day, inSameDayAs: model.date)
                let recordedH = model.recordedHours(on: day)
                let pendingH = model.pendingHours(on: day)
                let overtimeH = model.overtimeHours(on: day)
                Button {
                    Task { await model.select(date: day) }
                } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Text(Calendar.current.isDateInToday(day) ? "今天" : CN.weekdayShort(day))
                                .font(DS.font(13, selected ? .semibold : .medium))
                            Text(CN.slash(day))
                                .font(DS.font(11.5).monospacedDigit())
                                .foregroundStyle(DS.textSecondary)
                        }
                        statusLabel(recordedH: recordedH, pendingH: pendingH, overtimeH: overtimeH, info: info)
                    }
                    .foregroundStyle(selected ? DS.text : DS.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.s(48))
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
    private func statusLabel(recordedH: Double, pendingH: Double, overtimeH: Double, info: DayInfo) -> some View {
        if recordedH > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                Text("\(hoursText(recordedH))h").monospacedDigit()
            }
            .font(DS.font(11.5, .semibold))
            .foregroundStyle(DS.success)
        } else if pendingH > 0 {
            Text("草稿 \(hoursText(pendingH))h")
                .font(DS.font(11.5, .medium))
                .monospacedDigit()
                .foregroundStyle(DS.brand)
        } else if overtimeH > 0 {
            Text("加班 \(hoursText(overtimeH))h")
                .font(DS.font(11.5, .medium))
                .monospacedDigit()
                .foregroundStyle(.purple)
        } else if model.isLoadingRecorded && !model.hasSyncedRemoteRecorded {
            Text("查询中")
                .font(DS.font(11.5))
                .foregroundStyle(DS.textTertiary)
        } else if !info.isWorkday {
            Text(info.name.map { String($0.prefix(3)) } ?? "休息")
                .font(DS.font(11.5))
                .foregroundStyle(DS.danger)
        } else {
            Text("未写")
                .font(DS.font(11.5))
                .foregroundStyle(DS.warning)
        }
    }
}

/// 当日需填工时与快速加班设置卡。
struct WorkHoursCard: View {
    @Bindable var model: LogModel

    private let presets: [Double] = [1, 2, 3, 4]

    var body: some View {
        let dayInfo = model.context.workCalendar.dayInfo(model.date)
        DSCard(padding: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    summaryBlock(dayInfo: dayInfo)
                    Spacer(minLength: 8)
                    overtimeControls
                }
                VStack(alignment: .leading, spacing: 10) {
                    summaryBlock(dayInfo: dayInfo)
                    overtimeControls
                }
            }
        }
    }

    private func summaryBlock(dayInfo: DayInfo) -> some View {
        let base = model.baseWorkHours
        let ot = model.plannedOvertimeHours
        let target = model.targetHours
        let recorded = model.recordedHours
        let remaining = model.remainingTargetHours
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Calendar.current.isDateInToday(model.date) ? "今天需填工时" : "当日需填工时")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                if !dayInfo.isWorkday {
                    Tag(dayInfo.name ?? "休息日", color: DS.danger)
                }
                if ot > 0 {
                    Tag("含加班 \(hoursText(ot))h", color: .purple)
                }
                if dayInfo.isWorkday, let endText = model.context.workCalendar.offWorkTimeText(on: model.date) {
                    Tag("\(endText) 下班", color: ot > 0 ? .purple : DS.textSecondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(hoursText(target)) h")
                    .font(DS.font(24, .bold))
                    .monospacedDigit()
                    .foregroundStyle(ot > 0 ? .purple : DS.text)

                HStack(spacing: 4) {
                    Text(compositionText(base: base, ot: ot, isWorkday: dayInfo.isWorkday))
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)

                    if recorded > 0 && remaining > 0 {
                        Text("· 已写 \(hoursText(recorded))h，还需填 \(hoursText(remaining))h")
                            .font(DS.caption.monospacedDigit())
                            .foregroundStyle(DS.warning)
                    } else if target > 0 && remaining == 0 {
                        Text("· 已填满")
                            .font(DS.caption)
                            .foregroundStyle(DS.success)
                    }
                }
            }
        }
    }

    private func compositionText(base: Double, ot: Double, isWorkday: Bool) -> String {
        if ot > 0 {
            if base > 0 {
                return "正常 \(hoursText(base))h + 加班 \(hoursText(ot))h"
            }
            return "休息日加班 \(hoursText(ot))h"
        }
        if isWorkday {
            return "正常工作 \(hoursText(base))h"
        }
        return "休息日默认无需填写"
    }

    private var overtimeControls: some View {
        HStack(spacing: 8) {
            Label("加班", systemImage: "moon.stars")
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)

            ForEach(presets, id: \.self) { h in
                let selected = abs(model.plannedOvertimeHours - h) < 0.01
                Button("+\(hoursText(h))h") {
                    model.toggleOvertimeHours(h)
                }
                .buttonStyle(.plain)
                .font(DS.font(12.5, selected ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(selected ? .purple : DS.text)
                .padding(.horizontal, 10)
                .frame(height: DS.s(28))
                .background(selected ? Color.purple.opacity(0.14) : DS.card, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(selected ? Color.purple.opacity(0.45) : DS.borderStrong)
                }
                .contentShape(.capsule)
            }

            DSStepper(
                value: Binding(
                    get: { model.plannedOvertimeHours },
                    set: { model.plannedOvertimeHours = $0 }
                ),
                in: 0...12,
                step: 0.5
            ) { $0 > 0 ? "+\(hoursText($0))h" : "0h" }

            if model.plannedOvertimeHours > 0 {
                Button("清除") {
                    model.plannedOvertimeHours = 0
                }
                .buttonStyle(.dsGhost)
            }
        }
    }
}

struct Metrics: View {
    let model: LogModel

    var body: some View {
        let commits = model.activities.reduce(0) { $0 + $1.commits.count }
        let recordedCount = model.recordedDrafts.count
        let pendingCount = model.pendingDrafts.count
        let pendingHours = model.pendingDrafts.reduce(0) { $0 + $1.hours }
        let target = model.targetHours
        let remaining = model.remainingTargetHours
        let recordedDetail: String = {
            if remaining > 0 {
                return "目标 \(hoursText(target)) h · 还需 \(hoursText(remaining)) h"
            }
            if target > 0 {
                return "已达目标 \(hoursText(target)) h（\(recordedCount) 条）"
            }
            return recordedCount > 0 ? "已记录 \(recordedCount) 条" : "休息日"
        }()
        HStack(spacing: 12) {
            DSMetric("已写日志",
                     value: model.recordedHours > 0 ? "\(hoursText(model.recordedHours)) h" : (model.isLoadingRecorded ? "查询中" : "未写"),
                     detail: recordedDetail,
                     valueColor: model.recordedHours > 0 ? DS.success : (model.isLoadingRecorded ? DS.textTertiary : DS.warning))
            DSMetric("待提交草稿",
                     value: "\(hoursText(pendingHours)) h",
                     detail: pendingCount > 0 ? "\(pendingCount) 条待提交" : "合计 \(hoursText(model.totalHours)) h",
                     valueColor: pendingHours > 0 ? DS.brand : DS.textTertiary)
            DSMetric("Git 提交",
                     value: "\(commits) 次",
                     detail: "\(model.activities.count) 个仓库",
                     valueColor: commits > 0 ? DS.text : DS.textTertiary)
            DSMetric("未关闭任务",
                     value: "\(model.openTasks.count)",
                     detail: model.lastScan.map { "扫描于 \(CN.time($0))" } ?? "\(model.projects.count) 个项目")
        }
    }
}

struct ActivityList: View {
    let model: LogModel

    var body: some View {
        if model.activities.isEmpty {
            DSCard {
                Text(model.isScanning ? "正在扫描…" : "这一天没有找到你的提交，可以手动添加工作内容。")
                    .font(DS.body).foregroundStyle(DS.textSecondary)
            }
        }
        VStack(spacing: 10) {
            ForEach(model.activities) { act in
                DSCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(act.repoName).font(DS.rowTitle)
                            if let m = model.mappings[act.repoPath], m.projectID != nil {
                                Tag(m.projectName, color: DS.textSecondary)
                            } else {
                                Tag("未关联项目", color: DS.warning)
                            }
                            Spacer()
                            Text("\(act.commits.count) 次 · \(act.lines) 行").font(DS.caption).foregroundStyle(DS.textTertiary)
                        }
                        ForEach(act.commits) { c in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(CN.time(c.date))
                                    .font(DS.caption.monospacedDigit()).foregroundStyle(DS.textTertiary)
                                    .frame(width: 40, alignment: .leading)
                                Text(c.subject).font(DS.body).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 已记录的禅道日志卡片：工作内容与消耗工时为主焦点，任务归属与剩余工时沉到底栏。
struct RecordedLogCard: View {
    let model: LogModel
    let entry: DraftEntry

    private var accent: Color { entry.isOvertime ? .purple : DS.success }

    private var hasWork: Bool {
        !entry.work.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var workText: String {
        let trimmed = entry.work.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（无工作内容说明）" : trimmed
    }

    private var recordedTitle: String {
        if let task = model.task(entry.taskID) {
            return "#\(task.id) \(task.name)"
        }
        if let id = entry.taskID, let title = entry.taskTitle {
            return "#\(id) \(title)"
        }
        if let title = entry.taskTitle {
            return title
        }
        if let id = entry.taskID {
            return "#\(id)"
        }
        return "禅道日志"
    }

    private var projectSubtitle: String? {
        var parts: [String] = []
        if let task = model.task(entry.taskID), !task.projectName.isEmpty {
            parts.append(task.projectName)
        }
        if !entry.repoPaths.isEmpty {
            parts.append(entry.repoPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: 3.5)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    Text(workText)
                        .font(DS.font(15.5, .semibold))
                        .foregroundStyle(hasWork ? DS.text : DS.textTertiary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(hoursText(entry.hours))
                            .font(DS.font(21, .bold))
                            .monospacedDigit()
                        Text("h")
                            .font(DS.font(12, .semibold))
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.12), in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.26)) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Rectangle()
                    .fill(DS.border)
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("已记录")
                    }
                    .font(DS.font(11.5, .semibold))
                    .foregroundStyle(DS.success)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(DS.success.opacity(0.14), in: .capsule)

                    if entry.isOvertime { Tag("加班", color: .purple) }
                    if entry.isFallback { Tag("兜底", color: DS.warning) }

                    HStack(spacing: 4) {
                        Image(systemName: "checklist").font(DS.font(11))
                        Text(recordedTitle).lineLimit(1)
                    }
                    .font(DS.font(12.5, .medium))
                    .foregroundStyle(DS.textSecondary)

                    if let project = projectSubtitle {
                        Text("·").foregroundStyle(DS.textTertiary)
                        Text(project)
                            .font(DS.font(12.5))
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text("剩余 \(hoursText(entry.left)) h")
                        .font(DS.font(12).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(DS.card.opacity(0.5))
            }
        }
        .background {
            ZStack {
                DS.well
                accent.opacity(0.045)
            }
        }
        .clipShape(.rect(cornerRadius: DS.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radius)
                .strokeBorder(accent.opacity(0.28), lineWidth: 1)
        }
    }
}

/// 一条待提交草稿。
struct DraftCard: View {
    let model: LogModel
    @Binding var entry: DraftEntry
    let onDelete: () -> Void

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    DSPicker(selection: $entry.taskID, options: taskOptions, width: 250)
                        .onChange(of: entry.taskID) { recompute() }
                    if entry.isFallback { Tag("兜底", color: DS.warning) }
                    if entry.isOvertime { Tag("加班", color: .purple) }
                    if entry.isManual { Tag("手动", color: DS.textSecondary) }
                    Spacer(minLength: 0)
                    Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.dsGhost).help("删除这一条")
                }
                if let task = model.task(entry.taskID) {
                    Text("\(task.projectName)" + (entry.repoPaths.isEmpty ? "" : " · " + entry.repoPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")))
                        .font(DS.caption).foregroundStyle(DS.textTertiary).lineLimit(1)
                }
                TextEditor(text: $entry.work)
                    .font(DS.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 70)
                    .padding(8)
                    .background(DS.well, in: .rect(cornerRadius: DS.controlRadius))
                HStack(spacing: 10) {
                    Text("消耗").font(DS.caption).foregroundStyle(DS.textSecondary)
                    DSStepper(value: $entry.hours, in: 0...24, step: 0.5) { "\(hoursText($0)) h" }
                        .onChange(of: entry.hours) { recompute() }
                    Text("剩余").font(DS.caption).foregroundStyle(DS.textSecondary)
                    TextField("", value: $entry.left, format: .number).textFieldStyle(.ds).frame(width: 56)
                    Spacer()
                    Toggle("加班", isOn: $entry.isOvertime).toggleStyle(.checkbox).font(DS.caption)
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
        if let i = model.drafts.firstIndex(where: { $0.id == entry.id }) { model.recomputeLeft(for: i) }
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
