import Foundation
import Testing
@testable import IronBowlKit

@Test func clipboardPrivacyFilterDetectsSensitivePasteboardTypesAndPasswordManagers() {
    #expect(ClipboardHistoryStore.shouldIgnorePasteboard(
        types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
        sourceBundleID: "com.apple.Safari"
    ))
    #expect(ClipboardHistoryStore.shouldIgnorePasteboard(
        types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"],
        sourceBundleID: nil
    ))
    #expect(ClipboardHistoryStore.shouldIgnorePasteboard(
        types: ["public.utf8-plain-text"],
        sourceBundleID: "com.1password.1password"
    ))
    #expect(ClipboardHistoryStore.shouldIgnorePasteboard(
        types: ["public.utf8-plain-text"],
        sourceBundleID: "com.apple.Passwords"
    ))
    #expect(!ClipboardHistoryStore.shouldIgnorePasteboard(
        types: ["public.utf8-plain-text"],
        sourceBundleID: "com.apple.Terminal"
    ))
}

@Test func clipboardKindClassifierIdentifiesJSONURLCommandAndCode() {
    #expect(ClipboardHistoryStore.classifyKind(#"{"ok":true,"count":3}"#) == .json)
    #expect(ClipboardHistoryStore.classifyKind("https://github.com/taopaox/IronBowl") == .url)
    #expect(ClipboardHistoryStore.classifyKind("curl -X POST https://api.example.com") == .command)
    #expect(ClipboardHistoryStore.classifyKind("func hello() { return }") == .code)
    #expect(ClipboardHistoryStore.classifyKind("今天下午三点开会") == .text)
}

@MainActor @Test func clipboardStoreDeduplicatesAndPrunesHistoryWhileKeepingSnippets() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "clipboard-store-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)
    settings[ClipboardKeys.maxHistoryCount] = 20
    let store = ClipboardHistoryStore(database: db, settings: settings)

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    // 保存常用片段
    let snippet = try #require(store.saveSnippet(title: "测试 cURL", content: "curl https://example.com"))
    #expect(store.snippetItems.count == 1)

    // 写入 22 条历史（超出 maxHistoryCount = 20）
    for i in 1...22 {
        _ = store.recordCopy("history-item-\(i)", sourceApp: "Xcode", now: t0.addingTimeInterval(Double(i)))
    }
    #expect(store.historyItems.count == 20)
    // 常用片段不被裁剪
    #expect(store.snippetItems.map(\.id) == [snippet.id])

    // 重复复制应累加 copyCount 而非新增条目
    let repeated = try #require(store.recordCopy("history-item-22", sourceApp: "Terminal", now: t0.addingTimeInterval(100)))
    #expect(repeated.copyCount == 2)
    #expect(store.historyItems.count == 20)

    // 清空历史仍保留片段
    store.clearHistoryKeepingSnippets()
    #expect(store.historyItems.isEmpty)
    #expect(store.snippetItems.count == 1)
}
