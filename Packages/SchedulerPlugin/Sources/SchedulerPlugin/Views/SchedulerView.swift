import AppKit
import IronBowlKit
import SwiftUI

struct SchedulerView: View {
    @Bindable var scheduler: TaskScheduler
    let workCalendar: WorkCalendar
    let openPlugin: (String) -> Void
    let openSettings: (String?) -> Void

    enum Tab: Hashable {
        case tasks
        case runs
    }

    enum RunFilter: Hashable {
        case all
        case succeeded
        case skipped
        case failed
    }

    @State private var tab: Tab = .tasks
    @State private var runFilter: RunFilter = .all
    @State private var selectedTaskIDFilter: String? = nil
    @State private var editorDraft: EditorDraft?
    @State private var deletingTask: ScheduledTask?
    @State private var confirmClearRuns = false
    @State private var expandedRunIDs = Set<Int64>()
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    struct EditorDraft: Identifiable {
        let id = UUID()
        let task: ScheduledTask?
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("定时任务", topPadding: 8) {
                DSTabs(selection: $tab, options: [
                    (.tasks, "任务列表 (\(scheduler.tasks.count))"),
                    (.runs, "执行记录 (\(scheduler.recentRuns.count))"),
                ])
                .padding(.leading, sidebarCollapsed ? 38 : 0)
            } actions: {
                if tab == .runs && !scheduler.recentRuns.isEmpty {
                    Button("清空记录") { confirmClearRuns = true }
                        .buttonStyle(.dsSecondary)
                }
                Button {
                    editorDraft = EditorDraft(task: nil)
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .buttonStyle(.dsPrimary)
                .disabled(scheduler.registeredActions.isEmpty)
            }

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == .tasks {
                        tasksContent
                    } else {
                        runsContent
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.canvas)
        .sheet(item: $editorDraft) { draft in
            TaskEditorSheet(scheduler: scheduler, existingTask: draft.task)
        }
        .alert("删除定时任务？", isPresented: Binding(
            get: { deletingTask != nil },
            set: { if !$0 { deletingTask = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let task = deletingTask {
                    scheduler.deleteTask(id: task.id)
                }
                deletingTask = nil
            }
            Button("取消", role: .cancel) { deletingTask = nil }
        } message: {
            Text("确定删除「\(deletingTask?.name ?? "")」吗？删除后不会再自动执行。")
        }
        .alert("清空执行记录？", isPresented: $confirmClearRuns) {
            Button("清空", role: .destructive) {
                scheduler.clearRuns(taskID: selectedTaskIDFilter)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(selectedTaskIDFilter == nil ? "将删除全部历史执行日志。" : "将删除当前筛选任务的全部历史执行日志。")
        }
    }

    // MARK: - 任务列表

    @ViewBuilder
    private var tasksContent: some View {
        metricsBar

        if scheduler.tasks.isEmpty {
            DSCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没有定时任务").font(DS.rowTitle)
                    Text("你可以创建定时生成并提交禅道日志、定时桌面提醒或定时运行 Shell 脚本的任务。")
                        .font(DS.body)
                        .foregroundStyle(DS.textSecondary)
                    Button("新建定时任务") {
                        editorDraft = EditorDraft(task: nil)
                    }
                    .buttonStyle(.dsPrimary)
                    .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
        } else {
            VStack(spacing: 12) {
                ForEach(scheduler.tasks) { task in
                    taskCard(task)
                }
            }
        }
    }

    private var metricsBar: some View {
        let upcoming = scheduler.nextUpcomingTask()
        let counts = scheduler.todayRunCounts()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            DSMetric(
                "已启用任务",
                value: "\(scheduler.enabledTaskCount) / \(scheduler.tasks.count)",
                detail: scheduler.isStarted ? "调度引擎运行中" : "调度引擎未启动"
            )
            DSMetric(
                "下一次执行",
                value: upcoming.map { formatUpcomingValue($0.fireAt) } ?? "暂无计划",
                detail: upcoming.map { "\($0.task.name)（\(countdown(to: $0.fireAt))后）" } ?? "请开启至少一个任务"
            )
            DSMetric(
                "今日执行",
                value: "成功 \(counts.succeeded)",
                detail: "跳过 \(counts.skipped) · 失败 \(counts.failed)",
                valueColor: counts.failed > 0 ? DS.danger : DS.text
            )
        }
    }

    private func taskCard(_ task: ScheduledTask) -> some View {
        let action = scheduler.action(id: task.actionID)
        let isRunning = scheduler.runningTaskIDs.contains(task.id)

        return DSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: action?.systemImage ?? "clock.badge.questionmark")
                        .font(DS.font(16))
                        .foregroundStyle(task.isEnabled ? DS.text : DS.textTertiary)
                        .frame(width: 34, height: 34)
                        .background(DS.well, in: .rect(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(task.name)
                                .font(DS.font(15, .semibold))
                                .foregroundStyle(task.isEnabled ? DS.text : DS.textSecondary)
                            if isRunning {
                                Tag("执行中", color: DS.brand)
                            } else if task.isEnabled {
                                Tag("已启用", color: DS.success)
                            } else {
                                Tag("已暂停", color: DS.textTertiary)
                            }
                            if action == nil {
                                Tag("对应插件未启用", color: DS.warning)
                            }
                        }

                        Text("\(action?.title ?? task.actionID) · \(task.schedule.summaryText)")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        Button {
                            Task { await scheduler.runNow(taskID: task.id) }
                        } label: {
                            if isRunning {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("运行中")
                                }
                            } else {
                                Label("立即运行", systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(isRunning || action == nil)

                        Button {
                            editorDraft = EditorDraft(task: task)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.dsGhost)
                        .help("编辑任务")

                        Button {
                            deletingTask = task
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.dsGhost)
                        .help("删除任务")

                        DSToggle(isOn: Binding(
                            get: { task.isEnabled },
                            set: { scheduler.setEnabled(taskID: task.id, enabled: $0) }
                        ))
                    }
                }

                Divider().overlay(DS.border)

                HStack(spacing: 16) {
                    if task.isEnabled, let next = task.nextRunAt {
                        Label(
                            "下次：\(CN.dateTime(next))（\(countdown(to: next))后）",
                            systemImage: "calendar.badge.clock"
                        )
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                    } else {
                        Label("已暂停自动调度", systemImage: "pause.circle")
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                    }

                    if task.schedule.kind != .interval {
                        Text(task.misfirePolicy == .runIfMissedToday ? "错过当天补跑" : "错过跳过")
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                    }

                    Spacer(minLength: 8)

                    if let lastRunAt = task.lastRunAt, let lastStatus = task.lastStatus {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(lastStatus))
                                .frame(width: 7, height: 7)
                            Text("上次 \(CN.dateTime(lastRunAt)) · \(task.lastSummary ?? lastStatus.displayName)")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("尚未执行过")
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                }

                if action == nil {
                    DSBanner(.warning, "该任务依赖的插件当前未启用，开启对应插件后即可正常执行。", actionTitle: "前往设置") {
                        openSettings("general")
                    }
                } else if let pluginID = action?.pluginID {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("打开关联插件") { openPlugin(pluginID) }
                            .buttonStyle(.dsGhost)
                    }
                }
            }
        }
    }

    // MARK: - 执行记录

    @ViewBuilder
    private var runsContent: some View {
        HStack(spacing: 12) {
            DSTabs(selection: $runFilter, options: [
                (.all, "全部"),
                (.succeeded, "成功"),
                (.skipped, "跳过"),
                (.failed, "失败"),
            ])

            Spacer()

            let taskOptions: [DSPickerOption<String?>] =
                [DSPickerOption(nil, title: "全部任务")]
                + scheduler.tasks.map { DSPickerOption(Optional($0.id), title: $0.name) }
            DSPicker(selection: $selectedTaskIDFilter, options: taskOptions, width: 220)
        }

        let runs = filteredRuns
        if runs.isEmpty {
            DSCard {
                Text("暂无符合条件的执行记录")
                    .font(DS.body)
                    .foregroundStyle(DS.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        } else {
            VStack(spacing: 10) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    runCard(run)
                }
            }
        }
    }

    private var filteredRuns: [ScheduledTaskRun] {
        scheduler.recentRuns.filter { run in
            if let taskID = selectedTaskIDFilter, run.taskID != taskID { return false }
            switch runFilter {
            case .all: return true
            case .succeeded: return run.status == .succeeded
            case .skipped: return run.status == .skipped
            case .failed: return run.status == .failed
            }
        }
    }

    private func runCard(_ run: ScheduledTaskRun) -> some View {
        let runKey = run.id ?? Int64(run.startedAt.timeIntervalSince1970 * 1000)
        let isExpanded = expandedRunIDs.contains(runKey)

        return DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor(run.status))
                        .frame(width: 8, height: 8)
                    Text(run.taskName)
                        .font(DS.rowTitle)
                    Tag(run.status.displayName, color: statusColor(run.status))
                    Tag(run.trigger.displayName, color: DS.textSecondary)

                    Spacer()

                    Text(durationText(for: run))
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                        .monospacedDigit()
                    Text(CN.dateTime(run.startedAt))
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                        .monospacedDigit()
                }

                Text(run.summary.isEmpty ? run.status.displayName : run.summary)
                    .font(DS.body)
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)

                if !run.detail.isEmpty {
                    HStack(spacing: 10) {
                        Button(isExpanded ? "收起详情" : "查看详情") {
                            if isExpanded {
                                expandedRunIDs.remove(runKey)
                            } else {
                                expandedRunIDs.insert(runKey)
                            }
                        }
                        .buttonStyle(.dsGhost)

                        if isExpanded {
                            Button("复制详情") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(run.detail, forType: .string)
                            }
                            .buttonStyle(.dsGhost)
                        }
                    }

                    if isExpanded {
                        Text(run.detail)
                            .font(DS.mono(12.5))
                            .foregroundStyle(DS.textSecondary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.well, in: .rect(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - 辅助

    private func formatUpcomingValue(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "今天 \(CN.time(date))"
        }
        if Calendar.current.isDateInTomorrow(date) {
            return "明天 \(CN.time(date))"
        }
        return "\(CN.monthDay(date)) \(CN.time(date))"
    }

    private func durationText(for run: ScheduledTaskRun) -> String {
        guard let finishedAt = run.finishedAt else { return "进行中" }
        let sec = max(0, finishedAt.timeIntervalSince(run.startedAt))
        return sec < 1 ? "<1 秒" : String(format: "%.1f 秒", sec)
    }

    private func statusColor(_ status: TaskRunStatus) -> Color {
        switch status {
        case .running: DS.brand
        case .succeeded: DS.success
        case .skipped: DS.warning
        case .failed: DS.danger
        }
    }
}
