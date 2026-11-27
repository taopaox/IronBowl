import AppKit
import Carbon.HIToolbox
import IronBowlKit
import Observation
import SwiftUI

/// 全局 `⌘K` / `⌃⌥⌘K` 命令面板与跨模块历史全文搜索控制器。
@Observable
final class CommandPaletteController {
    enum Entry: Identifiable {
        case command(PaletteCommand)
        case searchHit(WorkspaceSearchHit)

        var id: String {
            switch self {
            case .command(let cmd): "cmd.\(cmd.id)"
            case .searchHit(let hit): "hit.\(hit.id)"
            }
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var panel: CommandPalettePanel?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    var query = ""
    var selectedIndex = 0
    private(set) var shortcutError: String?
    private(set) var commands: [PaletteCommand] = []
    private(set) var hits: [WorkspaceSearchHit] = []

    init(app: AppModel) {
        self.app = app
    }

    isolated deinit {
        unregister()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    var visibleEntries: [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = q.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }

        let matchedCommands: [PaletteCommand]
        if tokens.isEmpty {
            matchedCommands = Array(commands.prefix(12))
        } else {
            matchedCommands = commands.filter { cmd in
                let haystack = ([cmd.title, cmd.subtitle ?? "", cmd.badge ?? ""] + cmd.keywords)
                    .joined(separator: " ")
                    .lowercased()
                return tokens.allSatisfy { haystack.contains($0) }
            }
        }

        var out: [Entry] = matchedCommands.prefix(12).map { .command($0) }
        out.append(contentsOf: hits.map { .searchHit($0) })
        return out
    }

    // MARK: - 全局快捷键 ⌃⌥⌘K

    func syncShortcut() {
        unregister()
        shortcutError = nil
        guard let app, app.settings[AppKeys.commandPaletteShortcut] else { return }

        let target = GetApplicationEventTarget()
        let keyID = EventHotKeyID(signature: 0x49424350, id: 1) // IBCP
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(target, { _, event, context in
            var received = EventHotKeyID()
            guard let context,
                  GetEventParameter(
                      event,
                      EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil,
                      MemoryLayout<EventHotKeyID>.size,
                      nil,
                      &received
                  ) == noErr,
                  received.signature == 0x49424350,
                  received.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                Unmanaged<CommandPaletteController>.fromOpaque(context).takeUnretainedValue().toggle()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)

        guard installed == noErr,
              RegisterEventHotKey(
                  UInt32(kVK_ANSI_K),
                  UInt32(controlKey | optionKey | cmdKey),
                  keyID,
                  target,
                  OptionBits(kEventHotKeyExclusive),
                  &hotKey
              ) == noErr else {
            unregister()
            shortcutError = "⌃⌥⌘K 注册失败，可能已被占用。窗口内仍可使用 ⌘K，或点「立即打开」。"
            return
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    // MARK: - 面板开关与数据检索

    func toggle() {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        query = ""
        selectedIndex = 0
        rebuildCommands()
        hits = []

        if panel == nil {
            let p = CommandPalettePanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.title = "命令面板与全局搜索"
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = true
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

            let hosting = NSHostingController(rootView: CommandPaletteView(controller: self))
            p.contentViewController = hosting
            self.panel = p

            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: p,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismiss()
                }
            }
        }

        if let panel {
            positionAtUpperCenter(panel)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    func updateQuery(_ newValue: String) {
        query = newValue
        selectedIndex = 0
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let app else {
            hits = []
            return
        }
        hits = WorkspaceSearchEngine.search(database: app.database, query: trimmed, limit: 24)
    }

    func moveSelection(_ delta: Int) {
        let count = visibleEntries.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    func executeSelected() {
        let entries = visibleEntries
        guard !entries.isEmpty else { return }
        let idx = min(max(0, selectedIndex), entries.count - 1)
        execute(entries[idx])
    }

    func execute(_ entry: Entry) {
        dismiss()
        switch entry {
        case .command(let cmd):
            cmd.action()
        case .searchHit(let hit):
            openSearchHit(hit)
        }
    }

    func copyHitText(_ hit: WorkspaceSearchHit) {
        guard let text = hit.copyText, let app else { return }
        app.context.clipboard.copyToPasteboard(text)
        dismiss()
    }

    private func openSearchHit(_ hit: WorkspaceSearchHit) {
        guard let app else { return }
        switch hit.source {
        case .clipboard:
            if let text = hit.copyText {
                app.context.clipboard.copyToPasteboard(text)
            }
            app.open(plugin: hit.targetPluginID)
        case .chat:
            if let threadID = hit.chatThreadID {
                app.chat.selectThread(threadID)
            }
            app.open(plugin: AppModel.homeID)
        default:
            app.open(plugin: hit.targetPluginID)
        }
    }

    private func rebuildCommands() {
        guard let app else {
            commands = []
            return
        }
        var built: [PaletteCommand] = [
            PaletteCommand(
                id: "nav.home",
                title: "打开「今天」AI 对话工作台",
                subtitle: "多轮对话、工作目录与快捷卡片",
                keywords: ["home", "chat", "ai", "今天", "对话"],
                systemImage: "house",
                badge: "导航"
            ) { [weak app] in
                app?.open(plugin: AppModel.homeID)
            },
            PaletteCommand(
                id: "nav.reminders",
                title: "打开「消息提醒」中心",
                subtitle: "查看未读提醒与历史送达记录",
                keywords: ["reminder", "bell", "提醒", "通知"],
                systemImage: "bell",
                badge: "导航"
            ) { [weak app] in
                app?.open(plugin: AppModel.remindersID)
            },
            PaletteCommand(
                id: "nav.settings",
                title: "打开应用设置",
                subtitle: "外观、工作时间、AI 提供者与插件配置",
                keywords: ["settings", "preferences", "设置", "配置"],
                systemImage: "gearshape",
                badge: "导航"
            ) { [weak app] in
                app?.openSettings()
            },
        ]

        // 已启用插件直达
        for plugin in app.enabledPlugins {
            built.append(PaletteCommand(
                id: "plugin.\(plugin.id)",
                title: "打开「\(plugin.title)」",
                subtitle: plugin.sidebarTitle == plugin.title ? nil : "侧栏名称：\(plugin.sidebarTitle)",
                keywords: [plugin.id, plugin.title, plugin.sidebarTitle, plugin.sidebarSection ?? ""],
                systemImage: plugin.systemImage,
                badge: "插件"
            ) { [weak app] in
                plugin.onSidebarSelect()
                app?.open(plugin: plugin.id)
            })
        }

        // 插件暴露的子命令
        for plugin in app.enabledPlugins {
            built.append(contentsOf: plugin.paletteCommands)
        }

        // 插件快捷动作
        for plugin in app.enabledPlugins {
            for qa in plugin.quickActions {
                built.append(PaletteCommand(
                    id: "quick.\(qa.id)",
                    title: qa.title,
                    subtitle: "来自「\(plugin.title)」的快捷操作",
                    keywords: [plugin.title, qa.title],
                    systemImage: qa.systemImage,
                    badge: "快捷动作",
                    action: qa.action
                ))
            }
        }

        // 核心快捷动作
        built.append(contentsOf: [
            PaletteCommand(
                id: "op.overtime.plus1",
                title: "今日加班设为 +1 小时",
                subtitle: "顺延今天下班倒计时与目标工时",
                keywords: ["overtime", "加班", "1h"],
                systemImage: "clock.badge.plus",
                badge: "工作时间"
            ) { [weak app] in
                app?.workCalendar.setOvertimeHours(1.0)
            },
            PaletteCommand(
                id: "op.overtime.plus2",
                title: "今日加班设为 +2 小时",
                subtitle: "顺延今天下班倒计时与目标工时",
                keywords: ["overtime", "加班", "2h"],
                systemImage: "clock.badge.plus",
                badge: "工作时间"
            ) { [weak app] in
                app?.workCalendar.setOvertimeHours(2.0)
            },
            PaletteCommand(
                id: "op.overtime.clear",
                title: "清除今日加班时长",
                subtitle: "恢复默认下班时间与目标工时",
                keywords: ["overtime", "clear", "清除", "加班"],
                systemImage: "clock.arrow.circlepath",
                badge: "工作时间"
            ) { [weak app] in
                app?.workCalendar.setOvertimeHours(0)
            },
            PaletteCommand(
                id: "op.attendance.sync",
                title: "立即同步钉钉考勤打卡",
                subtitle: "刷新今日上下班打卡与异常状态",
                keywords: ["dingtalk", "attendance", "打卡", "考勤", "同步"],
                systemImage: "person.badge.clock",
                badge: "考勤"
            ) { [weak app] in
                guard let app else { return }
                Task { await app.workCalendar.syncAttendance() }
            },
            PaletteCommand(
                id: "op.web.suspendAll",
                title: "立即休眠全部后台网页",
                subtitle: "触发墓碑机制释放 WKWebView 内存",
                keywords: ["web", "suspend", "memory", "休眠", "内存"],
                systemImage: "moon.zzz",
                badge: "内存优化"
            ) { [weak app] in
                guard let app else { return }
                Task { _ = await app.webSessions.suspendAllInactive() }
            },
            PaletteCommand(
                id: "op.scratchpad.fromPasteboard",
                title: "将当前剪贴板存为随手便签",
                subtitle: "读取系统剪贴板文本新建一条便签并打开",
                keywords: ["pasteboard", "clipboard", "note", "剪贴板", "便签"],
                systemImage: "note.text.badge.plus",
                badge: "随手便签"
            ) { [weak app] in
                guard let app else { return }
                if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    _ = app.context.scratchpad.createNote(content: text)
                }
                app.open(plugin: "scratchpad")
            },
        ])

        commands = built
    }

    private func positionAtUpperCenter(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }
        let frame = screen.visibleFrame
        let width: CGFloat = 640
        let height: CGFloat = 440
        let x = frame.midX - width / 2
        let y = frame.maxY - height - max(72, frame.height * 0.14)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct CommandPaletteView: View {
    @Bindable var controller: CommandPaletteController
    @FocusState private var searchFocused: Bool

    var body: some View {
        let entries = controller.visibleEntries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(DS.font(16, .medium))
                    .foregroundStyle(DS.brand)
                TextField(
                    "",
                    text: Binding(
                        get: { controller.query },
                        set: { controller.updateQuery($0) }
                    ),
                    prompt: Text("搜索插件功能、日报周报、待办、便签、剪贴板或对话历史…")
                )
                .textFieldStyle(.plain)
                .font(DS.font(15))
                .focused($searchFocused)
                .onKeyPress(.downArrow) {
                    controller.moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    controller.moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.return) {
                    controller.executeSelected()
                    return .handled
                }

                if !controller.query.isEmpty {
                    Button {
                        controller.updateQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                Text("Esc")
                    .font(DS.font(10.5, .medium))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.well, in: .rect(cornerRadius: 5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider().overlay(DS.border)

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.font(24))
                        .foregroundStyle(DS.textTertiary)
                    Text("没有找到匹配「\(controller.query)」的命令或历史记录")
                        .font(DS.body)
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                let isSelected = index == controller.selectedIndex
                                CommandPaletteRow(
                                    entry: entry,
                                    isSelected: isSelected,
                                    onSelect: { controller.execute(entry) },
                                    onCopyHit: { hit in controller.copyHitText(hit) }
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: controller.selectedIndex) { _, newValue in
                        if entries.indices.contains(newValue) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(entries[newValue].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider().overlay(DS.border)

            HStack(spacing: 14) {
                Text("↑↓ 选择")
                Text("↵ 执行 / 打开")
                Text("Esc 关闭")
                Spacer()
                if !controller.hits.isEmpty {
                    Text("命中 \(controller.hits.count) 条历史记录")
                        .monospacedDigit()
                }
            }
            .font(DS.font(11))
            .foregroundStyle(DS.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(DS.well.opacity(0.6))
        }
        .frame(width: 640, height: 440)
        .background(DS.card, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(DS.borderStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        .onAppear { searchFocused = true }
        .onExitCommand { controller.dismiss() }
    }
}

private struct CommandPaletteRow: View {
    let entry: CommandPaletteController.Entry
    let isSelected: Bool
    let onSelect: () -> Void
    let onCopyHit: (WorkspaceSearchHit) -> Void
    @State private var hovering = false

    var body: some View {
        switch entry {
        case .command(let cmd):
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: cmd.systemImage)
                        .font(DS.font(14))
                        .foregroundStyle(isSelected ? DS.brand : DS.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(DS.well, in: .rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(cmd.title)
                            .font(DS.font(13.5, .medium))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        if let subtitle = cmd.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(DS.font(11.5))
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if let badge = cmd.badge, !badge.isEmpty {
                        Tag(badge, color: isSelected ? DS.brand : DS.textSecondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(rowBg, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

        case .searchHit(let hit):
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: hit.source.systemImage)
                        .font(DS.font(13.5))
                        .foregroundStyle(DS.brand)
                        .frame(width: 24, height: 24)
                        .background(DS.brand.opacity(0.12), in: .rect(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(hit.title)
                                .font(DS.font(13, .medium))
                                .foregroundStyle(DS.text)
                                .lineLimit(1)
                            if let dateText = hit.dateText, !dateText.isEmpty {
                                Text(dateText)
                                    .font(DS.font(11))
                                    .foregroundStyle(DS.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet)
                                .font(DS.font(11.5))
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if hit.copyText != nil {
                        Button {
                            onCopyHit(hit)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(DS.font(11.5))
                                .foregroundStyle(DS.textSecondary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .help("复制内容")
                    }

                    Tag(hit.source.displayName, color: DS.brand)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(rowBg, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private var rowBg: Color {
        if isSelected { return DS.selected }
        if hovering { return DS.hover }
        return .clear
    }
}
