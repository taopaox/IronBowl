import IronBowlKit
import SwiftUI

struct LogView: View {
    @Bindable var model: LogModel
    @State private var showOvertime = false
    @State private var confirmSubmit = false

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("禅道日志") {
                EmptyView()
            } actions: {
                Button { Task { await model.refresh() } } label: {
                    if model.isScanning || model.isLoadingTasks { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.dsGhost)
                .help("重新扫描提交、拉取禅道任务")
                DSPicker(selection: $model.providerKind, options: AIProviderKind.allCases.map { ($0, $0.displayName) })
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
            .padding(.top, 8)

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
            Image(systemName: "link").font(.system(size: 28)).foregroundStyle(DS.textTertiary)
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
                    sectionTitle("当天的提交")
                    ActivityList(model: model)
                } else {
                    sectionTitle("日志草稿")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach($model.drafts) { $entry in
                            DraftCard(model: model, entry: $entry) {
                                model.drafts.removeAll { $0.id == entry.id }
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
            Text("合计 \(hoursText(model.totalHours)) / \(hoursText(model.defaultHours)) 小时")
                .font(DS.body.monospacedDigit())
                .foregroundStyle(model.totalHours > model.defaultHours ? DS.warning : DS.textSecondary)
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
        HStack(spacing: 6) {
            ForEach(model.recentDays, id: \.self) { day in
                let info = model.context.workCalendar.dayInfo(day)
                let selected = Calendar.current.isDate(day, inSameDayAs: model.date)
                let submitted = !model.store.submissions(on: WorkCalendar.dayString(day)).isEmpty
                Button {
                    Task { await model.select(date: day) }
                } label: {
                    VStack(spacing: 2) {
                        Text(Calendar.current.isDateInToday(day) ? "今天" : day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        HStack(spacing: 3) {
                            Text(day.formatted(.dateTime.month(.defaultDigits).day())).monospacedDigit()
                            if submitted { Image(systemName: "checkmark").foregroundStyle(DS.toggle) }
                            else if !info.isWorkday { Text(info.name.map { String($0.prefix(2)) } ?? "休").foregroundStyle(DS.danger) }
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.textSecondary)
                    }
                    .foregroundStyle(selected ? DS.text : DS.textSecondary)
                    .frame(width: 62, height: 44)
                    .background(selected ? DS.selected : .clear, in: .rect(cornerRadius: DS.controlRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct Metrics: View {
    let model: LogModel

    var body: some View {
        let commits = model.activities.reduce(0) { $0 + $1.commits.count }
        HStack(spacing: 12) {
            DSMetric("提交", value: "\(commits) 次", detail: "\(model.activities.count) 个仓库")
            DSMetric("草稿工时", value: "\(hoursText(model.totalHours)) h", detail: "默认 \(hoursText(model.defaultHours)) h")
            DSMetric("未关闭任务", value: "\(model.openTasks.count)", detail: "\(model.projects.count) 个项目")
            DSMetric("状态", value: model.pendingDrafts.isEmpty && model.drafts.contains(where: \.isRecorded) ? "已提交" : model.drafts.isEmpty ? "未生成" : "待提交",
                     detail: model.lastScan.map { "扫描于 \($0.formatted(date: .omitted, time: .shortened))" })
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
                                Text(c.date.formatted(date: .omitted, time: .shortened))
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

/// 一条草稿。
struct DraftCard: View {
    let model: LogModel
    @Binding var entry: DraftEntry
    let onDelete: () -> Void

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if entry.isRecorded {
                        Text(model.task(entry.taskID).map { "#\($0.id) \($0.name)" } ?? "#\(entry.taskID ?? 0)")
                            .font(DS.rowTitle).lineLimit(1)
                    } else {
                        DSPicker(selection: $entry.taskID, options: taskOptions, width: 250)
                            .onChange(of: entry.taskID) { recompute() }
                    }
                    if entry.isRecorded { Tag("已记录", color: DS.success) }
                    if entry.isFallback { Tag("兜底", color: DS.warning) }
                    if entry.isOvertime { Tag("加班", color: .purple) }
                    if entry.isManual { Tag("手动", color: DS.textSecondary) }
                    Spacer(minLength: 0)
                    if !entry.isRecorded {
                        Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.dsGhost).help("删除这一条")
                    }
                }
                if let task = model.task(entry.taskID) {
                    Text("\(task.projectName)" + (entry.repoPaths.isEmpty ? "" : " · " + entry.repoPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")))
                        .font(DS.caption).foregroundStyle(DS.textTertiary).lineLimit(1)
                }
                if entry.isRecorded {
                    Text(entry.work).font(DS.body).foregroundStyle(DS.textSecondary).textSelection(.enabled)
                    Text("消耗 \(hoursText(entry.hours)) h · 剩余 \(hoursText(entry.left)) h").font(DS.caption).foregroundStyle(DS.textTertiary)
                } else {
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
    }

    private var taskOptions: [(Int?, String)] {
        [(nil, "选择任务…")] + model.projects.flatMap { p in
            model.openTasks.filter { $0.projectID == p.id }.map { (Int?.some($0.id), "\(p.name) · #\($0.id) \($0.name)") }
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
        DSPicker(selection: $selection,
                 options: [(nil, "选择任务…")] + model.openTasks.map { (Int?.some($0.id), "\($0.projectName) · #\($0.id) \($0.name)") },
                 width: 300)
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
