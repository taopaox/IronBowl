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
    #expect(manager.idleMinutes == 5)
    #expect(manager.maxLiveCount == 2)
    #expect(manager.windowCloseSeconds == 60)

    // 先放宽保活上限至 4，单独验证闲置时长休眠逻辑
    manager.maxLiveCount = 4

    // 1. 超过闲置时间后自动休眠，未超时的与免休眠、正在显示的保持活跃
    let now = Date()
    #expect(manager.hasSession(id: "s1") == false)
    let s1 = manager.session(id: "s1", initialURL: "https://example.com/1")
    #expect(manager.hasSession(id: "s1") == true)
    let s2 = manager.session(id: "s2", initialURL: "https://example.com/2")
    let s3 = manager.session(id: "s3", initialURL: "https://example.com/3", neverSuspend: true)
    let s4 = manager.session(id: "s4", initialURL: "https://example.com/4")

    s1.lastActiveAt = now.addingTimeInterval(-6 * 60)  // 6 分钟前，超过默认 5 分钟应休眠
    s2.lastActiveAt = now.addingTimeInterval(-2 * 60)  // 2 分钟前，保留
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

    // 手动强制休眠对免休眠页也生效，且休眠状态仍保留会话直到显式移除
    let forced = await manager.suspend(id: "s3", force: true)
    #expect(forced == true)
    #expect(s3.state == .tombstoned)
    #expect(manager.hasSession(id: "s3") == true)

    // 关闭（移除）网页会话后 hasSession 变为 false
    manager.remove(id: "s3")
    #expect(manager.hasSession(id: "s3") == false)
    #expect(manager.existingSession(id: "s3") == nil)
}

@MainActor @Test func webSessionWindowCloseFastTombstone() async throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-web-window-close-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)

    let manager = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    manager.idleMinutes = 30
    manager.maxLiveCount = 4
    manager.windowCloseSeconds = 60

    let t0 = Date()
    let s1 = manager.session(id: "w1", initialURL: "https://example.com/w1")
    let s2 = manager.session(id: "w2", initialURL: "https://example.com/w2")
    let s3 = manager.session(id: "w3", initialURL: "https://example.com/w3", neverSuspend: true)
    s1.lastActiveAt = t0
    s2.lastActiveAt = t0
    s3.lastActiveAt = t0

    let token1 = UUID()
    manager.attachDisplay(sessionID: "w1", token: token1)
    #expect(s1.isVisible == true)

    // 1. 关闭主窗口时立即将网页标为后台；未满 60 秒前不休眠
    manager.setHostWindowOpen(false, now: t0)
    #expect(manager.isHostWindowOpen == false)
    #expect(s1.isVisible == false)
    await manager.sweep(now: t0.addingTimeInterval(30))
    #expect(s1.state == .active)
    #expect(s2.state == .active)
    #expect(s3.state == .active)

    // 2. 在超时前重新打开主窗口应取消快速休眠
    manager.setHostWindowOpen(true, now: t0.addingTimeInterval(40))
    #expect(manager.isHostWindowOpen == true)
    await manager.sweep(now: t0.addingTimeInterval(90))
    #expect(s1.state == .active)
    #expect(s2.state == .active)

    // 3. 再次关闭主窗口且满 60 秒后，可休眠页自动墓碑化，免休眠页仍保留
    let t1 = t0.addingTimeInterval(100)
    manager.setHostWindowOpen(false, now: t1)
    await manager.sweep(now: t1.addingTimeInterval(60))
    #expect(s1.state == .tombstoned)
    #expect(s2.state == .tombstoned)
    #expect(s3.state == .active)

    // 4. 设为 0（跟随后台闲置时长）后不再触发关窗加速回收
    manager.windowCloseSeconds = 0
    let s4 = manager.session(id: "w4", initialURL: "https://example.com/w4")
    s4.lastActiveAt = t1
    manager.setHostWindowOpen(false, now: t1)
    await manager.sweep(now: t1.addingTimeInterval(120))
    #expect(s4.state == .active)

    // 5. 启用定时调度时，关窗满配置秒数后自动触发休眠
    let scheduledManager = WebSessionManager(settings: settings, startTimer: true, headlessForTesting: true)
    defer { scheduledManager.stop() }
    scheduledManager.idleMinutes = 30
    scheduledManager.maxLiveCount = 4
    scheduledManager.windowCloseSeconds = 1
    let timed = scheduledManager.session(id: "timed", initialURL: "https://example.com/timed")
    scheduledManager.setHostWindowOpen(false)
    let deadline = Date().addingTimeInterval(3)
    while timed.state != .tombstoned, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(100))
    }
    #expect(timed.state == .tombstoned)
}

@MainActor @Test func coldLaunchDeferralAndVisibleManualSuspend() async throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-web-cold-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)

    let manager = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    manager.armColdLaunchDeferral()

    // 1. 首个冷启动恢复挂载的网页应保持在墓碑待唤醒状态，被动 attachDisplay 不自动唤醒
    let s1 = manager.session(id: "cold.1", initialURL: "https://example.com/1")
    #expect(s1.state == .tombstoned)
    #expect(s1.deferAutoWake == true)

    let token1 = UUID()
    manager.attachDisplay(sessionID: "cold.1", token: token1)
    #expect(s1.isVisible == true)
    #expect(s1.state == .tombstoned)

    // 2. 延后标记仅作用于首个会话，后续会话正常激活
    let s2 = manager.session(id: "cold.2", initialURL: "https://example.com/2")
    #expect(s2.state == .active)
    #expect(s2.deferAutoWake == false)

    // 3. 点击墓碑卡片「重新唤醒」(forceWake: true) 后立即恢复活跃
    manager.attachDisplay(sessionID: "cold.1", token: token1, forceWake: true)
    #expect(s1.state == .active)
    #expect(s1.deferAutoWake == false)

    // 4. 在可见态手动强制休眠后，标记 deferAutoWake，被动重新挂载不唤醒，主动 allowAutoWake 后立即唤醒
    let suspended = await manager.suspend(id: "cold.1", force: true)
    #expect(suspended == true)
    #expect(s1.state == .tombstoned)
    #expect(s1.deferAutoWake == true)

    let token2 = UUID()
    manager.attachDisplay(sessionID: "cold.1", token: token2)
    #expect(s1.state == .tombstoned)

    manager.allowAutoWake(id: "cold.1")
    #expect(s1.state == .active)
    #expect(s1.deferAutoWake == false)
}
