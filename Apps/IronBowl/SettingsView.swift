import IronBowlKit
import SwiftUI

struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            GeneralSettings(app: app).tabItem { Label("通用", systemImage: "gearshape") }
            WorkTimeSettings(app: app).tabItem { Label("工作时间", systemImage: "clock") }
            ProviderSettings(app: app).tabItem { Label("AI 提供者", systemImage: "sparkles") }
            ForEach(app.enabledPlugins, id: \.id) { plugin in
                if let view = plugin.makeSettingsView() {
                    view.tabItem { Label(plugin.title, systemImage: plugin.systemImage) }
                }
            }
        }
        .frame(width: 760, height: 600)
    }
}

// MARK: 通用

struct GeneralSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        let s = app.settings
        Form {
            Section("启动与显示") {
                Toggle("开机自动启动", isOn: $app.launchAtLogin)
                if let e = app.launchError { Text(e).font(.caption).foregroundStyle(.red) }
                Picker("程序坞图标", selection: Binding(
                    get: { s[AppKeys.dockMode] },
                    set: { s[AppKeys.dockMode] = $0; app.applyDockMode() }
                )) {
                    ForEach(DockMode.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                MenuBarItemsEditor(app: app)
            } header: {
                Text("菜单栏显示")
            } footer: {
                Hint("🍚 图标一直显示；勾选的信息按顺序跟在后面，用箭头调整顺序。")
            }

            Section("插件") {
                ForEach(app.plugins, id: \.id) { plugin in
                    Toggle(isOn: Binding(get: { app.enabledIDs.contains(plugin.id) },
                                         set: { app.setEnabled(plugin.id, $0) })) {
                        Label(plugin.title + (plugin.isComingSoon ? "（即将推出）" : ""), systemImage: plugin.systemImage)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MenuBarItemsEditor: View {
    let app: AppModel

    var body: some View {
        let s = app.settings
        let selected = s[AppKeys.menuBarItems]
        let all = app.availableMenuBarItems
        // 已选的按顺序在前，没选的在后。
        let ordered = selected.compactMap { id in all.first { $0.id == id } } + all.filter { !selected.contains($0.id) }
        ForEach(ordered) { item in
            HStack {
                Toggle(item.title, isOn: Binding(
                    get: { s[AppKeys.menuBarItems].contains(item.id) },
                    set: { on in
                        var list = s[AppKeys.menuBarItems].filter { $0 != item.id }
                        if on { list.append(item.id) }
                        s[AppKeys.menuBarItems] = list
                    }
                ))
                Spacer()
                if let i = selected.firstIndex(of: item.id) {
                    Text(item.text() ?? "—").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0)
                    Button { move(i, 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == selected.count - 1)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    func move(_ i: Int, _ delta: Int) {
        var list = app.settings[AppKeys.menuBarItems]
        let j = i + delta
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        app.settings[AppKeys.menuBarItems] = list
    }
}

// MARK: 工作时间

struct WorkTimeSettings: View {
    let app: AppModel
    @State private var markDate = Date()

    private let weekdays = [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")]

    var body: some View {
        let s = app.settings
        let cal = app.workCalendar
        Form {
            Section("工作日与上下班") {
                HStack {
                    Text("每周上班")
                    Spacer()
                    ForEach(weekdays, id: \.0) { day, name in
                        let on = s[WorkCalendar.weekdaysKey].contains(day)
                        Button(name) {
                            var list = s[WorkCalendar.weekdaysKey]
                            if on { list.removeAll { $0 == day } } else { list.append(day) }
                            s[WorkCalendar.weekdaysKey] = list.sorted()
                        }
                        .buttonStyle(.plain)
                        .frame(width: 30, height: 26)
                        .glassEffect(on ? .regular.tint(Color.accentColor.opacity(0.4)).interactive() : .regular.interactive(),
                                     in: .rect(cornerRadius: 8))
                    }
                }
                TimeField(title: "上班时间", value: s.binding(WorkCalendar.startKey))
                TimeField(title: "下班时间", value: s.binding(WorkCalendar.endKey))
                Stepper("午休 \(s[WorkCalendar.lunchMinutesKey]) 分钟", value: s.binding(WorkCalendar.lunchMinutesKey), in: 0...180, step: 15)
                LabeledContent("每天默认工时", value: "\(String(format: "%g", cal.defaultWorkHours)) 小时")
            }

            Section {
                Picker("数据源", selection: s.binding(WorkCalendar.sourceKey)) {
                    ForEach(HolidaySource.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("更新频率", selection: s.binding(WorkCalendar.frequencyKey)) {
                    ForEach(HolidayUpdateFrequency.allCases) { Text($0.displayName).tag($0) }
                }
                HStack {
                    let years = cal.cachedYears
                    Text(years.isEmpty ? "还没有节假日数据" : "已缓存：\(years.map(String.init).joined(separator: "、")) 年")
                        .foregroundStyle(.secondary)
                    if let last = s[WorkCalendar.lastFetchKey] {
                        Text("· 更新于 \(last.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await cal.updateNow() }
                    } label: {
                        if cal.isUpdating { ProgressView().controlSize(.small) } else { Text("立即更新") }
                    }
                    .disabled(s[WorkCalendar.sourceKey] == .manual)
                }
                .font(.callout)
                if let e = cal.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("法定节假日与调休")
            } footer: {
                Hint("holiday-cn 根据国务院放假通知自动更新，免费、无需注册。手动标记优先于联网数据。")
            }

            Section("手动标记某一天") {
                DatePicker("日期", selection: $markDate, displayedComponents: .date)
                let info = cal.dayInfo(markDate)
                LabeledContent("当前", value: label(info) + (cal.override(for: markDate) != nil ? "（手动）" : ""))
                HStack {
                    Button("标为放假") { cal.setOverride(markDate, isOffDay: true, note: "手动放假") }
                    Button("标为上班") { cal.setOverride(markDate, isOffDay: false, note: "手动补班") }
                    Button("清除手动标记") { cal.setOverride(markDate, isOffDay: nil) }
                        .disabled(cal.override(for: markDate) == nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    func label(_ info: DayInfo) -> String {
        switch info.kind {
        case .workday: "工作日"
        case .makeupWorkday: "调休上班" + (info.name.map { "（\($0)）" } ?? "")
        case .weekend: "休息日"
        case .holiday: "放假" + (info.name.map { "（\($0)）" } ?? "")
        }
    }
}

struct TimeField: View {
    let title: String
    @Binding var value: String

    var body: some View {
        DatePicker(title, selection: Binding(
            get: {
                let p = value.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                value = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
    }
}

// MARK: AI 提供者

struct ProviderSettings: View {
    let app: AppModel

    var body: some View {
        let store = app.providers
        Form {
            Section {
                Picker("默认提供者", selection: Binding(get: { store.defaultKind }, set: { store.defaultKind = $0 })) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                Hint("日志页工具栏可以临时换别的。所有提供者都以只读方式运行，碰不到你的仓库。")
            }
            ForEach(store.configs) { config in
                ProviderEditor(store: store, config: config)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProviderEditor: View {
    let store: AIProviderStore
    let config: AIProviderConfig
    @State private var models: [(id: String, name: String)] = []
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Section(config.kind.displayName) {
            HStack {
                TextField("程序路径", text: bind(\.executablePath), prompt: Text("留空自动查找"))
                Button("自动查找") {
                    Task {
                        if let p = await Shell.which(config.kind.binaryName) { update { $0.executablePath = p } }
                    }
                }
            }
            HStack {
                TextField("模型", text: bind(\.model), prompt: Text("留空用默认模型"))
                if config.kind == .agy {
                    Menu("选择") {
                        ForEach(models, id: \.id) { m in Button(m.name) { update { $0.model = m.id } } }
                    }
                    .frame(width: 80)
                    .task { if models.isEmpty { models = await AIRunner.listModels(config: config) } }
                }
            }
            Picker("思考深度", selection: bind(\.effort)) {
                ForEach(config.kind.effortOptions, id: \.self) { Text($0.isEmpty ? "默认" : $0).tag($0) }
            }
            Stepper("超时 \(config.timeoutSeconds) 秒", value: bind(\.timeoutSeconds), in: 15...600, step: 15)
            TextField("额外参数", text: bind(\.extraArgs), prompt: Text("空格分隔，追加到命令末尾"))
            HStack {
                Button {
                    Task { await test() }
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("测试") }
                }
                .buttonStyle(.glass)
                .disabled(testing)
                if let testResult { Text(testResult).font(.callout).textSelection(.enabled) }
            }
            if config.kind == .codex {
                Hint("Codex 需要先在终端运行一次 `codex login` 登录。")
            }
        }
    }

    func bind<V>(_ path: WritableKeyPath<AIProviderConfig, V>) -> Binding<V> {
        Binding(get: { store.config(config.kind)[keyPath: path] }, set: { v in update { $0[keyPath: path] = v } })
    }

    func update(_ change: (inout AIProviderConfig) -> Void) {
        var c = store.config(config.kind)
        change(&c)
        store.update(c)
    }

    func test() async {
        testing = true
        defer { testing = false }
        let schema = #"{"type":"object","additionalProperties":false,"required":["work"],"properties":{"work":{"type":"string"}}}"#
        let prompt = "把这条 git 提交改写成一句中文工作日志，写业务功能，不写技术细节：fix(driver): 取消预约弹窗不再被高德地图的文字和「查看大图」遮挡"
        do {
            let r = try await AIRunner.run(config: store.config(config.kind), prompt: prompt, schema: schema)
            let obj = try JSONSerialization.jsonObject(with: r.json) as? [String: Any]
            testResult = "✅ \(Int(r.duration)) 秒：\(obj?["work"] as? String ?? "")"
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}
