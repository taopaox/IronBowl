import Foundation
import Observation
import Testing
@testable import IronBowlKit

@Test func chineseDateFormats() {
    var c = DateComponents()
    c.year = 2026; c.month = 11; c.day = 25; c.hour = 14; c.minute = 5
    let d = Calendar(identifier: .gregorian).date(from: c)!
    #expect(CN.monthDay(d) == "11月25日")
    #expect(CN.weekdayShort(d) == "周三")
    #expect(CN.weekday(d) == "星期三")
    #expect(CN.time(d) == "14:05")
    #expect(CN.full(d) == "2026年11月25日 星期三")
    #expect(CN.slash(d) == "11/25")
}

@MainActor @Test func settingSameValueDoesNotNotify() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ib-test-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db = try AppDatabase(url: url, migrations: [])
    let s = SettingsStore(database: db)
    let key = SettingKey<Bool>("t", default: false)
    s[key] = true
    final class Flag: @unchecked Sendable { var value = false }
    let notified = Flag()
    withObservationTracking { _ = s[key] } onChange: { notified.value = true }
    s[key] = true
    #expect(!notified.value)
    s[key] = false
    #expect(notified.value)
}

@MainActor @Test func settingsReloadReadsExternalDatabaseWrites() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ib-reload-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let db1 = try AppDatabase(url: url, migrations: [])
    let db2 = try AppDatabase(url: url, migrations: [])
    let s1 = SettingsStore(database: db1)
    let s2 = SettingsStore(database: db2)
    let key = SettingKey<String>("shared.key", default: "init")

    #expect(s2[key] == "init")
    s1[key] = "updated"
    #expect(s2[key] == "init")
    #expect(s2.reload())
    #expect(s2[key] == "updated")
    #expect(!s2.reload())
}
