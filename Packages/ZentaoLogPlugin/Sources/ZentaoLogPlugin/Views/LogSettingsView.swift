import AppKit
import IronBowlKit
import SwiftUI

// 日志插件的四个设置页，显示在设置窗口左侧「禅道日志」分组下。

// MARK: 禅道账号

struct ZentaoAccountSettings: View {
    let model: LogModel
    @State private var showPassword = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let s = model.settings
        DSSection("禅道账号", footer: "账号密码以明文保存在本机数据库（~/Library/Application Support/IronBowl/ironbowl.sqlite），不会进入代码仓库。") {
            DSRow("禅道地址") {
                TextField("", text: s.binding(LogKeys.baseURL)).textFieldStyle(.ds).frame(width: 300)
            }
            DSRow("账号") {
                TextField("", text: s.binding(LogKeys.account)).textFieldStyle(.ds).frame(width: 300)
            }
            DSRow("密码") {
                HStack(spacing: 6) {
                    Group {
                        if showPassword {
                            TextField("", text: s.binding(LogKeys.password))
                        } else {
                            SecureField("", text: s.binding(LogKeys.password))
                        }
                    }
                    .textFieldStyle(.ds)
                    .frame(width: 262)
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.dsGhost)
                }
            }
        }

        DSSection("连接", footer: "每次请求禅道的原始返回都会写进接口日志（不含密码），接口对不上时把日志发给我。") {
            DSRow("测试连接", description: testResult ?? "登录禅道并拉取指派给你的任务。") {
                HStack(spacing: 8) {
                    Button("打开接口日志") { NSWorkspace.shared.open(ZentaoLog.url) }.buttonStyle(.dsGhost)
                    Button {
                        Task { await test() }
                    } label: {
                        if testing { ProgressView().controlSize(.small).tint(DS.onPrimary) } else { Text("测试连接") }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(testing)
                }
            }
        }

        DSSection("兜底任务") {
            DSRow("兜底任务", description: "AI 找不到合适任务时记到这里，草稿里会标黄。默认选名字里带「杂项」的任务。") {
                let fallbackOptions = [DSPickerOption(Int?.none, title: "未设置", subtitle: "自动匹配名称含「杂项」的未关闭任务。")]
                    + model.openTasks.map { DSPickerOption(Int?.some($0.id), title: "#\($0.id) \($0.name)", subtitle: $0.projectName) }
                DSPicker(
                    selection: s.binding(LogKeys.fallbackTaskID),
                    options: fallbackOptions,
                    width: 260
                )
            }
        }
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
    @State private var query = ""
    @State private var filter: Filter = .active

    enum Filter: Hashable { case active, unmapped, all }

    var body: some View {
        let s = model.settings
        DSSection("扫描") {
            DSRow("扫描根目录", description: "在这个目录下找 git 仓库。") {
                HStack(spacing: 6) {
                    TextField("", text: s.binding(LogKeys.gitRoot)).textFieldStyle(.ds).frame(width: 260)
                    Button("选择…") { chooseRoot() }.buttonStyle(.dsSecondary)
                }
            }
            DSRow("查找深度", description: "从根目录往下找几层。") {
                DSStepper(intValue: s.binding(LogKeys.gitDepth), in: 1...4) { "\($0) 层" }
            }
            DSRow("提交作者邮箱", description: "只统计这个邮箱的提交。留空读取 git 全局邮箱。") {
                TextField("", text: s.binding(LogKeys.authorEmail)).textFieldStyle(.ds).frame(width: 260)
            }
            DSRow("扫描方式") {
                DSPicker(
                    selection: s.binding(LogKeys.scanMode),
                    options: ScanMode.allCases.map { DSPickerOption($0, title: $0.shortName, subtitle: $0.detail) }
                )
            }
            if s[LogKeys.scanMode] == .onDemandPlusInterval {
                DSRow("定时扫描间隔") {
                    DSStepper(intValue: s.binding(LogKeys.scanInterval), in: 5...120, step: 5) { "\($0) 分钟" }
                }
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("仓库 → 禅道项目").font(DS.sectionTitle).foregroundStyle(DS.textSecondary)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    if loading { ProgressView().controlSize(.small) } else { Label("重新扫描", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.dsGhost)
                Button {
                    Task { await suggest() }
                } label: {
                    if suggesting { ProgressView().controlSize(.small).tint(DS.onPrimary) } else { Label("AI 推荐对应项目", systemImage: "sparkles") }
                }
                .buttonStyle(.dsPrimary)
                .disabled(active.isEmpty || model.projects.isEmpty || suggesting)
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(DS.textTertiary)
                    TextField("搜索仓库", text: $query).textFieldStyle(.plain)
                }
                .font(DS.font(14))
                .padding(.horizontal, 10)
                .frame(width: 220, height: 30)
                .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
                DSTabs(selection: $filter, options: [
                    (.active, "近 30 天 \(active.count)"),
                    (.unmapped, "未关联 \(unmappedCount)"),
                    (.all, "全部"),
                ])
            }
            if model.projects.isEmpty {
                DSBanner(.warning, "还没拉到禅道任务，先去「禅道账号」页测试连接。")
            }
            VStack(spacing: 0) {
                let list = rows
                if list.isEmpty {
                    Text(loading ? "正在扫描…" : "没有符合条件的仓库").font(DS.body).foregroundStyle(DS.textSecondary)
                        .frame(maxWidth: .infinity).padding(24)
                }
                ForEach(Array(list.enumerated()), id: \.element) { index, repo in
                    RepoRow(model: model, repo: repo, recent: active[repo] ?? [])
                    if index < list.count - 1 { Divider().overlay(DS.border).padding(.horizontal, 16) }
                }
            }
            .background(DS.card, in: .rect(cornerRadius: DS.radius))
            .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
            Text("只有对应了项目的仓库，AI 才知道该从哪些任务里挑。「发送代码改动」会把该仓库的 diff（截断）一起发给 AI。")
                .font(DS.caption).foregroundStyle(DS.textTertiary).padding(.horizontal, 4)
        }
        .task {
            if active.isEmpty { await load() }
            if model.tasks.isEmpty { await model.loadTasks() }
        }
    }

    var unmappedCount: Int { active.keys.filter { model.mappings[$0]?.projectID == nil && model.mappings[$0]?.excluded != true }.count }

    var rows: [String] {
        let maps = model.mappings
        var list: [String]
        switch filter {
        case .active: list = Array(active.keys)
        case .unmapped: list = active.keys.filter { maps[$0]?.projectID == nil && maps[$0]?.excluded != true }
        case .all: list = model.repos()
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { ($0 as NSString).lastPathComponent.localizedCaseInsensitiveContains(q) } }
        return list.sorted { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() }
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

/// 一个仓库：状态圆点 + 名字 + 最近提交；右边项目下拉，悬停出现「排除 / 发代码」开关。
struct RepoRow: View {
    let model: LogModel
    let repo: String
    let recent: [String]
    @State private var hovering = false

    var body: some View {
        let m = model.mappings[repo]
        let excluded = m?.excluded ?? false
        HStack(spacing: 12) {
            Circle()
                .fill(excluded ? DS.textTertiary : m?.projectID != nil ? DS.toggle : DS.warning)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((repo as NSString).lastPathComponent).font(DS.rowTitle)
                        .foregroundStyle(excluded ? DS.textTertiary : DS.text)
                    if !recent.isEmpty {
                        Text("\(recent.count)\(recent.count >= 15 ? "+" : "") 次").font(DS.caption).foregroundStyle(DS.textTertiary)
                    }
                    if m?.sendDiff == true { Tag("发送代码", color: DS.warning) }
                }
                Text(excluded ? "已排除，不参与扫描" : (recent.first ?? "近 30 天没有提交"))
                    .font(DS.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering || excluded || m?.sendDiff == true {
                Button(excluded ? "取消排除" : "排除") {
                    model.updateMapping(repo: repo) { $0.excluded.toggle() }
                }
                .buttonStyle(.dsGhost)
                Button(m?.sendDiff == true ? "不发代码" : "发送代码改动") {
                    model.updateMapping(repo: repo) { $0.sendDiff.toggle() }
                }
                .buttonStyle(.dsGhost)
            }
            DSPicker(selection: Binding(
                get: { m?.projectID },
                set: { id in model.setMapping(repo: repo, project: model.projects.first { $0.id == id }) }
            ), options: projectOptions(m), width: 200)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovering ? DS.hover : .clear)
        .onHover { hovering = $0 }
    }

    func projectOptions(_ m: RepoMapping?) -> [(Int?, String)] {
        var options: [(Int?, String)] = [(nil, "未关联")] + model.projects.map { (Int?.some($0.id), $0.name) }
        if let id = m?.projectID, !model.projects.contains(where: { $0.id == id }) {
            options.append((id, m?.projectName ?? "#\(id)"))
        }
        return options
    }
}

extension ScanMode {
    var shortName: String {
        switch self {
        case .onDemand: "按需扫描"
        case .onDemandPlusInterval: "按需 + 定时"
        case .manualOnly: "只手动刷新"
        }
    }
}

// MARK: 生成

struct GenerateSettings: View {
    let model: LogModel

    var body: some View {
        let s = model.settings
        DSSection("提示词", footer: "占位符：{{date}} 日期，{{activity}} 提交明细，{{tasks}} 可选任务和兜底任务。") {
            DSBlockRow {
                TextEditor(text: s.binding(LogKeys.prompt))
                    .font(DS.mono(13.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 280)
            }
            DSRow("恢复默认提示词") {
                Button("恢复默认") { s[LogKeys.prompt] = DraftGenerator.defaultPrompt }.buttonStyle(.dsSecondary)
            }
        }
        DSSection("工时") {
            DSRow("加班默认时长", description: "点「记加班」时默认填的小时数。") {
                DSStepper(value: s.binding(LogKeys.overtimeDefaultHours), in: 0.5...12, step: 0.5) { "\(hoursText($0)) 小时" }
            }
            DSRow("非工作日的工时默认算加班") { DSToggle(isOn: s.binding(LogKeys.offDayOvertime)) }
        }
    }
}

// MARK: 提醒

struct ReminderSettings: View {
    let model: LogModel
    let scheduler: LogReminderScheduler
    @State private var notificationStatus: SystemNotificationStatus?
    @State private var previewing = false
    @State private var requestingAuth = false
    @State private var previewFeedback: NotificationBannerState?

    private enum BannerAction {
        case none
        case openSettings(String)
        case requestAuth(String)

        var title: String? {
            switch self {
            case .none: nil
            case .openSettings(let title), .requestAuth(let title): title
            }
        }
    }

    private struct NotificationBannerState {
        let kind: DSBanner.Kind
        let text: String
        let action: BannerAction
    }

    var body: some View {
        let s = model.settings
        DSSection("什么时候提醒", footer: "当天已提交日志、或点了「今天不写」就不再提醒。") {
            ForEach(Array(s[LogKeys.reminderTimes].enumerated()), id: \.offset) { index, time in
                DSRow("提醒时间 \(index + 1)") {
                    HStack(spacing: 6) {
                        DatePicker("", selection: Binding(
                            get: { Self.date(from: time) },
                            set: { d in
                                var times = s[LogKeys.reminderTimes]
                                times[index] = Self.string(from: d)
                                s[LogKeys.reminderTimes] = times
                            }
                        ), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        Button {
                            var times = s[LogKeys.reminderTimes]
                            times.remove(at: index)
                            s[LogKeys.reminderTimes] = times
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.dsGhost)
                    }
                }
            }
            DSRow("添加提醒时间") {
                Button("添加", systemImage: "plus") { s[LogKeys.reminderTimes] = s[LogKeys.reminderTimes] + ["17:30"] }
                    .buttonStyle(.dsSecondary)
            }
            DSRow("非工作日也提醒") { DSToggle(isOn: s.binding(LogKeys.remindOnOffDays)) }
            DSRow("稍后提醒间隔", description: "点「N 分钟后」再提醒的间隔。") {
                DSStepper(intValue: s.binding(LogKeys.snoozeMinutes), in: 5...120, step: 5) { "\($0) 分钟" }
            }
        }
        DSSection("怎么提醒", footer: "系统通知是横幅还是常驻，由「系统设置 → 通知 → 饭碗」决定；右上角卡片和中央弹框由饭碗自己画，不操作不会消失，勿扰模式下也会出现。") {
            DSRow("提醒方式", description: "系统通知走 macOS 通知中心；卡片与弹框在勿扰模式下也会出现。") {
                HStack(spacing: 8) {
                    Button {
                        Task { await runPreview(style: s[LogKeys.reminderStyle]) }
                    } label: {
                        if previewing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("预览")
                        }
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(previewing)
                    DSPicker(
                        selection: s.binding(LogKeys.reminderStyle),
                        options: ReminderStyle.allCases.map {
                            DSPickerOption($0, title: $0.shortName, subtitle: $0.detail)
                        }
                    )
                }
            }
            if s[LogKeys.reminderStyle] == .system {
                DSRow("系统通知权限", description: permissionDescription) {
                    permissionControls
                }
            }
        }
        if s[LogKeys.reminderStyle] == .system, let banner = activeBanner {
            DSBanner(banner.kind, banner.text, actionTitle: banner.action.title) {
                performBannerAction(banner.action)
            }
        }
        Color.clear
            .frame(height: 0)
            .task { await refreshNotificationStatus() }
            .onChange(of: s[LogKeys.reminderStyle]) { _, newStyle in
                if newStyle == .system {
                    Task { await refreshNotificationStatus() }
                } else {
                    previewFeedback = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshNotificationStatus() }
            }
    }

    private var permissionDescription: String {
        switch notificationStatus {
        case nil:
            "正在检查系统通知权限…"
        case .authorized:
            "已开启系统通知，预览或到点时会由 macOS 通知中心弹出。"
        case .notDetermined:
            "尚未授权，点击「请求权限」或点「预览」会弹出系统授权提示。"
        case .denied:
            "未允许通知，请在「系统设置 → 通知 → 饭碗」打开「允许通知」。"
        case .alertsDisabled:
            "提醒样式当前为「无」，请在「系统设置 → 通知 → 饭碗」选择「横幅」或「提醒」。"
        case .unavailable:
            "仅以 .app 应用包运行时支持系统通知。"
        }
    }

    @ViewBuilder
    private var permissionControls: some View {
        switch notificationStatus {
        case nil:
            ProgressView().controlSize(.small)
        case .notDetermined:
            HStack(spacing: 8) {
                statusBadge("未授权", color: DS.warning)
                Button {
                    Task { await requestAuthorization() }
                } label: {
                    if requestingAuth { ProgressView().controlSize(.small).tint(DS.onPrimary) } else { Text("请求权限") }
                }
                .buttonStyle(.dsPrimary)
                .disabled(requestingAuth)
                Button("系统设置") { openSystemSettings() }
                    .buttonStyle(.dsSecondary)
            }
        case .denied:
            HStack(spacing: 8) {
                statusBadge("未开启", color: DS.warning)
                Button("前往设置权限") { openSystemSettings() }
                    .buttonStyle(.dsPrimary)
            }
        case .alertsDisabled:
            HStack(spacing: 8) {
                statusBadge("样式为无", color: DS.warning)
                Button("前往设置样式") { openSystemSettings() }
                    .buttonStyle(.dsPrimary)
            }
        case .authorized:
            HStack(spacing: 8) {
                statusBadge("已开启", color: DS.success)
                Button("打开系统设置") { openSystemSettings() }
                    .buttonStyle(.dsSecondary)
            }
        case .unavailable:
            HStack(spacing: 8) {
                statusBadge("不可用", color: DS.textTertiary)
                Button("打开系统设置") { openSystemSettings() }
                    .buttonStyle(.dsSecondary)
            }
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(DS.caption).foregroundStyle(color)
        }
    }

    private var activeBanner: NotificationBannerState? {
        if let previewFeedback { return previewFeedback }
        switch notificationStatus {
        case .denied:
            return NotificationBannerState(
                kind: .warning,
                text: "系统通知权限未开启，选「系统通知」时将无法弹出提醒。请前往「系统设置 → 通知 → 饭碗」打开「允许通知」。",
                action: .openSettings("前往设置权限")
            )
        case .alertsDisabled:
            return NotificationBannerState(
                kind: .warning,
                text: "系统通知权限已开启，但提醒样式当前为「无」，不会在屏幕上弹窗。请前往「系统设置 → 通知 → 饭碗」改为「横幅」或「提醒」。",
                action: .openSettings("前往设置样式")
            )
        case .notDetermined:
            return NotificationBannerState(
                kind: .info,
                text: "尚未向系统申请通知权限，点击「请求权限」或在首次预览时授权。",
                action: .requestAuth("请求权限")
            )
        case .unavailable:
            return NotificationBannerState(
                kind: .warning,
                text: "当前不是以 .app 应用包运行，macOS 不会投递系统通知。",
                action: .none
            )
        case .authorized, nil:
            return nil
        }
    }

    private func performBannerAction(_ action: BannerAction) {
        switch action {
        case .none:
            break
        case .openSettings:
            openSystemSettings()
        case .requestAuth:
            Task { await requestAuthorization() }
        }
    }

    private func refreshNotificationStatus() async {
        let latest = await model.context.reminders.systemNotificationStatus()
        notificationStatus = latest
        if latest == .authorized, previewFeedback?.kind == .warning {
            previewFeedback = nil
        }
    }

    private func requestAuthorization() async {
        requestingAuth = true
        defer { requestingAuth = false }
        let latest = await model.context.reminders.requestSystemNotificationAuthorization()
        notificationStatus = latest
        previewFeedback = bannerState(for: latest)
    }

    private func bannerState(for status: SystemNotificationStatus) -> NotificationBannerState? {
        switch status {
        case .authorized:
            return NotificationBannerState(
                kind: .success,
                text: "系统通知权限已开启，现在可以点击「预览」测试通知效果。",
                action: .none
            )
        case .denied:
            return NotificationBannerState(
                kind: .warning,
                text: "未获得系统通知权限，请到「系统设置 → 通知 → 饭碗」打开「允许通知」。",
                action: .openSettings("前往设置权限")
            )
        case .alertsDisabled:
            return NotificationBannerState(
                kind: .warning,
                text: "系统通知提醒样式当前为「无」，请到「系统设置 → 通知 → 饭碗」改为「横幅」或「提醒」。",
                action: .openSettings("前往设置样式")
            )
        case .notDetermined:
            return nil
        case .unavailable:
            return NotificationBannerState(
                kind: .warning,
                text: "当前不是以 .app 应用包运行，macOS 不会投递系统通知。",
                action: .none
            )
        }
    }

    private func runPreview(style: ReminderStyle) async {
        previewing = true
        defer { previewing = false }
        let result = await scheduler.preview(style: style)
        guard style == .system else {
            previewFeedback = nil
            return
        }
        notificationStatus = await model.context.reminders.systemNotificationStatus()
        switch result {
        case .delivered:
            previewFeedback = NotificationBannerState(
                kind: .success,
                text: "已发送系统通知预览。如果右上角仍未出现，请检查是否开启了「专注/勿扰模式」，或打开系统设置确认提醒样式。",
                action: .openSettings("打开系统设置")
            )
        case .permissionDenied:
            previewFeedback = NotificationBannerState(
                kind: .warning,
                text: "未弹出通知：系统通知权限未开启。请到「系统设置 → 通知 → 饭碗」打开「允许通知」。",
                action: .openSettings("前往设置权限")
            )
        case .alertsDisabled:
            previewFeedback = NotificationBannerState(
                kind: .warning,
                text: "未弹出通知：系统通知提醒样式当前为「无」，不会在屏幕上弹窗。请到「系统设置 → 通知 → 饭碗」改为「横幅」或「提醒」。",
                action: .openSettings("前往设置样式")
            )
        case .unavailable:
            previewFeedback = NotificationBannerState(
                kind: .warning,
                text: "当前不是以 .app 应用包运行，macOS 不会投递系统通知。",
                action: .none
            )
        case .failed(let message):
            previewFeedback = NotificationBannerState(
                kind: .danger,
                text: "系统通知发送失败：\(message)",
                action: .openSettings("打开系统设置")
            )
        }
    }

    private func openSystemSettings() {
        if !ReminderCenter.openSystemNotificationSettings() {
            previewFeedback = NotificationBannerState(
                kind: .warning,
                text: "未能自动打开系统设置，请手动前往「系统设置 → 通知 → 饭碗」。",
                action: .none
            )
        }
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

    var detail: String {
        switch self {
        case .system: "走 macOS 通知中心，勿扰模式下不弹。"
        case .cornerCard: "右上角浮动卡片，不点按钮不消失。"
        case .centerDialog: "屏幕正中间弹出，盖在所有窗口上面。"
        }
    }
}
