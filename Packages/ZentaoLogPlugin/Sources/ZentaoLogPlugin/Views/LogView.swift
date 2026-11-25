import IronBowlKit
import SwiftUI

struct LogView: View {
    @Bindable var model: LogModel
    @Environment(\.openSettings) private var openSettings
    @State private var showOvertime = false
    @State private var confirmSubmit = false

    var body: some View {
        Group {
            if !model.isConfigured {
                ContentUnavailableView {
                    Label("先连上禅道", systemImage: "link.badge.plus")
                } description: {
                    Text("在设置 → 禅道日志里填写禅道地址、账号和密码。")
                } actions: {
                    Button("打开设置") { openSettings() }.buttonStyle(.glassProminent)
                }
            } else {
                content
            }
        }
        .navigationTitle("禅道日志")
        .toolbar { toolbar }
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DayStrip(model: model)
                SummaryCard(model: model)
                if let error = model.errorMessage {
                    GlassCard(tint: .red) {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                if let message = model.message {
                    GlassCard(tint: .green) { Label(message, systemImage: "checkmark.circle.fill") }
                }
                if model.drafts.isEmpty {
                    ActivityList(model: model)
                } else {
                    ForEach($model.drafts) { $entry in
                        DraftCard(model: model, entry: $entry) {
                            model.drafts.removeAll { $0.id == entry.id }
                        }
                    }
                    DisclosureGroup("当天的提交（\(model.activities.reduce(0) { $0 + $1.commits.count }) 次）") {
                        ActivityList(model: model)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var bottomBar: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                Button("手动添加", systemImage: "plus") { model.addManual() }
                    .buttonStyle(.glass)
                Button("加班", systemImage: "moon.stars.fill") { showOvertime = true }
                    .buttonStyle(.glass)
                Spacer()
                Text("合计 \(hoursText(model.totalHours)) / 默认 \(hoursText(model.defaultHours)) 小时")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(model.totalHours > model.defaultHours ? Color.orange : .secondary)
                Button {
                    confirmSubmit = true
                } label: {
                    if model.isSubmitting { ProgressView().controlSize(.small) } else { Label("提交到禅道", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.glassProminent)
                .disabled(model.pendingDrafts.isEmpty || model.isSubmitting)
            }
            .padding(12)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("AI", selection: $model.providerKind) {
                ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .help("这次用哪个 AI 生成")
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isScanning || model.isLoadingTasks { ProgressView().controlSize(.small) } else { Label("刷新", systemImage: "arrow.clockwise") }
            }
            .help("重新扫描提交、拉取禅道任务")
            Button {
                Task { await model.generate() }
            } label: {
                if model.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("生成草稿", systemImage: "sparkles")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isGenerating)
        }
    }
}

func hoursText(_ h: Double) -> String {
    h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h)
}

/// 最近 7 天选择条。
struct DayStrip: View {
    let model: LogModel

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(model.recentDays, id: \.self) { day in
                    let info = model.context.workCalendar.dayInfo(day)
                    let selected = Calendar.current.isDate(day, inSameDayAs: model.date)
                    Button {
                        Task { await model.select(date: day) }
                    } label: {
                        VStack(spacing: 2) {
                            Text(Calendar.current.isDateInToday(day) ? "今天" : day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption2)
                            Text(day.formatted(.dateTime.month(.defaultDigits).day()))
                                .font(.callout.weight(.semibold).monospacedDigit())
                            Text(dayBadge(info)).font(.system(size: 9)).foregroundStyle(info.isWorkday ? Color.secondary : .red)
                        }
                        .frame(width: 58, height: 52)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.35)).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 14))
                }
            }
        }
    }

    func dayBadge(_ info: DayInfo) -> String {
        switch info.kind {
        case .workday: "班"
        case .makeupWorkday: "补班"
        case .weekend: "休"
        case .holiday: info.name ?? "假"
        }
    }
}

struct SummaryCard: View {
    let model: LogModel

    var body: some View {
        let commits = model.activities.reduce(0) { $0 + $1.commits.count }
        let unmapped = model.activities.filter { model.mappings[$0.repoPath]?.projectID == nil }
        GlassCard {
            HStack(spacing: 28) {
                stat("\(commits)", "次提交")
                stat("\(model.activities.count)", "个仓库")
                stat("\(model.openTasks.count)", "个未关闭任务")
                stat(hoursText(model.defaultHours), "小时默认工时")
                Spacer()
                if !unmapped.isEmpty {
                    Label("\(unmapped.count) 个仓库还没对应禅道项目", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActivityList: View {
    let model: LogModel

    var body: some View {
        if model.activities.isEmpty {
            GlassCard {
                Label(model.isScanning ? "正在扫描…" : "这一天没有找到你的提交", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(model.activities) { act in
            GlassCard(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(act.repoName).font(.headline)
                        if let m = model.mappings[act.repoPath], m.projectID != nil {
                            Tag(m.projectName, color: .accentColor)
                        } else {
                            Tag("未关联项目", color: .orange)
                        }
                        Spacer()
                        Text("\(act.commits.count) 次 · \(act.lines) 行").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(act.commits) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(c.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(c.subject).font(.callout).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

/// 一条草稿。
struct DraftCard: View {
    let model: LogModel
    @Binding var entry: DraftEntry
    let onDelete: () -> Void

    var body: some View {
        GlassCard(tint: entry.isRecorded ? .gray : entry.isFallback ? .yellow : nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if entry.isRecorded {
                        Text(model.task(entry.taskID).map { "#\($0.id) \($0.name)" } ?? "#\(entry.taskID ?? 0)")
                            .font(.headline)
                    } else {
                        TaskPicker(model: model, selection: $entry.taskID)
                            .onChange(of: entry.taskID) { recompute() }
                    }
                    if entry.isRecorded { Tag("已记录", color: .green) }
                    if entry.isFallback { Tag("兜底", color: .orange) }
                    if entry.isOvertime { Tag("加班", color: .purple) }
                    if entry.isManual { Tag("手动", color: .blue) }
                    Spacer()
                    if !entry.isRecorded {
                        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("删除这一条")
                    }
                }
                HStack(spacing: 18) {
                    LabeledContent("消耗") {
                        if entry.isRecorded {
                            Text("\(hoursText(entry.hours)) h")
                        } else {
                            Stepper(value: $entry.hours, in: 0...24, step: 0.5) {
                                Text("\(hoursText(entry.hours)) h").monospacedDigit()
                            }
                            .onChange(of: entry.hours) { recompute() }
                        }
                    }
                    LabeledContent("剩余") {
                        if entry.isRecorded {
                            Text("\(hoursText(entry.left)) h")
                        } else {
                            TextField("剩余", value: $entry.left, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    if !entry.isRecorded {
                        Toggle("加班", isOn: $entry.isOvertime).toggleStyle(.checkbox)
                    }
                    Spacer()
                    if !entry.repoPaths.isEmpty {
                        Text(entry.repoPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.callout)
                if entry.isRecorded {
                    Text(entry.work).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    TextEditor(text: $entry.work)
                        .font(.callout)
                        .frame(minHeight: 64)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background.opacity(0.4), in: .rect(cornerRadius: 10))
                }
            }
        }
    }

    private func recompute() {
        if let i = model.drafts.firstIndex(where: { $0.id == entry.id }) { model.recomputeLeft(for: i) }
    }
}

/// 按项目分组的任务选择器。
struct TaskPicker: View {
    let model: LogModel
    @Binding var selection: Int?

    var body: some View {
        Picker("任务", selection: $selection) {
            Text("选择任务…").tag(Int?.none)
            ForEach(model.projects, id: \.id) { project in
                Section(project.name) {
                    ForEach(model.openTasks.filter { $0.projectID == project.id }) { t in
                        Text("#\(t.id) \(t.name)（剩 \(hoursText(t.left))h）").tag(Int?.some(t.id))
                    }
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 420)
    }
}

struct OvertimeSheet: View {
    let model: LogModel
    @Environment(\.dismiss) private var dismiss
    @State private var hours: Double = 2
    @State private var taskID: Int?
    @State private var work = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("记一笔加班", systemImage: "moon.stars.fill").font(.title3.weight(.semibold))
            Form {
                Stepper(value: $hours, in: 0.5...12, step: 0.5) { Text("时长：\(hoursText(hours)) 小时") }
                LabeledContent("任务") { TaskPicker(model: model, selection: $taskID) }
                TextField("做了什么（可留空）", text: $work, axis: .vertical).lineLimit(2...4)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.glass)
                Button("加上") {
                    model.addOvertime(hours: hours, taskID: taskID, work: work)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(taskID == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            hours = model.settings[LogKeys.overtimeDefaultHours]
            taskID = model.busiestTaskID
        }
    }
}
