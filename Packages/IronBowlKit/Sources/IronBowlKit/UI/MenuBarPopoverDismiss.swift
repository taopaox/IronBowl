import AppKit
import SwiftUI

/// 关闭当前状态栏（`MenuBarExtra(.window)`）弹出面板的动作。
public nonisolated struct MenuBarPopoverDismissAction: Sendable {
    private let action: @MainActor @Sendable () -> Void

    public init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    @MainActor
    public func callAsFunction() {
        action()
    }
}

private nonisolated struct MenuBarPopoverDismissKey: EnvironmentKey {
    static let defaultValue = MenuBarPopoverDismissAction {
        MenuBarPopoverController.dismiss()
    }
}

public extension EnvironmentValues {
    var dismissMenuBarPopover: MenuBarPopoverDismissAction {
        get { self[MenuBarPopoverDismissKey.self] }
        set { self[MenuBarPopoverDismissKey.self] = newValue }
    }
}

/// 负责关闭状态栏弹出窗口并清理系统菜单栏按钮可能残留的高亮状态。
@MainActor
public enum MenuBarPopoverController {
    /// 判断窗口类名是否为 `MenuBarExtra(.window)` 或标准弹出浮层，严格排除状态栏按钮宿主窗口与普通面板。
    public nonisolated static func isMenuBarPopoverWindowClassName(_ className: String) -> Bool {
        if className.contains("NSStatusBarWindow") {
            return false
        }
        return className.contains("MenuBarExtra") || className.contains("PopoverWindow")
    }

    public static func isMenuBarPopoverWindow(_ window: NSWindow) -> Bool {
        isMenuBarPopoverWindowClassName(NSStringFromClass(type(of: window)))
    }

    /// 优先尝试 SwiftUI 原生 `dismiss()`，若弹出窗口仍可见则兜底关闭对应的 `NSWindow` 并清理状态栏按钮高亮。
    public static func dismiss(
        window: NSWindow? = nil,
        swiftUIDismiss: (@MainActor () -> Void)? = nil,
        windowsProvider: @escaping () -> [NSWindow] = { NSApp?.windows ?? [] }
    ) {
        swiftUIDismiss?()

        let target = window ?? windowsProvider().first { $0.isVisible && isMenuBarPopoverWindow($0) }
        if let target, target.isVisible {
            // `MenuBarExtraWindow` 无 `.closable` 样式，不能用 `performClose`（会触发系统提示音）。
            target.close()
        }

        let clearIfNoPopoverVisible = {
            let windows = windowsProvider()
            guard !windows.contains(where: { $0.isVisible && isMenuBarPopoverWindow($0) }) else { return }
            clearHighlightedStatusBarButtons(in: windows)
        }

        clearIfNoPopoverVisible()
        DispatchQueue.main.async {
            clearIfNoPopoverVisible()
        }
    }

    /// 复位所有状态栏按钮残留的高亮与按下状态，避免下次点击需要按两次才能打开。
    public static func clearHighlightedStatusBarButtons(in windows: [NSWindow]) {
        for window in windows {
            guard let contentView = window.contentView else { continue }
            clearHighlightedButtons(in: contentView)
        }
    }

    private static func clearHighlightedButtons(in view: NSView) {
        if let button = view as? NSStatusBarButton {
            if button.isHighlighted {
                button.highlight(false)
            }
            if button.state != .off {
                button.state = .off
            }
        }
        for subview in view.subviews {
            clearHighlightedButtons(in: subview)
        }
    }
}

@MainActor
private final class MenuBarDismissContext {
    weak var window: NSWindow?
    var swiftUIDismiss: DismissAction?
}

/// 仅用于解析所属 `NSWindow`，不拦截鼠标和悬停事件。
private struct MenuBarWindowResolver: NSViewRepresentable {
    let context: MenuBarDismissContext

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.dismissContext = self.context
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.dismissContext = self.context
        nsView.syncWindow()
    }

    final class ResolverView: NSView {
        weak var dismissContext: MenuBarDismissContext?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncWindow()
        }

        func syncWindow() {
            if let window {
                dismissContext?.window = window
            }
        }
    }
}

private struct MenuBarPopoverDismissModifier: ViewModifier {
    @Environment(\.dismiss) private var swiftUIDismiss
    @State private var dismissContext = MenuBarDismissContext()

    func body(content: Content) -> some View {
        dismissContext.swiftUIDismiss = swiftUIDismiss
        return content
            .background(MenuBarWindowResolver(context: dismissContext))
            .environment(
                \.dismissMenuBarPopover,
                MenuBarPopoverDismissAction {
                    MenuBarPopoverController.dismiss(
                        window: dismissContext.window,
                        swiftUIDismiss: { dismissContext.swiftUIDismiss?() }
                    )
                }
            )
    }
}

public extension View {
    /// 为状态栏 `MenuBarExtra(.window)` 内容视图注入 `\.dismissMenuBarPopover` 关闭能力。
    func menuBarPopoverDismissable() -> some View {
        modifier(MenuBarPopoverDismissModifier())
    }
}
