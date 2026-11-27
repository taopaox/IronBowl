import Foundation
import IronBowlKit
import Testing
@testable import FeishuPlugin

@Test func urlNormalizeAndCleanTitle() {
    #expect(FeishuURL.normalize("my.feishu.cn/wiki/abc")?.absoluteString == "https://my.feishu.cn/wiki/abc")
    #expect(FeishuURL.normalize("  https://example.feishu.cn/docx/123  ")?.absoluteString == "https://example.feishu.cn/docx/123")
    #expect(FeishuURL.normalize("javascript:alert(1)") == nil)
    #expect(FeishuURL.normalize("   ") == nil)

    #expect(FeishuURL.cleanTitle("产品周报 - 飞书云文档", fallbackURL: "https://my.feishu.cn/") == "产品周报")
    #expect(FeishuURL.cleanTitle("架构规范 - 飞书知识库", fallbackURL: "https://my.feishu.cn/") == "架构规范")
    #expect(FeishuURL.cleanTitle("", fallbackURL: "https://my.feishu.cn/wiki/abc") == "abc")
    #expect(FeishuURL.cleanTitle(nil, fallbackURL: "https://my.feishu.cn/") == "my.feishu.cn")

    #expect(FeishuURL.isSamePage("https://my.feishu.cn/", "https://my.feishu.cn"))
    #expect(FeishuURL.isSamePage("HTTPS://MY.FEISHU.CN/wiki/1/", "https://my.feishu.cn/wiki/1"))
    #expect(!FeishuURL.isSamePage("https://my.feishu.cn/wiki/1", "https://my.feishu.cn/wiki/2"))
}

@MainActor @Test func pinRenameReorderUnpinAndPersistence() throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-feishu-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    let db1 = try AppDatabase(url: dbURL, migrations: [])
    let settings1 = SettingsStore(database: db1)
    let web1 = WebSessionManager(settings: settings1, startTimer: false, headlessForTesting: true)
    let model1 = FeishuModel(settings: settings1, webSessions: web1)
    #expect(model1.homeURL == "https://my.feishu.cn/")
    #expect(model1.activePageID == FeishuModel.homePageID)
    #expect(model1.pinnedPages.isEmpty)

    let first = model1.pin(title: "研发规范", url: "my.feishu.cn/wiki/spec", systemImage: "book.pages")
    let second = model1.pin(title: "值班表", url: "https://my.feishu.cn/sheets/duty", systemImage: "tablecells", neverSuspend: true)
    #expect(first != nil)
    #expect(second != nil)
    #expect(model1.pinnedPages.count == 2)
    #expect(model1.pinnedPages[0].url == "https://my.feishu.cn/wiki/spec")
    #expect(model1.pinnedPages[1].neverSuspend == true)

    // 重命名、免休眠开关与移动排序
    model1.renamePin(id: first!.id, title: "前端研发规范")
    model1.setNeverSuspend(true, id: first!.id)
    #expect(model1.pinnedPages[0].title == "前端研发规范")
    #expect(model1.pinnedPages[0].neverSuspend == true)

    model1.movePin(id: second!.id, delta: -1)
    #expect(model1.pinnedPages.map(\.id) == [second!.id, first!.id])

    // 选中第二个固定页并检查持久化恢复
    model1.selectPage(second!.id)
    #expect(model1.activePageID == second!.id)

    let db2 = try AppDatabase(url: dbURL, migrations: [])
    let settings2 = SettingsStore(database: db2)
    let web2 = WebSessionManager(settings: settings2, startTimer: false, headlessForTesting: true)
    let model2 = FeishuModel(settings: settings2, webSessions: web2)
    #expect(model2.pinnedPages.count == 2)
    #expect(model2.pinnedPages.map(\.title) == ["值班表", "前端研发规范"])
    #expect(model2.pinnedPages.map(\.neverSuspend) == [true, true])
    #expect(model2.activePageID == second!.id)

    // 取消当前激活的固定页会回退到飞书主页
    model2.unpin(id: second!.id)
    #expect(model2.pinnedPages.count == 1)
    #expect(model2.activePageID == FeishuModel.homePageID)
}

@MainActor @Test func closePageAndCloseActivePageBehavior() throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-feishu-close-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)
    let web = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    var openedPlugins: [String] = []
    let model = FeishuModel(
        settings: settings,
        webSessions: web,
        openPlugin: { openedPlugins.append($0) }
    )

    let pin = model.pin(title: "测试文档", url: "https://my.feishu.cn/wiki/doc1")!
    #expect(model.hasOpenSession(pageID: FeishuModel.homePageID) == false)
    #expect(model.hasOpenSession(pageID: pin.id) == false)

    // 先打开主页再切到固定页
    _ = model.activeSession
    #expect(model.hasOpenSession(pageID: FeishuModel.homePageID) == true)

    model.selectPage(pin.id)
    _ = model.activeSession
    #expect(model.hasOpenSession(pageID: pin.id) == true)

    // 后台关闭主页会话：只销毁主页会话，不切走当前固定页也不触发跳转
    model.closePage(id: FeishuModel.homePageID)
    #expect(model.hasOpenSession(pageID: FeishuModel.homePageID) == false)
    #expect(model.activePageID == pin.id)
    #expect(openedPlugins.isEmpty)

    // 关闭当前激活的固定页：销毁会话、清空 activePageID、保留固定项并跳转回今天首页
    model.closeActivePage()
    #expect(model.hasOpenSession(pageID: pin.id) == false)
    #expect(model.activePageID == nil)
    #expect(model.activeSession == nil)
    #expect(model.pinnedPages.contains(where: { $0.id == pin.id }))
    #expect(openedPlugins == ["home"])
}

@Test func pinnedPageDecodesLegacyJSONWithoutNeverSuspend() throws {
    let legacyJSON = #"{"id":"p1","title":"旧文档","url":"https://my.feishu.cn/wiki/1","systemImage":"doc.text"}"#
    let decoded = try JSONDecoder().decode(FeishuPinnedPage.self, from: Data(legacyJSON.utf8))
    #expect(decoded.id == "p1")
    #expect(decoded.title == "旧文档")
    #expect(decoded.neverSuspend == false)
}

@MainActor @Test func homeNeverSuspendAndManualSuspendBehavior() async throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-feishu-home-suspend-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)
    let web = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    web.armColdLaunchDeferral()

    let model = FeishuModel(settings: settings, webSessions: web)
    #expect(model.homeNeverSuspend == false)

    // 1. 冷启动默认进入墓碑待唤醒态，被动 attachDisplay 不自动加载
    let homeSession = try #require(model.activeSession)
    #expect(homeSession.state == .tombstoned)
    let token = UUID()
    web.attachDisplay(sessionID: FeishuModel.homePageID, token: token)
    #expect(homeSession.state == .tombstoned)

    // 2. 主动点击侧栏主页入口后立即唤醒
    model.selectHome()
    #expect(homeSession.state == .active)

    // 3. 切换主页免休眠会同步写入设置与当前会话
    model.setNeverSuspend(true, id: FeishuModel.homePageID)
    #expect(model.homeNeverSuspend == true)
    #expect(model.isNeverSuspend(pageID: FeishuModel.homePageID) == true)
    #expect(homeSession.neverSuspend == true)

    // 4. 在可见态点立即休眠，即使免休眠也会强制进入墓碑且不自动唤醒
    await model.suspendActivePage()
    #expect(homeSession.state == .tombstoned)
    #expect(homeSession.deferAutoWake == true)
}
