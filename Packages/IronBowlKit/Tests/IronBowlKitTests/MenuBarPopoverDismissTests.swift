import AppKit
import Testing
@testable import IronBowlKit

private final class StubWindow: NSWindow {
    var visibleStub = true
    var closeCallCount = 0

    override var isVisible: Bool { visibleStub }

    override func close() {
        closeCallCount += 1
        visibleStub = false
    }
}

private final class StubMenuBarExtraWindow: NSWindow {
    var visibleStub = true
    var closeCallCount = 0

    override var isVisible: Bool { visibleStub }

    override func close() {
        closeCallCount += 1
        visibleStub = false
    }
}

@MainActor @Test func menuBarPopoverWindowClassMatching() {
    #expect(MenuBarPopoverController.isMenuBarPopoverWindowClassName("SwiftUI.MenuBarExtraWindow"))
    #expect(MenuBarPopoverController.isMenuBarPopoverWindowClassName("_TtC7SwiftUI18MenuBarExtraWindow"))
    #expect(MenuBarPopoverController.isMenuBarPopoverWindowClassName("_NSPopoverWindow"))

    #expect(!MenuBarPopoverController.isMenuBarPopoverWindowClassName("NSStatusBarWindow"))
    #expect(!MenuBarPopoverController.isMenuBarPopoverWindowClassName("NSWindow"))
    #expect(!MenuBarPopoverController.isMenuBarPopoverWindowClassName("NSPanel"))
    #expect(!MenuBarPopoverController.isMenuBarPopoverWindowClassName("_TtC11IronBowlKit13DSPickerPanel"))
}

@MainActor @Test func dismissSkipsCloseWhenSwiftUIDismissAlreadyHidWindow() {
    let window = StubMenuBarExtraWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    MenuBarPopoverController.dismiss(
        window: window,
        swiftUIDismiss: { window.visibleStub = false },
        windowsProvider: { [window] }
    )

    #expect(!window.isVisible)
    #expect(window.closeCallCount == 0)
}

@MainActor @Test func dismissClosesWindowWhenSwiftUIDismissLeavesItVisible() {
    let window = StubMenuBarExtraWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )

    MenuBarPopoverController.dismiss(
        window: window,
        swiftUIDismiss: {},
        windowsProvider: { [window] }
    )

    #expect(!window.isVisible)
    #expect(window.closeCallCount == 1)
}

@MainActor @Test func dismissWithoutTargetWindowDoesNotCloseRegularWindows() {
    let regularWindow = StubWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    MenuBarPopoverController.dismiss(
        window: nil,
        swiftUIDismiss: {},
        windowsProvider: { [regularWindow] }
    )

    #expect(regularWindow.isVisible)
    #expect(regularWindow.closeCallCount == 0)
}
