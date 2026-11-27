import AppKit
import Foundation
import IronBowlKit
import Testing

@MainActor
@Test func userProfileDefaultFallbackBehavior() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: "user-profile-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let db = try AppDatabase(url: tempDir.appending(path: "db.sqlite"), migrations: [])
    let settings = SettingsStore(database: db)

    let withSystemName = UserProfileStore(
        settings: settings,
        avatarsDirectory: tempDir.appending(path: "avatars"),
        systemNameProvider: { "  张三  " }
    )
    #expect(withSystemName.fallbackDisplayName == "张三")
    #expect(withSystemName.effectiveDisplayName == "张三")
    #expect(withSystemName.effectiveSlogan == nil)
    #expect(withSystemName.hasCustomAvatar == false)

    let emptySystemName = UserProfileStore(
        settings: settings,
        avatarsDirectory: tempDir.appending(path: "avatars"),
        systemNameProvider: { "   \n " }
    )
    #expect(emptySystemName.fallbackDisplayName == "我")
    #expect(emptySystemName.effectiveDisplayName == "我")
}

@MainActor
@Test func userProfileUpdateTrimsAndPersistsAcrossReload() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: "user-profile-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let dbURL = tempDir.appending(path: "db.sqlite")
    let avatarsDir = tempDir.appending(path: "avatars")
    let db1 = try AppDatabase(url: dbURL, migrations: [])
    let store1 = UserProfileStore(
        settings: SettingsStore(database: db1),
        avatarsDirectory: avatarsDir,
        systemNameProvider: { "yxhc" }
    )

    store1.update(displayName: "  王小明  ", slogan: "  稳稳当当干饭  ")
    #expect(store1.displayName == "王小明")
    #expect(store1.slogan == "稳稳当当干饭")
    #expect(store1.effectiveDisplayName == "王小明")
    #expect(store1.effectiveSlogan == "稳稳当当干饭")

    let db2 = try AppDatabase(url: dbURL, migrations: [])
    let store2 = UserProfileStore(
        settings: SettingsStore(database: db2),
        avatarsDirectory: avatarsDir,
        systemNameProvider: { "yxhc" }
    )
    #expect(store2.effectiveDisplayName == "王小明")
    #expect(store2.effectiveSlogan == "稳稳当当干饭")

    store2.update(displayName: "   ", slogan: "\t  ")
    #expect(store2.effectiveDisplayName == "yxhc")
    #expect(store2.effectiveSlogan == nil)
}

@MainActor
@Test func userProfileAvatarSaveScaleReplaceAndClear() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: "user-profile-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let dbURL = tempDir.appending(path: "db.sqlite")
    let avatarsDir = tempDir.appending(path: "avatars")
    let db1 = try AppDatabase(url: dbURL, migrations: [])
    let store1 = UserProfileStore(
        settings: SettingsStore(database: db1),
        avatarsDirectory: avatarsDir,
        systemNameProvider: { "yxhc" }
    )

    let largeImageData = try makeSamplePNGData(width: 400, height: 200, color: .systemOrange)
    try store1.saveAvatarData(largeImageData)

    let firstFilename = try #require(store1.avatarFilename)
    let firstFileURL = avatarsDir.appending(path: firstFilename)
    #expect(FileManager.default.fileExists(atPath: firstFileURL.path))
    #expect(store1.hasCustomAvatar)
    let savedRep = try #require(NSBitmapImageRep(data: Data(contentsOf: firstFileURL)))
    #expect(savedRep.pixelsWide == 256)
    #expect(savedRep.pixelsHigh == 128)

    let db2 = try AppDatabase(url: dbURL, migrations: [])
    let store2 = UserProfileStore(
        settings: SettingsStore(database: db2),
        avatarsDirectory: avatarsDir,
        systemNameProvider: { "yxhc" }
    )
    #expect(store2.hasCustomAvatar)
    #expect(store2.avatarFilename == firstFilename)

    let secondImageData = try makeSamplePNGData(width: 120, height: 120, color: .systemBlue)
    try store2.saveAvatarData(secondImageData)
    let secondFilename = try #require(store2.avatarFilename)
    #expect(secondFilename != firstFilename)
    #expect(!FileManager.default.fileExists(atPath: firstFileURL.path))
    #expect(FileManager.default.fileExists(atPath: avatarsDir.appending(path: secondFilename).path))

    store2.clearAvatar()
    #expect(store2.avatarFilename == nil)
    #expect(!store2.hasCustomAvatar)
    #expect(!FileManager.default.fileExists(atPath: avatarsDir.appending(path: secondFilename).path))
}

@MainActor
@Test func userProfileInvalidImageDataThrowsAndPreservesExistingAvatar() throws {
    let tempDir = FileManager.default.temporaryDirectory.appending(path: "user-profile-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let db = try AppDatabase(url: tempDir.appending(path: "db.sqlite"), migrations: [])
    let avatarsDir = tempDir.appending(path: "avatars")
    let store = UserProfileStore(
        settings: SettingsStore(database: db),
        avatarsDirectory: avatarsDir,
        systemNameProvider: { "yxhc" }
    )

    let validData = try makeSamplePNGData(width: 64, height: 64, color: .systemGreen)
    try store.saveAvatarData(validData)
    let existingFilename = try #require(store.avatarFilename)

    #expect(throws: UserProfileError.invalidImageData) {
        try store.saveAvatarData(Data("not an image".utf8))
    }
    #expect(store.avatarFilename == existingFilename)
    #expect(store.hasCustomAvatar)
    #expect(FileManager.default.fileExists(atPath: avatarsDir.appending(path: existingFilename).path))
}

private func makeSamplePNGData(width: Int, height: Int, color: NSColor) throws -> Data {
    guard let rep = NSBitmapImageRep(
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
    ) else {
        throw UserProfileError.invalidImageData
    }
    rep.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw UserProfileError.invalidImageData
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw UserProfileError.invalidImageData
    }
    return data
}
