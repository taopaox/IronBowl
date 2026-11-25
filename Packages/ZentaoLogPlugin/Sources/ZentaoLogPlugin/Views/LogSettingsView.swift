import AppKit
import IronBowlKit
import SwiftUI

/// 插件设置页。注意不能再套 TabView：设置窗口本身就是 TabView，嵌套后 macOS 会把子页摊到窗口工具栏上。
struct LogSettingsView: View {
    let model: LogModel
    let scheduler: LogReminderScheduler
    @State private var page: Page = .zentao

    enum Page: String, CaseIterable, Identifiable {
        case zentao = "禅道", repos = "仓库与映射", generate = "生成", reminder = "提醒"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)

            switch page {
            case .zentao: ZentaoAccountSettings(model: model)
            case .repos: RepoSettings(model: model)
            case .generate: GenerateSettings(model: model)
            case .reminder: ReminderSettings(model: model, scheduler: scheduler)
            }
        }
    }
}

// MARK: 禅道账号

struct ZentaoAccountSettings: View {
    let model: LogModel
    @State private var showPassword = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let s = model.settings
        Form {
            Section {
                TextField("禅道地址", text: s.binding(LogKeys.baseURL))
                TextField("账号", text: s.binding(LogKeys.account))
                HStack {
                    if showPassword {
                        TextField("密码", text: s.binding(LogKeys.password))
                    } else {
                        SecureField("密码", text: s.binding(LogKeys.password))
                    }
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
                Hint("账号密码以明文保存在本机数据库（~/Library/Application Support/IronBowl/ironbowl.sqlite），不会进入代码仓库。")
            } header: { Text("禅道账号") }

            Section {
                HStack {
                    Button {
                        Task { await test() }
                    } label: {
                        if testing { ProgressView().controlSize(.small) } else { Text("测试连接") }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(testing)
                    Button("打开接口日志") { NSWorkspace.shared.open(ZentaoLog.url) }
                        .buttonStyle(.glass)
                }
                if let testResult { Text(testResult).font(.callout).textSelection(.enabled) }
                Hint("每次请求禅道的原始返回都会写进接口日志（不含密码），接口对不上时把日志给我看。")
            } header: { Text("连接") }

            Section {
                Picker("兜底任务", selection: s.binding(LogKeys.fallbackTaskID)) {
                    Text("未设置").tag(Int?.none)
                    ForEach(model.openTasks) { t in Text("#\(t.id) \(t.name)").tag(Int?.some(t.id)) }
                }
                Hint("AI 找不到合适任务时记到这里，草稿里会标黄。默认选名字里带「杂项」的任务。")
            } header: { Text("兜底任务") }
        }
        .formStyle(.grouped)
        .task { if model.tasks.isEmpty { await model.loadTasks() } }
    }

    func test() async {
        testing = true
        defer { testing = false }
        do {
            let client = try model.zentao()
            try await client.login()
            await model.loadTasks()
            testResult = "✅ 登录成功，拉到 \(model.tasks.count) 个任务（\(model.openTasks.count) 个未关闭，\(model.projects.count) 个项目）"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

// MARK: 仓库与映射

struct RepoSettings: View {
    let model: LogModel
    @State private var active: [String: [String]] = [:]
    @State private var loading = false
    @State private var suggesting = false
    @State private var showAll = false

    var body: some View {
        let s = model.settings
        Form {
            Section {
                HStack {
                    TextField("扫描根目录", text: s.binding(LogKeys.gitRoot))
                    Button("选择…") { chooseRoot() }
                }
                Stepper("向下找 \(s[LogKeys.gitDepth]) 层", value: s.binding(LogKeys.gitDepth), in: 1...4)
                TextField("提交作者邮箱", text: s.binding(LogKeys.authorEmail), prompt: Text("留空则读取 git 全局邮箱"))
                Picker("扫描方式", selection: s.binding(LogKeys.scanMode)) {
                    ForEach(ScanMode.allCases) { Text($0.displayName).tag($0) }
                }
                if s[LogKeys.scanMode] == .onDemandPlusInterval {
                    Stepper("每 \(s[LogKeys.scanInterval]) 分钟扫描一次", value: s.binding(LogKeys.scanInterval), in: 5...120, step: 5)
                }
            } header: { Text("扫描") }

            Section {
                HStack {
                    Button {
                        Task { await load() }
                    } label: {
                        if loading { ProgressView().controlSize(.small) } else { Text("扫描最近 30 天的仓库") }
                    }
                    Button {
                        Task { await suggest() }
                    } label: {
                        if suggesting { ProgressView().controlSize(.small) } else { Label("AI 推荐对应项目", systemImage: "sparkles") }
                    }
                    .disabled(active.isEmpty || model.projects.isEmpty || suggesting)
                    Spacer()
                    Toggle("显示全部仓库", isOn: $showAll).toggleStyle(.checkbox)
                }
                if model.projects.isEmpty {
                    Hint("还没拉到禅道任务，先去「禅道」页测试连接。")
                }
                ForEach(rows, id: \.self) { repo in
                    RepoRow(model: model, repo: repo, recent: active[repo] ?? [])
                }
            } header: {
                Text("仓库 → 禅道项目")
            } footer: {
                Hint("只有对应了项目的仓库，AI 才知道该从哪些任务里挑。打开「发送代码改动」会把该仓库的 diff（截断）一起发给 AI。")
            }
        }
        .formStyle(.grouped)
        .task {
            if active.isEmpty { await load() }
            if model.tasks.isEmpty { await model.loadTasks() }
        }
    }

    var rows: [String] {
        let maps = model.mappings
        let all = showAll ? model.repos() : Array(Set(active.keys).union(maps.keys.filter { maps[$0]?.projectID != nil }))
        return all.sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() }
    }

    func load() async {
        loading = true
        defer { loading = false }
        let email = await model.authorEmail()
        active = await GitScanner.recentlyActive(repos: model.repos(), authorEmail: email, days: 30)
    }

    func suggest() async {
        suggesting = true
        defer { suggesting = false }
        let unmapped = active.filter { model.mappings[$0.key]?.projectID == nil }
        let picks = await model.suggestMappings(repos: unmapped.isEmpty ? active : unmapped)
        for (repo, projectID) in picks {
            if let p = model.projects.first(where: { $0.id == projectID }) { model.setMapping(repo: repo, project: p) }
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: model.settings[LogKeys.gitRoot])
        if panel.runModal() == .OK, let url = panel.url { model.settings[LogKeys.gitRoot] = url.path }
    }
}

struct RepoRow: View {
    let model: LogModel
    let repo: String
    let recent: [String]

    var body: some View {
        let m = model.mappings[repo]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text((repo as NSString).lastPathComponent).font(.body.weight(.medium))
                if !recent.isEmpty { Tag("近 30 天 \(recent.count)+ 次", color: .secondary) }
                Spacer()
                Picker("项目", selection: Binding(
                    get: { m?.projectID },
                    set: { id in model.setMapping(repo: repo, project: model.projects.first { $0.id == id }) }
                )) {
                    Text("未关联").tag(Int?.none)
                    ForEach(model.projects, id: \.id) { Text($0.name).tag(Int?.some($0.id)) }
                    if let id = m?.projectID, !model.projects.contains(where: { $0.id == id }) {
                        Text(m?.projectName ?? "#\(id)").tag(Int?.some(id))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            HStack(spacing: 16) {
                Toggle("排除", isOn: Binding(get: { m?.excluded ?? false },
                                           set: { v in model.updateMapping(repo: repo) { $0.excluded = v } }))
                Toggle("发送代码改动", isOn: Binding(get: { m?.sendDiff ?? false },
                                               set: { v in model.updateMapping(repo: repo) { $0.sendDiff = v } }))
                if let first = recent.first {
                    Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

// MARK: 生成

struct GenerateSettings: View {
    let model: LogModel

    var body: some View {
        let s = model.settings
        Form {
            Section {
                TextEditor(text: s.binding(LogKeys.prompt))
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 260)
                HStack {
                    Hint("占位符：{{date}} 日期，{{activity}} 提交明细，{{tasks}} 可选任务和兜底任务。")
                    Spacer()
                    Button("恢复默认") { s[LogKeys.prompt] = DraftGenerator.defaultPrompt }
                }
            } header: { Text("提示词") }

            Section {
                Stepper("加班默认 \(hoursText(s[LogKeys.overtimeDefaultHours])) 小时",
                        value: s.binding(LogKeys.overtimeDefaultHours), in: 0.5...12, step: 0.5)
                Toggle("非工作日的工时默认算加班", isOn: s.binding(LogKeys.offDayOvertime))
            } header: { Text("工时") }
        }
        .formStyle(.grouped)
    }
}

// MARK: 提醒

struct ReminderSettings: View {
    let model: LogModel
    let scheduler: LogReminderScheduler

    var body: some View {
        let s = model.settings
        Form {
            Section {
                ForEach(Array(s[LogKeys.reminderTimes].enumerated()), id: \.offset) { index, time in
                    HStack {
                        DatePicker("提醒时间 \(index + 1)", selection: Binding(
                            get: { Self.date(from: time) },
                            set: { d in
                                var times = s[LogKeys.reminderTimes]
                                times[index] = Self.string(from: d)
                                s[LogKeys.reminderTimes] = times
                            }
                        ), displayedComponents: .hourAndMinute)
                        Button(role: .destructive) {
                            var times = s[LogKeys.reminderTimes]
                            times.remove(at: index)
                            s[LogKeys.reminderTimes] = times
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加提醒时间", systemImage: "plus") {
                    s[LogKeys.reminderTimes] = s[LogKeys.reminderTimes] + ["17:30"]
                }
                Toggle("非工作日也提醒", isOn: s.binding(LogKeys.remindOnOffDays))
                Stepper("稍后提醒间隔 \(s[LogKeys.snoozeMinutes]) 分钟", value: s.binding(LogKeys.snoozeMinutes), in: 5...120, step: 5)
                Hint("当天已提交日志、或点了「今天不写」就不再提醒。")
            } header: { Text("什么时候提醒") }

            Section {
                Picker("提醒样式", selection: s.binding(LogKeys.reminderStyle)) {
                    ForEach(ReminderStyle.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                HStack {
                    ForEach(ReminderStyle.allCases) { style in
                        Button("测试：\(style.shortName)") { scheduler.preview(style: style) }
                            .buttonStyle(.glass)
                    }
                }
                Hint("系统通知是横幅还是常驻，由「系统设置 → 通知 → 饭碗」决定；玻璃卡片和弹框由饭碗自己画，不操作不会消失，勿扰模式下也会出现。")
            } header: { Text("怎么提醒") }
        }
        .formStyle(.grouped)
    }

    static func date(from hhmm: String) -> Date {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 18, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }

    static func string(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

extension ReminderStyle {
    var shortName: String {
        switch self {
        case .system: "系统通知"
        case .cornerCard: "右上角卡片"
        case .centerDialog: "中央弹框"
        }
    }
}
