import AppKit
import Foundation
import SwiftUI
import Testing
@testable import IronBowlKit

@MainActor @Test func journalStatusStateAndSidebarBadgeSmoke() {
    let color = DS.danger
    let badge = SidebarBadge("今日未写", color: color)
    #expect(badge.text == "今日未写")
    #expect(badge == SidebarBadge("今日未写", color: color))

    func srgb(_ c: Color) -> NSColor? {
        NSColor(c).usingColorSpace(.sRGB)
    }

    let palette = JournalPalette(preset: .warm)
    #expect(srgb(JournalStatusState.unwritten.color(in: palette)) == srgb(palette.stampRed))
    #expect(srgb(JournalStatusState.draft.color(in: palette)) == srgb(palette.stampAmber))
    #expect(srgb(JournalStatusState.completed.color(in: palette)) == srgb(palette.stampGreen))
    #expect(srgb(JournalStatusState.offDay.color(in: palette)) == srgb(palette.inkTertiary))
}

@Test func journalHighlightKeyNormalizesWhitespace() {
    let k1 = JournalHighlight.key(date: "2026-11-26", work: "  完成导出重构\n  与单测  ")
    let k2 = JournalHighlight.key(date: "2026-11-26", work: "完成导出重构 与单测")
    #expect(k1 == "2026-11-26|完成导出重构 与单测")
    #expect(k1 == k2)
    #expect(JournalHighlight.key(date: "2026-11-26", work: "   \n ") == "")
}

@MainActor @Test func journalHighlightTogglesPersistsAndCaps() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "journal-hl-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)

    #expect(settings[JournalKeys.paperPreset] == .warm)
    settings[JournalKeys.paperPreset] = .clean
    #expect(settings[JournalKeys.paperPreset] == .clean)

    #expect(!JournalHighlight.isHighlighted(date: "2026-11-26", work: "导出模块优化", in: settings))
    JournalHighlight.toggle(date: "2026-11-26", work: "  导出模块优化 ", in: settings)
    #expect(JournalHighlight.isHighlighted(date: "2026-11-26", work: "导出模块优化", in: settings))

    // 二次切换取消高亮
    JournalHighlight.toggle(date: "2026-11-26", work: "导出模块优化", in: settings)
    #expect(!JournalHighlight.isHighlighted(date: "2026-11-26", work: "导出模块优化", in: settings))

    // 超过上限时保留最近 maxStoredCount 条
    for i in 0..<(JournalHighlight.maxStoredCount + 15) {
        JournalHighlight.toggle(date: "2026-11-26", work: "事项 \(i)", in: settings)
    }
    let stored = settings[JournalKeys.highlightedItems]
    #expect(stored.count == JournalHighlight.maxStoredCount)
    #expect(!JournalHighlight.isHighlighted(date: "2026-11-26", work: "事项 0", in: settings))
    #expect(JournalHighlight.isHighlighted(date: "2026-11-26", work: "事项 \(JournalHighlight.maxStoredCount + 14)", in: settings))
}
