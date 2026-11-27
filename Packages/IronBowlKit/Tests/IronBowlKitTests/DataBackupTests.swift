import Foundation
import Testing
@testable import IronBowlKit

@MainActor
@Test func dataBackupExportsAndRestoresDatabaseAndAssetDirectories() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "backup-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceSupport = root.appending(path: "src-support", directoryHint: .isDirectory)
    let destSupport = root.appending(path: "dst-support", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceSupport.appending(path: "user-avatars", directoryHint: .isDirectory), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destSupport, withIntermediateDirectories: true)

    let avatarData = Data("fake-png-bytes".utf8)
    try avatarData.write(to: sourceSupport.appending(path: "user-avatars/avatar.png"))

    let srcDB = try AppDatabase(url: sourceSupport.appending(path: "ironbowl.sqlite"), migrations: [])
    let srcSettings = SettingsStore(database: srcDB)
    srcSettings[UserProfileKeys.displayName] = "张饭碗"
    let srcTodos = TodoStore(database: srcDB)
    srcTodos.add(title: "验证数据备份恢复", priority: .important, estimatedHours: 1.5)
    let srcNotes = ScratchpadStore(database: srcDB)
    srcNotes.createNote(title: "密钥备忘", content: "{\"env\":\"prod\"}", colorTag: .blue, isPinned: true)

    let zipURL = root.appending(path: "IronBowl-Backup.zip")
    let exported = try await DataBackupService.exportBackup(
        database: srcDB,
        supportDirectory: sourceSupport,
        appVersion: "v0.4.1",
        to: zipURL
    )
    #expect(FileManager.default.fileExists(atPath: zipURL.path))
    #expect(exported.settingsCount >= 1)
    #expect(exported.todosCount == 1)
    #expect(exported.notesCount == 1)
    #expect(exported.includedDirectories == ["user-avatars"])

    let dstDB = try AppDatabase(url: destSupport.appending(path: "ironbowl.sqlite"), migrations: [])
    let restored = try await DataBackupService.restoreBackup(
        from: zipURL,
        into: dstDB,
        supportDirectory: destSupport,
        migrations: []
    )
    #expect(restored.todosCount == 1)
    #expect(restored.notesCount == 1)

    let dstSettings = SettingsStore(database: dstDB)
    #expect(dstSettings[UserProfileKeys.displayName] == "张饭碗")
    let dstTodos = TodoStore(database: dstDB)
    #expect(dstTodos.items.map(\.title) == ["验证数据备份恢复"])
    let dstNotes = ScratchpadStore(database: dstDB)
    #expect(dstNotes.notes.first?.title == "密钥备忘")
    #expect(dstNotes.notes.first?.isPinned == true)
    #expect(FileManager.default.fileExists(atPath: destSupport.appending(path: "user-avatars/avatar.png").path))
}
