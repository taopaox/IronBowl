import AppKit
import Foundation
import IronBowlKit
import Testing
@testable import AIWebPlugin

@MainActor @Test func presetsAreValidAndAllBundledLogosLoad() {
    #expect(AIWebPresets.all.count == 20)

    let logoStore = AILogoStore(baseDirectory: FileManager.default.temporaryDirectory.appending(path: "ib-logos-\(UUID().uuidString)"))
    for app in AIWebPresets.all {
        #expect(WebURL.normalize(app.url) != nil, "Invalid URL for \(app.name): \(app.url)")
        let loaded = logoStore.image(for: app.logo)
        #expect(loaded != nil, "Missing bundled logo for \(app.name)")
        if let image = loaded?.image {
            #expect(image.size.width >= 64)
            #expect(image.size.height >= 64)
        }
    }

    let pinnedDefaults = AIWebPresets.all.filter(\.isPinned)
    #expect(pinnedDefaults.count == 6)
    #expect(pinnedDefaults.map(\.name) == ["ChatGPT", "Claude", "Gemini", "DeepSeek", "豆包", "Kimi"])
}

@MainActor @Test func initialSeedingAndEmptyPersistenceNotOverwritten() throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-\(UUID().uuidString).sqlite")
    let logoDir = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-logos-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: logoDir)
    }

    let db1 = try AppDatabase(url: dbURL, migrations: [])
    let settings1 = SettingsStore(database: db1)
    let web1 = WebSessionManager(settings: settings1, startTimer: false, headlessForTesting: true)
    let model1 = AIWebModel(settings: settings1, webSessions: web1, logoStore: AILogoStore(baseDirectory: logoDir))

    #expect(model1.apps.count == 20)
    #expect(model1.pinnedApps.count == 6)
    #expect(model1.activeAppID == nil)

    // 全部删除后重新初始化不应自动写回 20 个预设
    for id in model1.apps.map(\.id) {
        model1.deleteApp(id: id)
    }
    #expect(model1.apps.isEmpty)

    let db2 = try AppDatabase(url: dbURL, migrations: [])
    let settings2 = SettingsStore(database: db2)
    let web2 = WebSessionManager(settings: settings2, startTimer: false, headlessForTesting: true)
    let model2 = AIWebModel(settings: settings2, webSessions: web2, logoStore: AILogoStore(baseDirectory: logoDir))
    #expect(model2.apps.isEmpty)
}

@MainActor @Test func crudPinReorderSessionAndPresetRestore() throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-crud-\(UUID().uuidString).sqlite")
    let logoDir = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-crud-logos-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: logoDir)
    }

    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)
    let web = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    let logoStore = AILogoStore(baseDirectory: logoDir)
    let model = AIWebModel(settings: settings, webSessions: web, logoStore: logoStore)

    // 1. 新增自定义 AI
    let custom = model.addApp(
        name: "内部助手",
        url: "ai.company.internal/chat",
        description: "公司内网知识问答",
        category: .custom,
        logo: .remoteURL("https://ai.company.internal/logo.png"),
        isPinned: true,
        neverSuspend: true
    )
    #expect(custom != nil)
    #expect(custom?.url == "https://ai.company.internal/chat")
    #expect(model.apps.count == 21)
    #expect(model.pinnedApps.count == 7)

    // 2. 选中并创建会话
    model.selectApp(custom!.id)
    let session = model.activeSession
    #expect(session != nil)
    #expect(session?.homeURL == "https://ai.company.internal/chat")
    #expect(session?.neverSuspend == true)

    // 3. 修改名称、URL、Logo、免休眠
    let pngData = makeTestPNGData(width: 64, height: 64)
    let localLogo = try logoStore.saveImageData(pngData)
    model.updateApp(
        id: custom!.id,
        name: "研发助手",
        url: "https://ai2.company.internal",
        description: "升级版",
        category: .coding,
        logo: localLogo,
        neverSuspend: false
    )
    let updated = model.app(withID: custom!.id)!
    #expect(updated.name == "研发助手")
    #expect(updated.url == "https://ai2.company.internal")
    #expect(updated.description == "升级版")
    #expect(updated.category == .coding)
    #expect(updated.neverSuspend == false)
    #expect(session?.homeURL == "https://ai2.company.internal")
    #expect(session?.neverSuspend == false)
    #expect(logoStore.image(for: localLogo) != nil)

    // 4. 在仅已固定项之间移动排序（custom 位于第 21 位，前面隔着 14 个未固定项，上移一步应直接与 Kimi 交换）
    model.movePinnedApp(id: custom!.id, delta: -1)
    let pinnedNamesAfterMove = model.pinnedApps.map(\.name)
    #expect(pinnedNamesAfterMove == ["ChatGPT", "Claude", "Gemini", "DeepSeek", "豆包", "研发助手", "Kimi"])

    // 5. 删除自定义 AI：清理会话、清理本地图标文件、回到目录页
    if case let .localFile(filename) = localLogo {
        let filePath = logoDir.appending(path: filename)
        #expect(FileManager.default.fileExists(atPath: filePath.path()))
        model.deleteApp(id: custom!.id)
        #expect(!FileManager.default.fileExists(atPath: filePath.path()))
    } else {
        Issue.record("Expected localFile logo")
    }
    #expect(model.activeAppID == nil)
    #expect(model.existingSession(for: custom!.id) == nil)
    #expect(model.apps.count == 20)

    // 6. 删除一个内置 AI 并修改另一个内置 AI 后，restoreMissingPresets 只补回缺失项、不覆盖用户修改
    let chatgptID = "preset.chatgpt"
    let claudeID = "preset.claude"
    model.renameApp(id: chatgptID, name: "我的 GPT")
    model.deleteApp(id: claudeID)
    #expect(model.apps.count == 19)

    let restoredCount = model.restoreMissingPresets()
    #expect(restoredCount == 1)
    #expect(model.apps.count == 20)
    #expect(model.app(withID: chatgptID)?.name == "我的 GPT")
    #expect(model.app(withID: claudeID)?.name == "Claude")

    // 7. 重置恢复默认
    model.resetToPresets()
    #expect(model.app(withID: chatgptID)?.name == "ChatGPT")
    #expect(model.pinnedApps.count == 6)
}

@MainActor @Test func closeAppReleasesSessionAndReturnsToDirectoryWhenActive() throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-close-\(UUID().uuidString).sqlite")
    let logoDir = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-close-logos-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: logoDir)
    }

    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)
    let web = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    let model = AIWebModel(settings: settings, webSessions: web, logoStore: AILogoStore(baseDirectory: logoDir))

    let firstID = "preset.chatgpt"
    let secondID = "preset.claude"
    #expect(model.hasOpenSession(appID: firstID) == false)

    // 打开两个 AI 网页，停留在第二个
    model.selectApp(firstID)
    _ = model.activeSession
    model.selectApp(secondID)
    _ = model.activeSession
    #expect(model.hasOpenSession(appID: firstID) == true)
    #expect(model.hasOpenSession(appID: secondID) == true)
    #expect(model.activeAppID == secondID)

    // 关闭后台 AI 网页：释放会话但不影响当前视图与应用本身
    model.closeApp(id: firstID)
    #expect(model.hasOpenSession(appID: firstID) == false)
    #expect(model.existingSession(for: firstID) == nil)
    #expect(model.app(withID: firstID) != nil)
    #expect(model.activeAppID == secondID)

    // 关闭当前正在查看的 AI 网页：释放会话并回到 AI 目录总览
    model.closeApp(id: secondID)
    #expect(model.hasOpenSession(appID: secondID) == false)
    #expect(model.activeAppID == nil)
    #expect(model.app(withID: secondID) != nil)
}

@MainActor @Test func manualSuspendVisibleAppAndReSelectWakesIt() async throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-suspend-\(UUID().uuidString).sqlite")
    let logoDir = FileManager.default.temporaryDirectory.appending(path: "ib-aiweb-suspend-logos-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: logoDir)
    }

    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)
    let web = WebSessionManager(settings: settings, startTimer: false, headlessForTesting: true)
    let model = AIWebModel(settings: settings, webSessions: web, logoStore: AILogoStore(baseDirectory: logoDir))

    let geminiID = "preset.gemini"
    model.selectApp(geminiID)
    let session = try #require(model.activeSession)
    let token = UUID()
    web.attachDisplay(sessionID: session.id, token: token)
    #expect(session.state == .active)

    // 可见态点击立即休眠后进入墓碑并延后自动唤醒
    await model.suspendApp(id: geminiID)
    #expect(session.state == .tombstoned)
    #expect(session.deferAutoWake == true)

    // 主动再次点击侧栏该 AI 项时立即唤醒
    model.selectApp(geminiID)
    #expect(session.state == .active)
    #expect(session.deferAutoWake == false)
}

@Test func legacyAIWebAppDecodesWithoutOptionalFields() throws {
    let json = #"{"id":"a1","name":"Custom","url":"https://example.com"}"#
    let decoded = try JSONDecoder().decode(AIWebApp.self, from: Data(json.utf8))
    #expect(decoded.id == "a1")
    #expect(decoded.name == "Custom")
    #expect(decoded.category == .custom)
    #expect(decoded.isPinned == false)
    #expect(decoded.neverSuspend == false)
    #expect(decoded.isBuiltIn == false)
}

private func makeTestPNGData(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
