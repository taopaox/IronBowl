import AppKit
import Carbon.HIToolbox
import IronBowlKit
import SwiftUI

@Observable
final class QuickLogCapture {
    private let model: LogModel
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var panel: QuickLogPanel?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private(set) var shortcutError: String?
    private(set) var isSaving = false
    var text = ""
    var error: String?
    var hours = 1.0
    var savesOriginal: Bool {
        !model.isConfigured || model.context.providers.config(model.context.providers.defaultKind).executablePath.isEmpty || error != nil
    }

    init(model: LogModel) { self.model = model }

    isolated deinit { unregister() }

    func syncShortcut() {
        unregister()
        shortcutError = nil
        guard model.settings[LogKeys.quickLogShortcut] else { return }
        let target = GetApplicationEventTarget()
        let keyID = EventHotKeyID(signature: 0x49424C47, id: 1) // IBLG
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(target, { _, event, context in
            var received = EventHotKeyID()
            guard let context,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &received) == noErr,
                  received.signature == 0x49424C47, received.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<QuickLogCapture>.fromOpaque(context).takeUnretainedValue().show()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr,
              RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey), keyID,
                                  target, OptionBits(kEventHotKeyExclusive), &hotKey) == noErr else {
            unregister()
            shortcutError = "⌃⌥⌘L 注册失败，可能已被占用。可点「立即打开」，或关闭再开启快捷键重试。"
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
        let panel = QuickLogPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.title = "快速记日志"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let form = NSHostingController(rootView: QuickLogForm(capture: self))
        form.sizingOptions = [.preferredContentSize]
        panel.contentViewController = form
        panel.setContentSize(form.view.fittingSize)
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        saveTask?.cancel()
        saveTask = nil
        panel?.orderOut(nil)
        panel = nil
        isSaving = false
        text = ""
        error = nil
        hours = 1
    }

    func save() {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, !isSaving else { return }
        let day = Date()
        if savesOriginal {
            guard model.appendQuickLog(work: sentence, hours: hours, taskID: model.settings[LogKeys.fallbackTaskID], on: day) else {
                error = "草稿未能写入本机数据库，请重试。"
                return
            }
            dismiss()
            return
        }
        isSaving = true
        saveTask = Task {
            let reply = await model.addFromSentence(sentence, on: day)
            guard !Task.isCancelled else { return }
            isSaving = false
            if reply.hasPrefix("❌") {
                error = String(reply.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                dismiss()
            }
        }
    }

    /// 为按原文保存预填工时；用户可以在保存前调整。
    static func suggestedHours(in text: String) -> Double {
        if let match = text.firstMatch(of: /(\d+(?:\.\d+)?)\s*(小时|分钟|[hH]\b)/),
           let value = Double(match.1), value.isFinite {
            let hours = match.2 == "分钟" ? value / 60 : value
            return min(24, max(0.5, (hours * 2).rounded() / 2))
        }
        return text.contains("半小时") ? 0.5 : 1
    }
}

private final class QuickLogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct QuickLogForm: View {
    @Bindable var capture: QuickLogCapture
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快速记日志").font(.headline)
            TextField("例如：和产品对需求 2 小时", text: $capture.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { capture.save() }
                .disabled(capture.isSaving)
                .onChange(of: capture.text) { _, text in
                    capture.hours = QuickLogCapture.suggestedHours(in: text)
                }
            if let error = capture.error {
                Text(error).font(.callout).foregroundStyle(DS.danger).lineLimit(3)
            }
            HStack {
                if capture.savesOriginal {
                    Stepper("原文工时 \(hoursText(capture.hours)) 小时", value: $capture.hours, in: 0.5...24, step: 0.5)
                        .fixedSize()
                } else if capture.isSaving {
                    ProgressView().controlSize(.small)
                    Text("正在解析工时…")
                }
                Spacer()
                Button("取消") { capture.dismiss() }.keyboardShortcut(.cancelAction)
                Button(capture.savesOriginal ? "保存原文" : "保存草稿") { capture.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || capture.isSaving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focused = true }
        .onExitCommand { capture.dismiss() }
    }
}
