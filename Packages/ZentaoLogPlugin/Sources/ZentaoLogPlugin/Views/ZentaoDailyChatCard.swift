import IronBowlKit
import SwiftUI

/// 在首页对话流中直接渲染并操作的日报交互卡片（编辑内容/任务/工时、重新生成、记加班与提交禅道）。
struct ZentaoDailyChatCard: View {
    @Bindable var model: LogModel
    let dateString: String

    @State private var confirmSubmit = false
    @State private var isOperating = false
    @State private var localNotice: String?
    @State private var localError: String?

    private var targetDate: Date {
        ZentaoChatHandler.parseDay(dateString)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(targetDate)
    }

    private var pendingEntries: [DraftEntry] {
        model.pendingEntries(forDateString: dateString)
    }

    private var recordedEntries: [DraftEntry] {
        model.recordedEntries(forDateString: dateString)
    }

    private var pendingHours: Double {
        pendingEntries.reduce(0) { $0 + $1.hours }
    }

    private var recordedHours: Double {
        recordedEntries.reduce(0) { $0 + $1.hours }
    }

    private var targetHours: Double {
        model.targetHours(on: targetDate)
    }

    private var remainingHours: Double {
        max(0, targetHours - recordedHours)
    }

    private var plannedOvertime: Double {
        model.overtimeHours(on: targetDate)
    }

    private var statusBadge: (text: String, color: Color) {
        let info = model.context.workCalendar.dayInfo(targetDate)
        if !info.isWorkday && targetHours <= 0 && pendingEntries.isEmpty && recordedEntries.isEmpty {
            return ("休息日", DS.textSecondary)
        }
        if recordedHours == 0 && pendingEntries.isEmpty {
            return (isToday ? "今日未写" : "未写", DS.danger)
        }
        if !pendingEntries.isEmpty || remainingHours > 0 {
            return (!pendingEntries.isEmpty ? "草稿待交" : "还差 \(hoursText(remainingHours))h", DS.warning)
        }
        return (isToday ? "今日已写满" : "已写满", DS.success)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            if !model.isConfigured {
                DSBanner(.warning, "尚未配置禅道账号，生成后暂无法拉取任务或提交。", actionTitle: "去填写账号") {
                    model.context.openSettings(ZentaoLogPlugin.settingsAccountID)
                }
            }

            if let localError {
                DSBanner(.danger, localError)
            } else if let localNotice {
                DSBanner(.success, localNotice)
            }

            if pendingEntries.isEmpty && recordedEntries.isEmpty {
                emptyState
            } else {
                if !pendingEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("待提交草稿")
                                .font(DS.font(12.5, .semibold))
                                .foregroundStyle(DS.warning)
                            Text("共 \(pendingEntries.count) 条 · \(hoursText(pendingHours))h")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                        ForEach(pendingEntries) { entry in
                            PendingDraftChatRow(
                                model: model,
                                entry: entry,
                                onChange: { updated in
                                    model.updatePendingDraft(updated, forDateString: dateString)
                                },
                                onDelete: {
                                    model.removePendingDraft(id: entry.id, forDateString: dateString)
                                }
                            )
                        }
                    }
                }

                if !recordedEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(DS.font(12))
                                .foregroundStyle(DS.success)
                            Text("已入账禅道")
                                .font(DS.font(12.5, .semibold))
                                .foregroundStyle(DS.text)
                            Text("共 \(recordedEntries.count) 条 · \(hoursText(recordedHours))h")
                                .font(DS.caption)
                                .foregroundStyle(DS.success)
                        }
                        ForEach(recordedEntries) { entry in
                            RecordedDraftChatRow(model: model, entry: entry)
                        }
                    }
                }
            }

            footerBar
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DS.borderStrong) }
        .alert("提交到禅道？", isPresented: $confirmSubmit) {
            Button("确认提交 \(pendingEntries.count) 条") {
                Task { await submitDrafts() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(dateString) 共 \(hoursText(pendingHours)) 小时，将逐条写入禅道任务工时并回查确认。")
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(DS.font(13, .semibold))
                .foregroundStyle(DS.brand)
            Text(isToday ? "今日日报 · \(dateString)" : "\(CN.monthDay(targetDate)) 日报 · \(dateString)")
                .font(DS.font(14, .semibold))
                .foregroundStyle(DS.text)

            Text(statusBadge.text)
                .font(DS.font(11, .semibold))
                .foregroundStyle(statusBadge.color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(statusBadge.color.opacity(0.12), in: .capsule)

            Spacer(minLength: 6)

            Text("目标 \(hoursText(targetHours))h · 已写 \(hoursText(recordedHours))h")
                .font(DS.font(11.5))
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)

            Button {
                Task { await regenerate() }
            } label: {
                if isOperating || model.isGenerating {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .font(DS.font(12))
                }
            }
            .buttonStyle(.dsSecondary)
            .controlSize(.small)
            .disabled(isOperating || model.isGenerating)

            Button {
                model.addManualPending(forDateString: dateString)
            } label: {
                Label("手写", systemImage: "plus")
                    .font(DS.font(12))
            }
            .buttonStyle(.dsSecondary)
            .controlSize(.small)

            Button {
                model.context.openPlugin(ZentaoLogPlugin.pluginID)
                Task { await model.select(date: targetDate) }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(DS.font(12))
            }
            .buttonStyle(.dsGhost)
            .help("在日报页面打开完整手账视图")
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Text("当前暂无待提交草稿或已入账工时。")
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
            Spacer()
            Button("按项目规则生成") {
                Task { await regenerate() }
            }
            .buttonStyle(.dsPrimary)
            .controlSize(.small)
            .disabled(isOperating || model.isGenerating)
        }
        .padding(10)
        .background(DS.well, in: .rect(cornerRadius: 8))
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text("加班：")
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
            ForEach([0.0, 1.0, 2.0, 3.0], id: \.self) { (hours: Double) in
                let selected = abs(plannedOvertime - hours) < 0.05
                Button {
                    model.setOvertimeHours(hours, for: targetDate)
                } label: {
                    Text(hours == 0 ? "无" : "+\(Int(hours))h")
                        .font(DS.font(11.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? DS.text : DS.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selected ? DS.selected : DS.well, in: .capsule)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if !pendingEntries.isEmpty {
                Button {
                    confirmSubmit = true
                } label: {
                    if model.isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("提交到禅道 (\(hoursText(pendingHours))h)", systemImage: "checkmark.seal.fill")
                    }
                }
                .buttonStyle(.dsPrimary)
                .disabled(!model.isConfigured || model.isSubmitting || isOperating)
            }
        }
        .padding(.top, 2)
    }

    private func regenerate() async {
        isOperating = true
        localNotice = nil
        localError = nil
        defer { isOperating = false }
        await model.generateForDate(targetDate, forceScan: true)
        if let err = model.errorMessage {
            localError = err
        } else {
            localNotice = model.message ?? "已按项目规则重新生成草稿"
        }
    }

    private func submitDrafts() async {
        localNotice = nil
        localError = nil
        let result = await model.submitPending(forDateString: dateString)
        if result.failures.isEmpty {
            localNotice = "已成功提交 \(result.succeeded) 条日报到禅道"
        } else {
            localError = (["成功 \(result.succeeded) 条，以下失败："] + result.failures).joined(separator: "\n")
        }
    }
}

private struct PendingDraftChatRow: View {
    let model: LogModel
    let entry: DraftEntry
    let onChange: (DraftEntry) -> Void
    let onDelete: () -> Void

    @State private var workText: String

    init(
        model: LogModel,
        entry: DraftEntry,
        onChange: @escaping (DraftEntry) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.model = model
        self.entry = entry
        self.onChange = onChange
        self.onDelete = onDelete
        _workText = State(initialValue: entry.work)
    }

    private var taskTitleText: String {
        if let task = model.task(entry.taskID) {
            return "#\(task.id) \(task.name)"
        }
        if let id = entry.taskID {
            return "#\(id)"
        }
        return "选择禅道任务"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    if model.openTasks.isEmpty {
                        Text("暂无可选任务（请先同步禅道任务）")
                    } else {
                        ForEach(model.openTasks) { task in
                            Button("#\(task.id) [\(task.projectName)] \(task.name)") {
                                var next = entry
                                next.taskID = task.id
                                next.isFallback = (task.id == model.settings[LogKeys.fallbackTaskID])
                                onChange(next)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(taskTitleText)
                            .font(DS.font(12, .medium))
                            .foregroundStyle(entry.taskID == nil ? DS.danger : DS.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .font(DS.font(9.5, .semibold))
                            .foregroundStyle(DS.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.card, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border) }
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 320, alignment: .leading)

                if entry.isFallback {
                    Text("兜底")
                        .font(DS.font(10.5, .medium))
                        .foregroundStyle(DS.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DS.warning.opacity(0.12), in: .capsule)
                }

                Button {
                    var next = entry
                    next.isOvertime.toggle()
                    onChange(next)
                } label: {
                    Text(entry.isOvertime ? "加班" : "正常")
                        .font(DS.font(10.5, .medium))
                        .foregroundStyle(entry.isOvertime ? .purple : DS.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (entry.isOvertime ? Color.purple.opacity(0.12) : DS.card),
                            in: .capsule
                        )
                        .overlay { Capsule().strokeBorder(DS.border) }
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                HStack(spacing: 0) {
                    Button {
                        var next = entry
                        next.hours = max(0.5, ((entry.hours - 0.5) * 2).rounded() / 2)
                        onChange(next)
                    } label: {
                        Image(systemName: "minus").frame(width: 22, height: 22)
                    }
                    Text("\(hoursText(entry.hours))h")
                        .font(DS.font(12, .semibold))
                        .monospacedDigit()
                        .frame(minWidth: 36)
                    Button {
                        var next = entry
                        next.hours = min(24, ((entry.hours + 0.5) * 2).rounded() / 2)
                        onChange(next)
                    } label: {
                        Image(systemName: "plus").frame(width: 22, height: 22)
                    }
                }
                .buttonStyle(.plain)
                .background(DS.card, in: .rect(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border) }

                Text("剩 \(hoursText(entry.left))h")
                    .font(DS.font(11))
                    .monospacedDigit()
                    .foregroundStyle(DS.textTertiary)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help("删除该条草稿")
            }

            TextField("填写工作内容…", text: $workText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.font(13))
                .lineLimit(1...6)
                .padding(8)
                .background(DS.card, in: .rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border) }
                .onChange(of: entry.work) { _, latest in
                    if workText != latest {
                        workText = latest
                    }
                }
                .onChange(of: workText) { _, newValue in
                    guard newValue != entry.work else { return }
                    var next = entry
                    next.work = newValue
                    onChange(next)
                }
        }
        .padding(10)
        .background(DS.well.opacity(0.65), in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(DS.border) }
    }
}

private struct RecordedDraftChatRow: View {
    let model: LogModel
    let entry: DraftEntry

    private var taskTitleText: String {
        if let title = entry.taskTitle, !title.isEmpty { return title }
        if let task = model.task(entry.taskID) { return "#\(task.id) \(task.name)" }
        if let id = entry.taskID { return "#\(id)" }
        return "未关联任务"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(taskTitleText)
                    .font(DS.font(12, .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Spacer()
                Text("\(hoursText(entry.hours))h")
                    .font(DS.font(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.success)
            }
            Text(entry.work)
                .font(DS.font(12.5))
                .foregroundStyle(DS.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(DS.success.opacity(0.06), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DS.success.opacity(0.25)) }
    }
}
