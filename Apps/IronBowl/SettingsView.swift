import AppKit
import IronBowlKit
import SwiftUI
import UniformTypeIdentifiers

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
            SettingsPage(id: "web", title: "网页与内存", systemImage: "globe") { AnyView(WebSettings(app: app)) },
            SettingsPage(id: "ai", title: "AI 提供者", systemImage: "sparkles") { AnyView(ProviderSettings(app: app)) },
            SettingsPage(id: "about", title: "关于", systemImage: "info.circle") { AnyView(AboutSettings(app: app)) },
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
                .font(DS.font(14))
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("饭碗 \(Bundle.main.displayVersion)")
                        .font(DS.font(11.5))
                        .monospacedDigit()
                        .foregroundStyle(DS.textTertiary)
                        .help("当前版本 \(Bundle.main.fullVersion)")

                    DSSloganView(style: .sidebar)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
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
        .overlay(alignment: .top) { WindowTitleBarArea(height: 40) }
        .ignoresSafeArea()
        .frame(width: DS.s(900), height: DS.s(660))
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
    }
}

// MARK: 通用

struct GeneralSettings: View {
    @Bindable var app: AppModel
    @State private var avatarError: String?

    var body: some View {
        let s = app.settings
        let profile = app.userProfile
        DSSection("个人资料", footer: "显示在主窗口左下角；也可以直接点击左下角头像或姓名快速编辑。") {
            DSRow("头像 / Logo", description: profile.hasCustomAvatar ? "已使用自定义图片" : "默认使用应用图标") {
                HStack(spacing: 8) {
                    UserProfileAvatarView(image: profile.avatarImage, size: DS.s(30))
                    Button("选择图片…") {
                        guard let url = UserProfileAvatarPicker.pickLocalImageURL() else { return }
                        do {
                            try profile.saveAvatar(from: url)
                            avatarError = nil
                        } catch {
                            avatarError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.dsSecondary)
                    if profile.hasCustomAvatar {
                        Button("恢复默认") {
                            profile.clearAvatar()
                            avatarError = nil
                        }
                        .buttonStyle(.dsGhost)
                    }
                }
            }
            if let avatarError {
                DSBlockRow {
                    DSBanner(.danger, avatarError)
                }
            }
            DSRow("显示姓名", description: "留空时默认使用系统用户名（\(profile.fallbackDisplayName)）。") {
                TextField(
                    "",
                    text: Binding(get: { profile.displayName }, set: { profile.displayName = $0 }),
                    prompt: Text(profile.fallbackDisplayName)
                )
                .textFieldStyle(.ds)
                .frame(width: DS.s(240))
            }
            DSRow("个人标语", description: "显示在左下角姓名下方，留空时不显示。") {
                TextField(
                    "",
                    text: Binding(get: { profile.slogan }, set: { profile.slogan = $0 }),
                    prompt: Text("写一句个人签名或标语")
                )
                .textFieldStyle(.ds)
                .frame(width: DS.s(240))
            }
        }
        DSSection("启动与显示") {
            DSLaunchAtLoginRow(controller: app.launchAtLogin, appName: "饭碗")
            DSRow("程序坞图标", description: "饭碗平时只在菜单栏，这里决定要不要在程序坞里出现。") {
                DSPicker(
                    selection: Binding(get: { s[AppKeys.dockMode] }, set: { s[AppKeys.dockMode] = $0; app.applyDockMode() }),
                    options: DockMode.allCases.map { DSPickerOption($0, title: $0.displayName, subtitle: $0.detail) }
                )
            }
        }
        DSSection("菜单栏显示", footer: "饭碗图标一直显示；打开的信息按顺序跟在后面，用箭头调整顺序。") {
            MenuBarItemsEditor(app: app)
        }
        DSSection("功能插件") {
            ForEach(app.plugins, id: \.id) { plugin in
                DSRow(plugin.title, description: plugin.isComingSoon ? "即将推出" : nil) {
                    DSToggle(isOn: Binding(get: { app.enabledIDs.contains(plugin.id) }, set: { app.setEnabled(plugin.id, $0) }))
                }
            }
        }
        DataBackupSettingsSection(app: app)
    }
}

private struct DataBackupSettingsSection: View {
    let app: AppModel
    @State private var isBusy = false
    @State private var feedback: (isError: Bool, text: String)?
    @State private var pendingRestoreURL: URL?

    var body: some View {
        DSSection("数据备份与恢复", footer: "备份包包含全部设置、禅道日报与草稿、周报月报、待办备忘、随手便签、AI 对话历史以及自定义头像与图标；导入前会自动在本地留存当前库快照。") {
            DSRow("导出数据备份", description: "打包为 .zip 压缩文件，方便迁移到新电脑或定期归档。") {
                Button("导出备份包…") {
                    exportBackup()
                }
                .buttonStyle(.dsSecondary)
                .disabled(isBusy)
            }
            DSRow("从备份包恢复", description: "选择先前导出的 .zip 备份包覆盖恢复本地数据。") {
                Button("导入并恢复…") {
                    chooseRestoreFile()
                }
                .buttonStyle(.dsSecondary)
                .disabled(isBusy)
            }
            DSRow("本地数据目录", description: AppPaths.supportDirectory.path) {
                Button("在访达中打开") {
                    NSWorkspace.shared.open(AppPaths.supportDirectory)
                }
                .buttonStyle(.dsGhost)
            }
            if let feedback {
                DSBlockRow {
                    DSBanner(feedback.isError ? .danger : .success, feedback.text)
                }
            }
        }
        .alert("确认从备份包恢复？", isPresented: Binding(
            get: { pendingRestoreURL != nil },
            set: { if !$0 { pendingRestoreURL = nil } }
        )) {
            Button("确认恢复", role: .destructive) {
                if let url = pendingRestoreURL {
                    pendingRestoreURL = nil
                    performRestore(from: url)
                }
            }
            Button("取消", role: .cancel) {
                pendingRestoreURL = nil
            }
        } message: {
            Text("恢复操作将使用「\(pendingRestoreURL?.lastPathComponent ?? "")」中的数据替换当前数据库内容（恢复前会自动留存本地安全快照）。")
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "IronBowl-Backup-\(fmt.string(from: Date())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBusy = true
        feedback = nil
        let db = app.database
        let version = Bundle.main.displayVersion
        Task {
            defer { isBusy = false }
            do {
                let manifest = try await DataBackupService.exportBackup(database: db, appVersion: version, to: url)
                feedback = (false, "已导出备份包（设置 \(manifest.settingsCount) 项 · 待办 \(manifest.todosCount) 条 · 便签 \(manifest.notesCount) 条）")
            } catch {
                feedback = (true, error.localizedDescription)
            }
        }
    }

    private func chooseRestoreFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
    }

    private func performRestore(from url: URL) {
        isBusy = true
        feedback = nil
        let db = app.database
        let migrations = app.plugins.flatMap(\.migrations)
        Task {
            defer { isBusy = false }
            do {
                let manifest = try await DataBackupService.restoreBackup(from: url, into: db, migrations: migrations)
                app.reloadAllStoresAfterRestore()
                feedback = (false, "恢复成功（设置 \(manifest.settingsCount) 项 · 待办 \(manifest.todosCount) 条 · 便签 \(manifest.notesCount) 条），所有视图已重载。")
            } catch {
                feedback = (true, error.localizedDescription)
            }
        }
    }
}

// MARK: 关于

struct AboutSettings: View {
    let app: AppModel
    @State private var copiedVersion = false

    var body: some View {
        DSSection("关于") {
            DSBlockRow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image("AppLogo")
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: DS.s(36), height: DS.s(36))

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("\(AppBrand.name) \(AppBrand.englishName)")
                                    .font(DS.font(15, .semibold))
                                Text(Bundle.main.displayVersion)
                                    .font(DS.font(11, .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(DS.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(DS.well, in: .capsule)
                            }
                            Text("macOS 本地效率工作台")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                    }

                    DSSloganView(style: .banner)
                }
            }
            DSRow("当前版本", description: "饭碗工作台 · \(Bundle.main.fullVersion)") {
                Button(copiedVersion ? "已复制" : "复制版本信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("饭碗 \(Bundle.main.fullVersion)", forType: .string)
                    copiedVersion = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedVersion = false
                    }
                }
                .buttonStyle(.dsSecondary)
            }
            AppUpdateSettingsRows(updater: app.updater)
        }
    }
}

struct MenuBarItemsEditor: View {
    let app: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let s = app.settings
        let selected = s[AppKeys.menuBarItems]
        let all = app.availableMenuBarItems
        let availableIDs = Set(all.map(\.id))
        let activeSelected = selected.filter { availableIDs.contains($0) }
        let ordered = activeSelected.compactMap { id in all.first { $0.id == id } } + all.filter { !activeSelected.contains($0.id) }
        DSRow("当前预览", description: "双行微缩仪表卡会实时渲染在系统菜单栏右侧。") {
            Image(nsImage: MenuBarCardRenderer.renderImage(
                segments: app.menuBarCardSegments,
                iconImage: NSImage(named: "MenuBarIcon"),
                isDark: colorScheme == .dark
            ))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DS.well, in: .rect(cornerRadius: 8))
        }
        ForEach(ordered) { item in
            DSRow(item.title, description: activeSelected.contains(item.id) ? "当前显示：\(item.text() ?? "—")" : nil) {
                HStack(spacing: 4) {
                    if let i = activeSelected.firstIndex(of: item.id) {
                        Button { move(item.id, -1, in: activeSelected) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.dsGhost).disabled(i == 0)
                        Button { move(item.id, 1, in: activeSelected) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.dsGhost).disabled(i == activeSelected.count - 1)
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

    func move(_ id: String, _ delta: Int, in activeSelected: [String]) {
        guard let activeIndex = activeSelected.firstIndex(of: id) else { return }
        let targetActiveIndex = activeIndex + delta
        guard activeSelected.indices.contains(targetActiveIndex) else { return }
        let neighborID = activeSelected[targetActiveIndex]
        var list = app.settings[AppKeys.menuBarItems]
        guard let i = list.firstIndex(of: id), let j = list.firstIndex(of: neighborID) else { return }
        list.swapAt(i, j)
        app.settings[AppKeys.menuBarItems] = list
    }
}

// MARK: 外观

struct AppearanceSettings: View {
    @Bindable var app: AppModel

    var body: some View {
        DSAppearanceSettingsView(
            settings: app.settings,
            onAppearanceChange: { app.applyAppearance() },
            onFontScaleChange: { DS.fontScale = app.settings[AppKeys.fontScale] }
        )
    }
}

// MARK: 网页与内存

struct WebSettings: View {
    @Bindable var app: AppModel
    @State private var confirmClearCache = false
    @State private var statusNotice: String?

    private let idleOptions: [DSPickerOption<Int>] = [
        DSPickerOption(5, title: "5 分钟", subtitle: "更快回收后台网页内存，适合内存紧张时。"),
        DSPickerOption(15, title: "15 分钟（推荐）", subtitle: "兼顾内存节省与切换流畅度。", triggerTitle: "15 分钟（推荐）"),
        DSPickerOption(30, title: "30 分钟", subtitle: "短时间切走仍保持网页活跃。"),
        DSPickerOption(60, title: "60 分钟", subtitle: "长时间保留后台网页状态，减少恢复等待。"),
        DSPickerOption(0, title: "不按时间（仅按上限）", subtitle: "后台网页不按闲置时间休眠，仅受同时保活数量限制。"),
    ]

    var body: some View {
        let web = app.webSessions
        DSSection("内存节省（墓碑机制）", footer: "仿 Chrome 内存节省：后台页面进入休眠后释放渲染进程，点击切回自动恢复登录态与访问历史；正在播放音视频或开会的网页会自动跳过。") {
            DSRow("自动休眠后台网页", description: "所有内嵌网页的插件统一启用墓碑机制。") {
                DSToggle(isOn: Binding(get: { web.tombstoneEnabled }, set: { web.tombstoneEnabled = $0 }))
            }
            DSRow("后台闲置休眠时长", description: "切到别的页面后，超过该时间自动释放内存。") {
                DSPicker(
                    selection: Binding(get: { web.idleMinutes }, set: { web.idleMinutes = $0 }),
                    options: idleOptions
                )
                .disabled(!web.tombstoneEnabled)
            }
            DSRow("最多同时保活页数", description: "超出后优先休眠最久未访问的后台网页。") {
                DSStepper(
                    intValue: Binding(get: { web.maxLiveCount }, set: { web.maxLiveCount = $0 }),
                    in: 0...12,
                    step: 1
                ) { $0 == 0 ? "不限" : "\($0) 页" }
                .disabled(!web.tombstoneEnabled)
            }
        }

        DSSection("当前会话状态") {
            DSRow("网页进程统计", description: statusNotice ?? "正在保活 \(web.liveCount) 个 · 已休眠 \(web.tombstonedCount) 个") {
                HStack(spacing: 8) {
                    Button("立即休眠后台网页") {
                        Task {
                            let n = await web.suspendAllInactive()
                            statusNotice = n > 0 ? "已休眠 \(n) 个后台网页" : "没有可休眠的后台网页"
                        }
                    }
                    .buttonStyle(.dsSecondary)

                    Button("全部刷新") {
                        web.reloadAllActive()
                        statusNotice = "已刷新所有活跃网页"
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
            DSRow("清除全部网页缓存", description: "清空所有内嵌网页的 Cookie 与本地存储（需重新登录）。") {
                Button("清除登录缓存") { confirmClearCache = true }
                    .buttonStyle(.dsSecondary)
            }
        }
        .alert("清除全部网页缓存？", isPresented: $confirmClearCache) {
            Button("清除", role: .destructive) {
                Task {
                    await web.clearWebsiteData()
                    statusNotice = "已清除全部网页缓存并刷新"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会清空所有内嵌网页的 Cookie 与本地存储，飞书等网站需要重新登录。")
        }
    }
}

// MARK: 工作时间

struct WorkTimeSettings: View {
    let app: AppModel

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
                            app.scheduler.recomputeNextRuns()
                        }
                        .buttonStyle(.plain)
                        .font(DS.font(13.5, on ? .semibold : .regular))
                        .foregroundStyle(on ? DS.onPrimary : DS.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(on ? DS.primaryFill : DS.well, in: .circle)
                    }
                }
            }
            DSRow("上班时间") { TimeField(value: workTimeBinding(WorkCalendar.startKey)) }
            DSRow("下班时间") { TimeField(value: workTimeBinding(WorkCalendar.endKey)) }
            DSRow("午休", description: "每天默认工时 = 下班 − 上班 − 午休，现在是 \(String(format: "%g", cal.defaultWorkHours)) 小时。") {
                DSStepper(intValue: s.binding(WorkCalendar.lunchMinutesKey), in: 0...180, step: 15) { "\($0) 分钟" }
            }
            DSRow("弹性时间", description: "上班早到几分钟就早走几分钟，晚到几分钟就晚走几分钟，最多这么多。需要拿到当天的上班打卡时间才生效。") {
                DSStepper(intValue: workTimeBinding(WorkCalendar.flexMinutesKey), in: 0...120, step: 5) { $0 == 0 ? "不弹性" : "\($0) 分钟" }
            }
        }

        DingTalkAttendanceSettings(app: app)

        DSHolidaySettingsView(workCalendar: cal, settings: s)
    }

    private func workTimeBinding<Value>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(
            get: { app.settings[key] },
            set: { newValue in
                app.settings[key] = newValue
                app.scheduler.recomputeNextRuns()
            }
        )
    }
}

/// 钉钉考勤：用 dws 读取每天的上班打卡时间，按弹性规则算下班时间。
struct DingTalkAttendanceSettings: View {
    let app: AppModel

    var body: some View {
        let s = app.settings
        let cal = app.workCalendar
        let enabled = s[WorkCalendar.dingtalkEnabledKey]
        DSSection("钉钉考勤", footer: "通过钉钉官方命令行工具 dws（npm install -g dingtalk-workspace-cli）只读查询本人打卡记录，需要先在终端运行 dws auth login 登录。开启后，上班时段内每 5 分钟检查一次，拿到当天打卡后不再查询。") {
            DSRow("自动同步上班打卡", description: "用当天第一次上班打卡时间折算下班时间，首页、侧栏、菜单栏倒计时与禅道日志的加班分界都会跟着变。") {
                DSToggle(isOn: Binding(get: { enabled }, set: { on in
                    s[WorkCalendar.dingtalkEnabledKey] = on
                    if on { Task { await cal.syncAttendance() } }
                }))
            }
            if enabled {
                DSRow("dws 路径", description: "留空会用登录 shell 自动查找。") {
                    HStack(spacing: 6) {
                        TextField("", text: s.binding(WorkCalendar.dingtalkPathKey), prompt: Text("自动查找")).textFieldStyle(.ds).frame(width: 300)
                        Button("查找") {
                            Task { if let p = await DingTalkAttendance.locateExecutable() { s[WorkCalendar.dingtalkPathKey] = p } }
                        }
                        .buttonStyle(.dsSecondary)
                    }
                }
                DSRow("今天", description: statusText) {
                    HStack(spacing: 6) {
                        switch cal.attendanceIssue {
                        case .missingExecutable?:
                            Button("在终端安装并登录") { DingTalkAttendance.openSetupInTerminal() }
                                .buttonStyle(.dsSecondary)
                        case .notLoggedIn?:
                            Button("在终端登录") { DingTalkAttendance.openSetupInTerminal() }
                                .buttonStyle(.dsSecondary)
                        default:
                            EmptyView()
                        }
                        Button {
                            Task { await cal.syncAttendance() }
                        } label: {
                            if cal.isSyncingAttendance { ProgressView().controlSize(.small) } else { Text(cal.attendanceIssue == nil ? "立即同步" : "重试") }
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(cal.isSyncingAttendance)
                    }
                }
            }
        }
    }

    private var statusText: String {
        let cal = app.workCalendar
        let today = app.now
        if let error = cal.attendanceError { return "❌ \(error)。现在按 \(cal.scheduleText(on: today)) 计算。" }
        if cal.clockIn(on: today) != nil { return cal.scheduleText(on: today) }
        if cal.attendanceLastSync != nil { return "钉钉上还没有今天的上班打卡，按 \(cal.scheduleText(on: today)) 计算。" }
        return "还没同步，按 \(cal.scheduleText(on: today)) 计算。"
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
                DSPicker(
                    selection: Binding(get: { store.defaultKind }, set: { store.defaultKind = $0 }),
                    options: AIProviderKind.allCases.map { DSPickerOption($0, title: $0.displayName, subtitle: $0.detail) }
                )
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
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let models = store.models(for: config.kind)
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
                    DSPicker(
                        selection: bind(\.model),
                        options: [DSPickerOption("", title: "默认", subtitle: "使用 CLI 默认模型。")] + models.map {
                            DSPickerOption($0.id, title: $0.name, subtitle: $0.detail ?? ($0.id == $0.name ? nil : $0.id))
                        }
                    )
                    .task { await store.loadModels(for: config.kind) }
                }
            }
            DSRow("思考深度") {
                DSPicker(
                    selection: bind(\.effort),
                    options: config.kind.effortOptions.map {
                        DSPickerOption($0, title: AIProviderKind.effortTitle($0), subtitle: AIProviderKind.effortDetail($0))
                    }
                )
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
