import AppKit
import Testing
@testable import IronBowlKit

@MainActor @Test func doubleClickActionResolution() {
    #expect(WindowTitleBarDoubleClickAction.resolve(from: nil) == .fill)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "") == .fill)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "Fill") == .fill)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "fill") == .fill)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "Maximize") == .fill)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "Zoom") == .fill)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "Minimize") == .minimize)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "None") == .none)
    #expect(WindowTitleBarDoubleClickAction.resolve(from: "UnknownValue") == .fill)
}

@MainActor @Test func nextFrameFillAndRestoreCycle() {
    let visible = NSRect(x: 0, y: 38, width: 1728, height: 1042)
    let initial = NSRect(x: 300, y: 180, width: 1120, height: 760)

    let filled = WindowTitleBarCoordinator.nextFrame(current: initial, visible: visible, saved: nil)
    #expect(filled.target == visible)
    #expect(filled.nextSaved == initial)

    let restored = WindowTitleBarCoordinator.nextFrame(current: filled.target, visible: visible, saved: filled.nextSaved)
    #expect(restored.target == initial)
    #expect(restored.nextSaved == nil)
}

@MainActor @Test func nextFrameTreatsNearlyEqualWithinToleranceAsFilled() {
    let visible = NSRect(x: 0, y: 38, width: 1728, height: 1042)
    let nearlyVisible = NSRect(x: 1, y: 39, width: 1726, height: 1041)
    let saved = NSRect(x: 200, y: 140, width: 1000, height: 700)

    let restored = WindowTitleBarCoordinator.nextFrame(current: nearlyVisible, visible: visible, saved: saved)
    #expect(restored.target == saved)
    #expect(restored.nextSaved == nil)
}

@MainActor @Test func nextFrameClampsSavedRectInsideSmallerScreen() {
    let smallVisible = NSRect(x: 0, y: 25, width: 1280, height: 775)
    let largeSaved = NSRect(x: 900, y: 400, width: 1400, height: 900)

    let restored = WindowTitleBarCoordinator.nextFrame(current: smallVisible, visible: smallVisible, saved: largeSaved)
    #expect(restored.target.width == 1280)
    #expect(restored.target.height == 775)
    #expect(restored.target.minX == 0)
    #expect(restored.target.minY == 25)
    #expect(restored.nextSaved == nil)
}

@MainActor @Test func nextFrameFallbackWhenAlreadyFilledWithoutSavedRect() {
    let visible = NSRect(x: 0, y: 38, width: 1728, height: 1042)

    let restored = WindowTitleBarCoordinator.nextFrame(current: visible, visible: visible, saved: nil)
    #expect(restored.target.width < visible.width)
    #expect(restored.target.height < visible.height)
    #expect(restored.target.width >= 860)
    #expect(restored.target.height >= 600)
    #expect(restored.nextSaved == nil)
}
