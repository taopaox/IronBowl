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
    private static let changeNotification = Notification.Name("com.taopaox.ironbowl.settingsDidChange")

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    @ObservationIgnored public var onExternalChange: (() -> Void)?
    private var cache: [String: String] = [:]

    public init(database: AppDatabase) {
        self.database = database
        cache = Self.loadAll(from: database)
        let myPID = ProcessInfo.processInfo.processIdentifier
        let dbPath = database.path
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.changeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let payload = note.object as? String
            Task { @MainActor [weak self] in
                guard let self, let payload else { return }
                let parts = payload.split(separator: "|", maxSplits: 1)
                guard parts.count == 2,
                      Int32(parts[0]) != myPID,
                      String(parts[1]) == dbPath else { return }
                if self.reload() {
                    self.onExternalChange?()
                }
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    @discardableResult
    public func reload() -> Bool {
        let fresh = Self.loadAll(from: database)
        guard fresh != cache else { return false }
        cache = fresh
        return true
    }

    private static func loadAll(from database: AppDatabase) -> [String: String] {
        let rows = (try? database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM setting")
        }) ?? []
        var result: [String: String] = [:]
        for row in rows {
            result[row["key"]] = row["value"]
        }
        return result
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
            // 值没变就什么都不做：不写库、不触发界面刷新（避免 SwiftUI 绑定回写造成的刷新死循环）。
            guard cache[key.name] != json else { return }
            cache[key.name] = json
            let name = key.name
            try? database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [name, json]
                )
            }
            let payload = "\(ProcessInfo.processInfo.processIdentifier)|\(database.path)"
            DistributedNotificationCenter.default().postNotificationName(
                Self.changeNotification,
                object: payload,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }

    public func binding<Value>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }

    /// 包一层，让顶层的字符串、数字也能用 JSONEncoder。
    private struct Wrapper<V: Codable>: Codable { let v: V }
}
