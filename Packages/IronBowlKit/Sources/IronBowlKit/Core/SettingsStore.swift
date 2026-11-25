import Foundation
import GRDB
import Observation
import SwiftUI

/// 强类型的设置键。值以 JSON 存在 `setting` 表里。
public nonisolated struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// 设置存储：内存缓存 + SQLite 持久化，@Observable 让界面自动刷新。
@Observable
public final class SettingsStore {
    @ObservationIgnored private let database: AppDatabase
    private var cache: [String: String] = [:]

    public init(database: AppDatabase) {
        self.database = database
        let rows = (try? database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM setting")
        }) ?? []
        for row in rows {
            cache[row["key"]] = row["value"]
        }
    }

    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            guard let json = cache[key.name], let data = json.data(using: .utf8),
                  let value = try? JSONDecoder().decode(Wrapper<Value>.self, from: data).v
            else { return key.defaultValue }
            return value
        }
        set {
            guard let data = try? JSONEncoder().encode(Wrapper(v: newValue)),
                  let json = String(data: data, encoding: .utf8) else { return }
            cache[key.name] = json
            let name = key.name
            try? database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [name, json]
                )
            }
        }
    }

    public func binding<Value>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }

    /// 包一层，让顶层的字符串、数字也能用 JSONEncoder。
    private struct Wrapper<V: Codable>: Codable { let v: V }
}
