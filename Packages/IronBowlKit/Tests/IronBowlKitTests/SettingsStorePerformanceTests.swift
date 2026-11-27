import Foundation
import Observation
import Testing
@testable import IronBowlKit

private func makeTempDatabase(dir: URL) throws -> AppDatabase {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try AppDatabase(url: dir.appending(path: "test.sqlite"), migrations: [])
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@MainActor
@Test func settingsStorePerKeyObservationIsolatesUnrelatedReads() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "settings-perf-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try makeTempDatabase(dir: dir)
    let store = SettingsStore(database: db)

    let keyA = SettingKey<String>("perf.keyA", default: "initA")
    let keyB = SettingKey<String>("perf.keyB", default: "initB")

    let invalidatedA = AtomicFlag()
    withObservationTracking {
        _ = store[keyA]
    } onChange: {
        invalidatedA.value = true
    }

    // 修改无关的 keyB，不应触发 keyA 的观察失效
    store[keyB] = "changedB"
    #expect(!invalidatedA.value)

    // 修改 keyA 本身，应精确触发 keyA 的观察失效
    store[keyA] = "changedA"
    #expect(invalidatedA.value)
    #expect(store[keyA] == "changedA")
    #expect(store[keyB] == "changedB")
}

@MainActor
@Test func settingsStoreCachesOptionalNilValuesWithoutReparsing() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "settings-opt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try makeTempDatabase(dir: dir)
    let store = SettingsStore(database: db)

    let optKey = SettingKey<String?>("perf.optKey", default: "fallback")
    #expect(store[optKey] == "fallback")

    store[optKey] = nil
    #expect(store[optKey] == nil)

    // 重新读取同库的另一个实例，确认 nil 已持久化且可正常反序列化
    let reloaded = SettingsStore(database: db)
    #expect(reloaded[optKey] == nil)
}

@MainActor
@Test func settingsStoreDeferredWriteFlushesAndReloadsIncrementally() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "settings-def-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: dir) }
    let db = try makeTempDatabase(dir: dir)
    let writer = SettingsStore(database: db)
    let reader = SettingsStore(database: db)

    let navKey = SettingKey<String>("perf.lastPage", default: "home")
    let otherKey = SettingKey<Int>("perf.counter", default: 1)

    writer.setDeferred("calendar", for: navKey)
    #expect(writer[navKey] == "calendar")

    // flush 前新读实例仍为默认值
    #expect(SettingsStore(database: db)[navKey] == "home")

    writer.flushDeferredWrites()
    #expect(SettingsStore(database: db)[navKey] == "calendar")

    let otherInvalidated = AtomicFlag()
    let navInvalidated = AtomicFlag()
    withObservationTracking {
        _ = reader[otherKey]
    } onChange: {
        otherInvalidated.value = true
    }
    withObservationTracking {
        _ = reader[navKey]
    } onChange: {
        navInvalidated.value = true
    }

    let changed = reader.reload()
    #expect(changed)
    #expect(!otherInvalidated.value)
    #expect(navInvalidated.value)
    #expect(reader[navKey] == "calendar")
}
