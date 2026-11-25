import AppKit
import SwiftUI

/// 标题栏双击行为，对应系统设置「桌面与程序坞 → 连按窗口的标题栏以」。
public enum WindowTitleBarDoubleClickAction: Equatable, Sendable {
    case fill
    case minimize
    case none

    public static func resolve(from rawValue: String?) -> Self {
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case nil, "", "fill", "maximize", "zoom":
            return .fill
        case "minimize":
            return .minimize
        case "none":
            return .none
        default:
            return .fill
        }
    }

    public static func currentSystemSetting() -> Self {
        let raw = (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String)
            ?? UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        return resolve(from: raw)
    }
}

/// 管理无标题栏窗口顶部区域的双击填充/恢复及防抖状态。
@MainActor
public final class WindowTitleBarCoordinator {
    public static let shared = WindowTitleBarCoordinator()

    private let savedFrames = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()
    private var lastHandledAt: [ObjectIdentifier: TimeInterval] = [:]

    private init() {}

    public static func framesNearlyEqual(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance
            && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.size.width - b.size.width) <= tolerance
            && abs(a.size.height - b.size.height) <= tolerance
    }

    /// 计算双击填充/恢复的目标 frame 与需要记录的旧 frame。
    public static func nextFrame(
        current: NSRect,
        visible: NSRect,
        saved: NSRect?,
        fallbackSize: NSSize = NSSize(width: 1120, height: 760),
        minSize: NSSize = NSSize(width: 860, height: 600),
        tolerance: CGFloat = 2
    ) -> (target: NSRect, nextSaved: NSRect?) {
        if !framesNearlyEqual(current, visible, tolerance: tolerance) {
            return (target: visible, nextSaved: current)
        }

        if let saved, !framesNearlyEqual(saved, visible, tolerance: tolerance) {
            let minW = min(minSize.width, visible.width)
            let minH = min(minSize.height, visible.height)
            let width = min(max(saved.width, minW), visible.width)
            let height = min(max(saved.height, minH), visible.height)
            let x = min(max(saved.minX, visible.minX), visible.maxX - width)
            let y = min(max(saved.minY, visible.minY), visible.maxY - height)
            return (target: NSRect(x: x, y: y, width: width, height: height), nextSaved: nil)
        }

        let minW = min(minSize.width, visible.width)
        let minH = min(minSize.height, visible.height)
        let targetW = min(visible.width, max(minW, min(fallbackSize.width, floor(visible.width * 0.85))))
        let targetH = min(visible.height, max(minH, min(fallbackSize.height, floor(visible.height * 0.85))))
        let originX = visible.minX + floor((visible.width - targetW) / 2)
        let originY = visible.minY + floor((visible.height - targetH) / 2)
        return (target: NSRect(x: originX, y: originY, width: targetW, height: targetH), nextSaved: nil)
    }

    public func handleDoubleClick(
        on window: NSWindow,
        action: WindowTitleBarDoubleClickAction = .currentSystemSetting()
    ) {
        guard !window.styleMask.contains(.fullScreen) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let key = ObjectIdentifier(window)
        if let last = lastHandledAt[key], now - last < 0.15 {
            return
        }
        lastHandledAt[key] = now

        switch action {
        case .none:
            return
        case .minimize:
            if window.styleMask.contains(.miniaturizable) {
                window.performMiniaturize(nil)
            }
        case .fill:
            guard window.styleMask.contains(.resizable),
                  let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            else { return }
            let saved = savedFrames.object(forKey: window)?.rectValue
            let (target, nextSaved) = Self.nextFrame(
                current: window.frame,
                visible: visible,
                saved: saved,
                minSize: window.minSize
            )
            if let nextSaved {
                savedFrames.setObject(NSValue(rect: nextSaved), forKey: window)
            } else {
                savedFrames.removeObject(forKey: window)
            }
            window.setFrame(target, display: true, animate: true)
        }
    }
}

/// 仅用于读取所属 NSWindow，不拦截鼠标和悬停事件。
private struct WindowResolver: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.notifyIfNeeded()
    }

    final class ResolverView: NSView {
        var onResolve: ((NSWindow?) -> Void)?
        private weak var lastReportedWindow: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            notifyIfNeeded()
        }

        func notifyIfNeeded() {
            let current = window
            guard current !== lastReportedWindow else { return }
            lastReportedWindow = current
            let callback = onResolve
            DispatchQueue.main.async {
                callback?(current)
            }
        }
    }
}

private struct WindowTitleBarSurface: View {
    @State private var window: NSWindow?

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .background(WindowResolver { window = $0 })
            .onTapGesture(count: 2) {
                if let target = window ?? NSApp.keyWindow {
                    WindowTitleBarCoordinator.shared.handleDoubleClick(on: target)
                }
            }
            .simultaneousGesture(WindowDragGesture())
    }
}

/// 顶部透明可拖动、可双击填充/恢复的标题栏占位区域。
public struct WindowTitleBarArea: View {
    let height: CGFloat

    public init(height: CGFloat = 52) {
        self.height = height
    }

    public var body: some View {
        WindowTitleBarSurface()
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

public extension View {
    /// 为自定义顶栏空白区域补上原生窗口拖拽与双击填充/恢复能力。
    func windowTitleBar() -> some View {
        background(WindowTitleBarSurface())
    }
}
