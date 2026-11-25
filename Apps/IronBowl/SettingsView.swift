import IronBowlKit
import SwiftUI

/// 设置窗口：左边搜索 + 分组导航，右边灰底白卡（WorkBuddy 风格）。
struct SettingsView: View {
    @Bindable var app: AppModel
    @State private var query = ""

    struct NavGroup: Identifiable {
        let id: String
        let title: String
        let pages: [SettingsPage]
    }

    private var groups: [NavGroup] {
        let core = NavGroup(id: "core", title: "设置", pages: [
            SettingsPage(id: "general", title: "通用", systemImage: "gearshape") { AnyView(GeneralSettings(app: app)) },
            SettingsPage(id: "appearance", title: "外观", systemImage: "paintpalette") { AnyView(AppearanceSettings(app: app)) },
            SettingsPage(id: "worktime", title: "工作时间", systemImage: "clock") { AnyView(WorkTimeSettings(app: app)) },
            SettingsPage(id: "ai", title: "AI 提供者", systemImage: "sparkles") { AnyView(ProviderSettings(app: app)) },
        ])
        let plugins = app.enabledPlugins.compactMap { p -> NavGroup? in
            let pages = p.settingsPages
            return pages.isEmpty ? nil : NavGroup(id: p.id, title: p.title, pages: pages)
        }
        return ([core] + plugins).compactMap { g in
            let q = query.trimmingCharacters(in: .whitespaces)
            let pages = q.isEmpty ? g.pages : g.pages.filter { $0.title.localizedCaseInsensitiveContains(q) || g.title.localizedCaseInsensitiveContains(q) }
            return pages.isEmpty ? nil : NavGroup(id: g.id, title: g.title, pages: pages)
        }
    }

    var body: some View {
        let groups = groups
        let current = groups.flatMap(\.pages).first { $0.id == app.settingsSelection } ?? groups.first?.pages.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
                    TextField("搜索设置项", text: $query).textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(DS.selected, in: .rect(cornerRadius: DS.controlRadius))
                .padding(.horizontal, 12)
                .padding(.top, 40)
                .padding(.bottom, 6)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            DSSidebarSection(group.title)
                            ForEach(group.pages) { page in
                                DSSidebarItem(page.title, systemImage: page.systemImage, selected: page.id == current?.id) {
                                    app.settingsSelection = page.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
            .frame(width: 220)
            .background(DS.sidebar)

            Rectangle().fill(DS.border).frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let current {
                        current.makeView().id(current.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.groupBackground)
        }
        .ignoresSafeArea()
        .frame(width: 900, height: 660)
    }
}

// MARK: 通用

struct GeneralSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        let s = app.settings
        DSSection("启动与显示") {
            DSRow("开机自动启动", description: app.launchError ?? "登录电脑后自动启动饭碗，只在菜单栏显示。") {
                DSToggle(isOn: $app.launchAtLogin)
            }
            DSRow("程序坞图标", description: "饭碗平时只在菜单栏，这里决定要不要在程序坞里出现。") {
                DSPicker(selection: Binding(get: { s[AppKeys.dockMode] }, set: { s[AppKeys.dockMode] = $0; app.applyDockMode() }),
                         options: DockMode.allCases.map { ($0, $0.displayName) })
            }
        }
        DSSection("菜单栏显示", footer: "🍚 图标一直显示；打开的信息按顺序跟在后面，用箭头调整顺序。") {
            MenuBarItemsEditor(app: app)
        }
        DSSection("功能插件") {
            ForEach(app.plugins, id: \.id) { plugin in
                DSRow(plugin.title, description: plugin.isComingSoon ? "即将推出" : nil) {
                    DSToggle(isOn: Binding(get: { app.enabledIDs.contains(plugin.id) }, set: { app.setEnabled(plugin.id, $0) }))
                }
            }
        }
    }
}

struct MenuBarItemsEditor: View {
    let app: AppModel

    var body: some View {
        let s = app.settings
        let selected = s[AppKeys.menuBarItems]
        let all = app.availableMenuBarItems
        let ordered = selected.compactMap { id in all.first { $0.id == id } } + all.filter { !selected.contains($0.id) }
        ForEach(ordered) { item in
            DSRow(item.title, description: selected.contains(item.id) ? "当前显示：\(item.text() ?? "—")" : nil) {
                HStack(spacing: 4) {
                    if let i = selected.firstIndex(of: item.id) {
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.dsGhost).disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.dsGhost).disabled(i == selected.count - 1)
                    }
                    DSToggle(isOn: Binding(
                        get: { s[AppKeys.menuBarItems].contains(item.id) },
                        set: { on in
                            var list = s[AppKeys.menuBarItems].filter { $0 != item.id }
                            if on { list.append(item.id) }
                            s[AppKeys.menuBarItems] = list
                        }
                    ))
                }
            }
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

// MARK: 外观

struct AppearanceSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        DSSection("主题", footer: "主窗口、设置、菜单栏面板和提醒卡片都会一起切换。") {
            DSBlockRow {
                HStack(spacing: 14) {
                    ForEach(AppearanceMode.allCases) { mode in
                        ThemeCard(mode: mode, selected: app.appearance == mode) { app.appearance = mode }
                    }
                }
            }
        }
    }
}

/// 主题选择卡：上面是缩略预览，下面是名字。
private struct ThemeCard: View {
    let mode: AppearanceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 84)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? DS.toggle : DS.border, lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? DS.toggle : DS.textTertiary)
                    Text(mode.displayName).font(DS.body)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            HStack(spacing: 0) {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
            }
        }
    }
}

/// 缩略窗口：侧栏 + 内容 + 几条线。用固定颜色，不受当前外观影响。
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let side = dark ? Color(white: 0.11) : Color(white: 0.965)
        let main = dark ? Color(white: 0.08) : .white
        let line = dark ? Color(white: 0.28) : Color(white: 0.86)
        let ink = dark ? Color(white: 0.92) : Color(white: 0.1)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 2).fill(i == 0 ? line : line.opacity(0.6)).frame(height: 5)
                }
                Spacer()
            }
            .padding(7)
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            .background(side)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 34, height: 6)
                RoundedRectangle(cornerRadius: 4).stroke(line).frame(height: 20)
                RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 50, height: 5)
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(main)
        }
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
        DSSection("工作日与上下班") {
            DSRow("每周上班", description: "点击切换哪几天上班。") {
                HStack(spacing: 4) {
                    ForEach(weekdays, id: \.0) { day, name in
                        let on = s[WorkCalendar.weekdaysKey].contains(day)
                        Button(name) {
                            var list = s[WorkCalendar.weekdaysKey]
                            if on { list.removeAll { $0 == day } } else { list.append(day) }
                            s[WorkCalendar.weekdaysKey] = list.sorted()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? DS.onPrimary : DS.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(on ? DS.primaryFill : DS.well, in: .circle)
                    }
                }
            }
            DSRow("上班时间") { TimeField(value: s.binding(WorkCalendar.startKey)) }
            DSRow("下班时间") { TimeField(value: s.binding(WorkCalendar.endKey)) }
            DSRow("午休", description: "每天默认工时 = 下班 − 上班 − 午休，现在是 \(String(format: "%g", cal.defaultWorkHours)) 小时。") {
                DSStepper(intValue: s.binding(WorkCalendar.lunchMinutesKey), in: 0...180, step: 15) { "\($0) 分钟" }
            }
        }

        DSSection("法定节假日与调休", footer: "holiday-cn 根据国务院放假通知自动更新，免费、无需注册。手动标记优先于联网数据。") {
            DSRow("数据源") {
                DSPicker(selection: s.binding(WorkCalendar.sourceKey), options: HolidaySource.allCases.map { ($0, $0.displayName) })
            }
            DSRow("更新频率") {
                DSPicker(selection: s.binding(WorkCalendar.frequencyKey), options: HolidayUpdateFrequency.allCases.map { ($0, $0.displayName) })
            }
            DSRow("已缓存数据", description: cachedText(cal: cal, s: s)) {
                Button {
                    Task { await cal.updateNow() }
                } label: {
                    if cal.isUpdating { ProgressView().controlSize(.small) } else { Text("立即更新") }
                }
                .buttonStyle(.dsSecondary)
                .disabled(s[WorkCalendar.sourceKey] == .manual)
            }
        }

        DSSection("手动标记某一天") {
            DSRow("日期", description: label(cal.dayInfo(markDate)) + (cal.override(for: markDate) != nil ? "（手动标记）" : "")) {
                DatePicker("", selection: $markDate, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
            }
            DSBlockRow {
                HStack(spacing: 8) {
                    Button("标为放假") { cal.setOverride(markDate, isOffDay: true, note: "手动放假") }.buttonStyle(.dsSecondary)
                    Button("标为上班") { cal.setOverride(markDate, isOffDay: false, note: "手动补班") }.buttonStyle(.dsSecondary)
                    Button("清除手动标记") { cal.setOverride(markDate, isOffDay: nil) }.buttonStyle(.dsGhost)
                        .disabled(cal.override(for: markDate) == nil)
                }
            }
        }
    }

    func cachedText(cal: WorkCalendar, s: SettingsStore) -> String {
        var t = cal.cachedYears.isEmpty ? "还没有节假日数据" : "已缓存 \(cal.cachedYears.map(String.init).joined(separator: "、")) 年"
        if let last = s[WorkCalendar.lastFetchKey] { t += "，更新于 \(last.formatted(date: .abbreviated, time: .shortened))" }
        if let e = cal.lastError { t += "。\(e)" }
        return t
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

/// "09:00" 字符串 ⇄ 时间选择。
struct TimeField: View {
    @Binding var value: String

    var body: some View {
        DatePicker("", selection: Binding(
            get: {
                let p = value.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                value = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
    }
}

// MARK: AI 提供者

struct ProviderSettings: View {
    let app: AppModel

    var body: some View {
        let store = app.providers
        DSSection(footer: "日志页可以临时换别的。所有提供者都以只读方式运行，碰不到你的仓库。") {
            DSRow("默认提供者") {
                DSPicker(selection: Binding(get: { store.defaultKind }, set: { store.defaultKind = $0 }),
                         options: AIProviderKind.allCases.map { ($0, $0.displayName) })
            }
        }
        ForEach(store.configs) { config in
            ProviderEditor(store: store, config: config)
        }
    }
}

struct ProviderEditor: View {
    let store: AIProviderStore
    let config: AIProviderConfig
    @State private var models: [(id: String, name: String)] = []
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        DSSection(config.kind.displayName, footer: config.kind == .codex ? "Codex 需要先在终端运行一次 codex login 登录。" : nil) {
            DSRow("程序路径", description: "留空会用登录 shell 自动查找。") {
                HStack(spacing: 6) {
                    TextField("", text: bind(\.executablePath), prompt: Text("自动查找")).textFieldStyle(.ds).frame(width: 300)
                    Button("查找") {
                        Task { if let p = await Shell.which(config.kind.binaryName) { update { $0.executablePath = p } } }
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
            DSRow("模型", description: "留空用 CLI 自己的默认模型。") {
                HStack(spacing: 6) {
                    TextField("", text: bind(\.model), prompt: Text("默认")).textFieldStyle(.ds).frame(width: 220)
                    if config.kind == .agy {
                        DSPicker(selection: bind(\.model), options: [("", "默认")] + models.map { ($0.id, $0.name) })
                            .task { if models.isEmpty { models = await AIRunner.listModels(config: config) } }
                    }
                }
            }
            DSRow("思考深度") {
                DSPicker(selection: bind(\.effort), options: config.kind.effortOptions.map { ($0, $0.isEmpty ? "默认" : $0) })
            }
            DSRow("超时") {
                DSStepper(intValue: bind(\.timeoutSeconds), in: 15...600, step: 15) { "\($0) 秒" }
            }
            DSRow("额外参数", description: "空格分隔，追加到命令末尾。") {
                TextField("", text: bind(\.extraArgs)).textFieldStyle(.ds).frame(width: 300)
            }
            DSRow("测试", description: testResult ?? "发一条示例提交，看生成结果和耗时。") {
                Button {
                    Task { await test() }
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("测试") }
                }
                .buttonStyle(.dsSecondary)
                .disabled(testing)
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
