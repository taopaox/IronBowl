import AppKit
import Carbon.HIToolbox
import Foundation
import IronBowlKit
import Observation
import SwiftUI

/// 随手便签 / 剪贴板暂存板插件：支持 Markdown 预览、JSON 格式化/压缩、全局快捷键 ⌃⌥⌘N 呼出及转入待办/日报。
public final class ScratchpadPlugin: IronBowlPlugin {
    public static let pluginID = "scratchpad"
    public static let settingsShortcutID = "scratchpad.shortcut"
    public static let quickShortcutKey = SettingKey<Bool>("scratchpad.quickShortcut", default: true)

    public let id = ScratchpadPlugin.pluginID
    public let title = "随手便签"
    public let systemImage = "note.text"

    private var context: PluginContext?
    private var quickCapture: QuickScratchpadCapture?

    public init() {}

    public func start(context: PluginContext) {
        self.context = context
        let capture = QuickScratchpadCapture(context: context)
        self.quickCapture = capture
        capture.syncShortcut()
    }

    public func stop() {
        quickCapture?.stop()
        quickCapture = nil
        context = nil
    }

    public func makeMainView() -> AnyView {
        guard let context else { return AnyView(ProgressView()) }
        return AnyView(ScratchpadMainView(context: context))
    }

    public var settingsPages: [SettingsPage] {
        guard let context, let quickCapture else { return [] }
        return [
            SettingsPage(id: Self.settingsShortcutID, title: "快速便签", systemImage: "note.text") {
                AnyView(ScratchpadSettingsView(settings: context.settings, capture: quickCapture))
            },
        ]
    }

    public var quickActions: [QuickAction] {
        guard let context else { return [] }
        return [
            QuickAction(id: "scratchpad.new", title: "新建便签", systemImage: "note.text.badge.plus") {
                _ = context.scratchpad.createNote()
                context.openPlugin(Self.pluginID)
            },
            QuickAction(id: "scratchpad.paste", title: "粘入剪贴板", systemImage: "doc.on.clipboard") {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                _ = context.scratchpad.createNote(content: text)
                context.openPlugin(Self.pluginID)
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let context else { return [] }
        return [
            HomeCard(
                id: "scratchpad.notes",
                label: "随手便签",
                value: { "\(context.scratchpad.notes.count) 条" },
                detail: { context.scratchpad.notes.first?.displayTitle ?? "暂存 JSON、命令与备忘" },
                action: { context.openPlugin(Self.pluginID) }
            ),
        ]
    }
}

@Observable
final class QuickScratchpadCapture {
    private let context: PluginContext
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var panel: QuickScratchpadPanel?
    private(set) var shortcutError: String?
    var title = ""
    var content = ""
    var statusText: String?

    init(context: PluginContext) {
        self.context = context
    }

    isolated deinit {
        unregister()
    }

    func syncShortcut() {
        unregister()
        shortcutError = nil
        guard context.settings[ScratchpadPlugin.quickShortcutKey] else { return }
        let target = GetApplicationEventTarget()
        let keyID = EventHotKeyID(signature: 0x49425350, id: 1) // IBSP
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(target, { _, event, ctxPtr in
            var received = EventHotKeyID()
            guard let ctxPtr,
                  GetEventParameter(
                      event,
                      EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil,
                      MemoryLayout<EventHotKeyID>.size,
                      nil,
                      &received
                  ) == noErr,
                  received.signature == 0x49425350,
                  received.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                Unmanaged<QuickScratchpadCapture>.fromOpaque(ctxPtr).takeUnretainedValue().show()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr,
              RegisterEventHotKey(
                  UInt32(kVK_ANSI_N),
                  UInt32(controlKey | optionKey | cmdKey),
                  keyID,
                  target,
                  OptionBits(kEventHotKeyExclusive),
                  &hotKey
              ) == noErr else {
            unregister()
            shortcutError = "⌃⌥⌘N 注册失败，可能已被占用。可点「立即打开」，或关闭再开启快捷键重试。"
            return
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    func stop() {
        unregister()
        dismiss()
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = QuickScratchpadPanel(
            contentRect: .zero,
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "随手便签"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let form = NSHostingController(rootView: QuickScratchpadForm(capture: self))
        form.sizingOptions = [.preferredContentSize]
        panel.contentViewController = form
        panel.setContentSize(form.view.fittingSize)
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        title = ""
        content = ""
        statusText = nil
    }

    func pasteFromClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            content = text
            statusText = nil
        }
    }

    func formatJSON() {
        switch ScratchpadStore.formatJSON(content) {
        case .success(let formatted):
            content = formatted
            statusText = nil
        case .failure(let err):
            statusText = "JSON 解析失败：\(err.localizedDescription)"
        }
    }

    func saveAndClose() {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty || !trimmedTitle.isEmpty else { return }
        if context.scratchpad.createNote(title: trimmedTitle, content: content) != nil {
            dismiss()
        }
    }
}

private final class QuickScratchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickScratchpadForm: View {
    @Bindable var capture: QuickScratchpadCapture
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("随手便签").font(.headline)
                Spacer()
                Button("粘贴剪贴板") { capture.pasteFromClipboard() }
                    .buttonStyle(.dsSecondary)
                Button("美化 JSON") { capture.formatJSON() }
                    .buttonStyle(.dsSecondary)
                    .disabled(capture.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("标题（留空则自动取首行）", text: $capture.title)
                .textFieldStyle(.ds)

            TextEditor(text: $capture.content)
                .font(DS.mono(13))
                .scrollContentBackground(.hidden)
                .frame(height: 170)
                .padding(8)
                .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
                .focused($focused)

            if let status = capture.statusText {
                Text(status).font(.callout).foregroundStyle(DS.danger)
            }

            HStack {
                Spacer()
                Button("取消") { capture.dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存便签") { capture.saveAndClose() }
                    .buttonStyle(.dsPrimary)
                    .disabled(capture.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && capture.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focused = true }
        .onExitCommand { capture.dismiss() }
    }
}

private struct ScratchpadSettingsView: View {
    let settings: SettingsStore
    @Bindable var capture: QuickScratchpadCapture

    var body: some View {
        DSSection("全局快速便签", footer: "任意桌面按下 ⌃⌥⌘N 可呼出悬浮便签，适合快速暂存 JSON、测试账号、curl 命令或会议碎片记录。") {
            DSRow("快捷键 ⌃⌥⌘N", description: capture.shortcutError ?? "在任意应用内按下 Control + Option + Command + N 打开悬浮便签。") {
                HStack(spacing: 8) {
                    Button("立即打开") { capture.show() }
                        .buttonStyle(.dsSecondary)
                    DSToggle(isOn: Binding(
                        get: { settings[ScratchpadPlugin.quickShortcutKey] },
                        set: {
                            settings[ScratchpadPlugin.quickShortcutKey] = $0
                            capture.syncShortcut()
                        }
                    ))
                }
            }
        }
    }
}
