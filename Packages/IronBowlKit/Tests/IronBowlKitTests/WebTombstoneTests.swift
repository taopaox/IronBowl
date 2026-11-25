import Foundation
import Testing
@testable import IronBowlKit

@Test func webURLNormalizationAndComparison() {
    #expect(WebURL.normalize("my.feishu.cn/wiki/123")?.absoluteString == "https://my.feishu.cn/wiki/123")
    #expect(WebURL.normalize("javascript:alert(1)") == nil)
    #expect(WebURL.cleanTitle("架构图 - 飞书云文档", fallbackURL: "https://my.feishu.cn/", stripSuffixes: [" - 飞书云文档"]) == "架构图")
    #expect(WebURL.isSamePage("https://my.feishu.cn/", "https://my.feishu.cn"))
    #expect(!WebURL.isSamePage("https://my.feishu.cn/a", "https://my.feishu.cn/b"))
}

@MainActor @Test func webSessionTombstonePolicies() async throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-web-tombstone-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)

    let manager = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    #expect(manager.tombstoneEnabled == true)
    #expect(manager.idleMinutes == 15)
    #expect(manager.maxLiveCount == 4)

    // 1. 超过闲置时间后自动休眠，未超时的与免休眠、正在显示的保持活跃
    let now = Date()
    let s1 = manager.session(id: "s1", initialURL: "https://example.com/1")
    let s2 = manager.session(id: "s2", initialURL: "https://example.com/2")
    let s3 = manager.session(id: "s3", initialURL: "https://example.com/3", neverSuspend: true)
    let s4 = manager.session(id: "s4", initialURL: "https://example.com/4")

    s1.lastActiveAt = now.addingTimeInterval(-20 * 60) // 20 分钟前，应休眠
    s2.lastActiveAt = now.addingTimeInterval(-5 * 60)  // 5 分钟前，保留
    s3.lastActiveAt = now.addingTimeInterval(-60 * 60) // 免休眠，保留
    let token4 = UUID()
    manager.attachDisplay(sessionID: "s4", token: token4) // 正在显示，保留
    s4.lastActiveAt = now.addingTimeInterval(-60 * 60)

    await manager.sweep(now: now)
    #expect(s1.state == .tombstoned)
    #expect(s2.state == .active)
    #expect(s3.state == .active)
    #expect(s4.state == .active)

    // 2. detachDisplay token 校验：旧 token 不应错误隐藏已重新 attach 的视图
    let newerToken = UUID()
    manager.attachDisplay(sessionID: "s4", token: newerToken)
    manager.detachDisplay(sessionID: "s4", token: token4)
    #expect(s4.isVisible == true)
    manager.detachDisplay(sessionID: "s4", token: newerToken)
    #expect(s4.isVisible == false)

    // 3. 最大保活数 LRU：当前 s2/s3/s4 活跃（共 3 个），把上限设为 3 并新增 s5（正在显示）
    manager.maxLiveCount = 3
    let s5 = manager.session(id: "s5", initialURL: "https://example.com/5")
    let token5 = UUID()
    manager.attachDisplay(sessionID: "s5", token: token5)
    s2.lastActiveAt = now.addingTimeInterval(-100)
    s4.lastActiveAt = now.addingTimeInterval(-200) // 最旧且非免休眠

    await manager.enforceLiveLimit()
    #expect(s4.state == .tombstoned) // 最久未访问的 s4 被 LRU 回收
    #expect(s2.state == .active)     // 较新的 s2 保留
    #expect(s3.state == .active)     // 免休眠保留
    #expect(s5.state == .active)     // 正在显示保留

    // 4. 唤醒与强制休眠
    let token1 = UUID()
    manager.attachDisplay(sessionID: "s1", token: token1)
    #expect(s1.state == .active)
    #expect(s1.tombstonedAt == nil)

    // 关闭总开关后不再自动回收
    manager.tombstoneEnabled = false
    s2.lastActiveAt = now.addingTimeInterval(-120 * 60)
    await manager.sweep(now: now)
    #expect(s2.state == .active)

    // 手动强制休眠对免休眠页也生效
    let forced = await manager.suspend(id: "s3", force: true)
    #expect(forced == true)
    #expect(s3.state == .tombstoned)
}
