import AppKit
import Observation
import SwiftUI

/// `DSPicker` 选项模型：支持主标题、可选说明副标题，以及收起时按钮显示的简短标题。
public nonisolated struct DSPickerOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    public let subtitle: String?
    public let triggerTitle: String?

    public var id: Value { value }

    public init(
        _ value: Value,
        title: String,
        subtitle: String? = nil,
        triggerTitle: String? = nil
    ) {
        self.value = value
        self.title = title
        self.subtitle = subtitle
        self.triggerTitle = triggerTitle
    }
}

/// 统一浮层卡片下拉选择器：触发按钮带边框，展开时箭头朝上并弹出带阴影的白卡菜单（支持副标题与绿色对勾）。
public struct DSPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [DSPickerOption<Value>]
    let width: CGFloat?
    let menuWidth: CGFloat?
    let placeholder: String

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var controller = DSPickerPopupController()

    public init(
        selection: Binding<Value>,
        options: [DSPickerOption<Value>],
        width: CGFloat? = nil,
        menuWidth: CGFloat? = nil,
        placeholder: String = "请选择"
    ) {
        _selection = selection
        self.options = options
        self.width = width
        self.menuWidth = menuWidth
        self.placeholder = placeholder
    }

    public init(
        selection: Binding<Value>,
        options: [(Value, String)],
        width: CGFloat? = nil,
        menuWidth: CGFloat? = nil,
        placeholder: String = "请选择"
    ) {
        self.init(
            selection: selection,
            options: options.map { DSPickerOption($0.0, title: $0.1) },
            width: width,
            menuWidth: menuWidth,
            placeholder: placeholder
        )
    }

    private var selectedOption: DSPickerOption<Value>? {
        options.first { $0.value == selection }
    }

    private var triggerText: String {
        selectedOption?.triggerTitle ?? selectedOption?.title ?? placeholder
    }

    public var body: some View {
        Button {
            guard isEnabled, !options.isEmpty else { return }
            if controller.isOpen {
                controller.dismiss()
            } else {
                controller.show(
                    options: options,
                    selection: selection,
                    menuWidth: menuWidth
                ) { chosen in
                    selection = chosen
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: triggerText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: controller.isOpen ? "chevron.up" : "chevron.down")
                    .font(DS.font(11, .semibold))
                    .foregroundStyle(isEnabled ? DS.textSecondary : DS.textTertiary)
            }
            .font(DS.font(14))
            .foregroundStyle(isEnabled ? DS.text : DS.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: DS.s(30))
            .frame(width: width)
            .frame(minWidth: DS.s(110))
            .background(
                (isEnabled && hovering) ? DS.hover : DS.card,
                in: .rect(cornerRadius: DS.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.controlRadius)
                    .strokeBorder(DS.borderStrong, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: width == nil, vertical: true)
        .onHover { hovering = $0 }
        .background {
            DSPickerAnchor { view in
                controller.anchorView = view
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { controller.dismiss() }
        }
        .onDisappear {
            controller.dismiss()
        }
    }
}

// MARK: - 锚点视图

private struct DSPickerAnchor: NSViewRepresentable {
    let onAttach: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            if let view { onAttach(view) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onAttach(nsView)
    }
}

// MARK: - 弹出浮层面板控制器

private final class DSPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@Observable
private final class DSPickerPopupController {
    private static weak var activeController: DSPickerPopupController?
    private static let shadowPad: CGFloat = 18
    private static let gap: CGFloat = 6

    var isOpen = false
    @ObservationIgnored weak var anchorView: NSView?

    @ObservationIgnored private var panel: DSPickerPanel?
    @ObservationIgnored private weak var parentWindow: NSWindow?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var triggerScreenRect: NSRect = .zero

    func show<Value: Hashable>(
        options: [DSPickerOption<Value>],
        selection: Value,
        menuWidth: CGFloat?,
        onSelect: @escaping (Value) -> Void
    ) {
        if let active = Self.activeController, active !== self {
            active.dismiss()
        }
        dismiss()

        guard let anchorView, let parentWindow = anchorView.window else { return }

        let boundsInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let triggerRect = parentWindow.convertToScreen(boundsInWindow)
        guard triggerRect.width > 0, triggerRect.height > 0 else { return }
        self.triggerScreenRect = triggerRect

        let visibleFrame = parentWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let cardWidth = measuredCardWidth(
            options: options,
            triggerWidth: triggerRect.width,
            explicitMenuWidth: menuWidth,
            maxAvailableWidth: visibleFrame.width - 32
        )

        let spaceBelow = triggerRect.minY - visibleFrame.minY - Self.gap - 8
        let spaceAbove = visibleFrame.maxY - triggerRect.maxY - Self.gap - 8
        let maxCardHeight = min(DS.s(320), max(DS.s(120), max(spaceBelow, spaceAbove)))

        let selectedIndex = options.firstIndex { $0.value == selection }
        let cardHeight: CGFloat
        let scrollable: Bool

        if options.count <= 16 {
            let probe = NSHostingView(
                rootView: DSPickerMenuCard(
                    options: options,
                    selection: selection,
                    cardWidth: cardWidth,
                    scrollHeight: nil,
                    selectedIndex: selectedIndex,
                    onSelect: { _ in }
                )
                .environment(\.locale, CN.locale)
            )
            probe.appearance = parentWindow.effectiveAppearance
            let naturalHeight = ceil(probe.fittingSize.height)
            if naturalHeight <= maxCardHeight {
                cardHeight = naturalHeight
                scrollable = false
            } else {
                cardHeight = maxCardHeight
                scrollable = true
            }
        } else {
            cardHeight = maxCardHeight
            scrollable = true
        }

        let contentView = DSPickerMenuCard(
            options: options,
            selection: selection,
            cardWidth: cardWidth,
            scrollHeight: scrollable ? cardHeight : nil,
            selectedIndex: selectedIndex
        ) { [weak self] chosen in
            onSelect(chosen)
            self?.dismiss()
        }
        .padding(Self.shadowPad)
        .environment(\.locale, CN.locale)

        let hosting = NSHostingView(rootView: contentView)
        hosting.appearance = parentWindow.effectiveAppearance
        let totalSize = NSSize(
            width: cardWidth + Self.shadowPad * 2,
            height: cardHeight + Self.shadowPad * 2
        )
        hosting.frame = NSRect(origin: .zero, size: totalSize)

        let panel = DSPickerPanel(
            contentRect: NSRect(origin: .zero, size: totalSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.appearance = parentWindow.effectiveAppearance
        panel.contentView = hosting

        var cardOriginX = triggerRect.midX >= parentWindow.frame.midX
            ? triggerRect.maxX - cardWidth
            : triggerRect.minX
        cardOriginX = min(max(cardOriginX, visibleFrame.minX + 8), visibleFrame.maxX - cardWidth - 8)

        var cardOriginY = triggerRect.minY - Self.gap - cardHeight
        if cardOriginY < visibleFrame.minY + 8, spaceAbove > spaceBelow {
            cardOriginY = triggerRect.maxY + Self.gap
        }
        cardOriginY = min(max(cardOriginY, visibleFrame.minY + 8), visibleFrame.maxY - cardHeight - 8)

        panel.setFrameOrigin(NSPoint(
            x: cardOriginX - Self.shadowPad,
            y: cardOriginY - Self.shadowPad
        ))

        panel.alphaValue = 0
        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.parentWindow = parentWindow
        self.isOpen = true
        Self.activeController = self

        installMonitors(parentWindow: parentWindow)
    }

    func dismiss() {
        removeMonitors()
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        parentWindow = nil
        triggerScreenRect = .zero
        if Self.activeController === self {
            Self.activeController = nil
        }
        isOpen = false
    }

    private func measuredCardWidth<Value: Hashable>(
        options: [DSPickerOption<Value>],
        triggerWidth: CGFloat,
        explicitMenuWidth: CGFloat?,
        maxAvailableWidth: CGFloat
    ) -> CGFloat {
        if let explicitMenuWidth {
            return min(DS.s(explicitMenuWidth), maxAvailableWidth)
        }
        let hasSubtitles = options.contains { ($0.subtitle?.isEmpty == false) }
        let titleFont = NSFont.systemFont(ofSize: 14 * DS.fontScale, weight: .semibold)
        let subtitleFont = NSFont.systemFont(ofSize: 12.5 * DS.fontScale, weight: .regular)

        var maxMeasured: CGFloat = 0
        for option in options {
            let titleWidth = (option.title as NSString).size(withAttributes: [.font: titleFont]).width
            maxMeasured = max(maxMeasured, titleWidth + 68)
            if let subtitle = option.subtitle, !subtitle.isEmpty {
                let subWidth = (subtitle as NSString).size(withAttributes: [.font: subtitleFont]).width
                maxMeasured = max(maxMeasured, subWidth + 36)
            }
        }

        if hasSubtitles {
            let minW = max(triggerWidth, DS.s(280))
            let maxW = min(max(triggerWidth, DS.s(360)), maxAvailableWidth)
            return min(max(ceil(maxMeasured), minW), maxW)
        } else {
            let minW = max(triggerWidth, DS.s(124))
            let maxW = min(max(triggerWidth, DS.s(340)), maxAvailableWidth)
            return min(max(ceil(maxMeasured), minW), maxW)
        }
    }

    private func installMonitors(parentWindow: NSWindow) {
        let shadowPad = Self.shadowPad
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            let cardRect = panel.frame.insetBy(dx: shadowPad, dy: shadowPad)
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                let mouse = NSEvent.mouseLocation
                if cardRect.contains(mouse) {
                    return event
                }
                if self.triggerScreenRect.contains(mouse) {
                    self.dismiss()
                    return nil
                }
                self.dismiss()
                return event
            case .keyDown:
                if event.keyCode == 53 { // Escape
                    self.dismiss()
                    return nil
                }
                return event
            case .scrollWheel:
                if !cardRect.contains(NSEvent.mouseLocation) {
                    self.dismiss()
                }
                return event
            default:
                return event
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismiss()
            }
        }

        let nc = NotificationCenter.default
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didResignKeyNotification, parentWindow),
            (NSWindow.willCloseNotification, parentWindow),
            (NSWindow.didMoveNotification, parentWindow),
            (NSWindow.didResizeNotification, parentWindow),
            (NSApplication.didResignActiveNotification, NSApp),
        ]
        observers = names.map { name, obj in
            nc.addObserver(forName: name, object: obj, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismiss()
                }
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        let nc = NotificationCenter.default
        for observer in observers {
            nc.removeObserver(observer)
        }
        observers.removeAll()
    }
}

// MARK: - 菜单卡片与选项行

private struct DSPickerMenuCard<Value: Hashable>: View {
    let options: [DSPickerOption<Value>]
    let selection: Value
    let cardWidth: CGFloat
    let scrollHeight: CGFloat?
    let selectedIndex: Int?
    let onSelect: (Value) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Group {
            if let scrollHeight {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            rows
                        }
                        .padding(6)
                    }
                    .frame(width: cardWidth, height: scrollHeight)
                    .onAppear {
                        if let selectedIndex {
                            proxy.scrollTo(selectedIndex, anchor: .center)
                        }
                    }
                }
            } else {
                VStack(spacing: 2) {
                    rows
                }
                .padding(6)
                .frame(width: cardWidth)
            }
        }
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radius)
                .strokeBorder(DS.borderStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.12), radius: 14, y: 6)
        .shadow(color: .black.opacity(isDark ? 0.25 : 0.05), radius: 2, y: 1)
    }

    private var rows: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            DSPickerMenuRow(
                option: option,
                isSelected: option.value == selection
            ) {
                onSelect(option.value)
            }
            .id(index)
        }
    }
}

private struct DSPickerMenuRow<Value: Hashable>: View {
    let option: DSPickerOption<Value>
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var hasSubtitle: Bool {
        option.subtitle?.isEmpty == false
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: hasSubtitle ? .top : .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: option.title)
                        .font(DS.font(14, isSelected ? .semibold : .regular))
                        .foregroundStyle(DS.text)
                        .lineLimit(hasSubtitle ? 2 : 1)
                        .multilineTextAlignment(.leading)

                    if let subtitle = option.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(DS.font(13, .semibold))
                        .foregroundStyle(DS.toggle)
                        .padding(.top, hasSubtitle ? 2 : 0)
                }
            }
            .padding(.horizontal, hasSubtitle ? 12 : 10)
            .padding(.vertical, hasSubtitle ? 9 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? DS.pickerSelected : hovering ? DS.hover : .clear,
                in: .rect(cornerRadius: DS.controlRadius)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
