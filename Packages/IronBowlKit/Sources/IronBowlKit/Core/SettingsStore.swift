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

@Observable
private final class SettingKeySignal {
    var revision = 0
}

/// 设置存储：按键粒度 @Observable + 解码内存缓存 + SQLite 持久化。
public final class SettingsStore {
    private static let changeNotification = Notification.Name("com.taopaox.ironbowl.settingsDidChange")

    private struct DecodedBox<Value> {
        let value: Value
    }

    private let database: AppDatabase
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    public var onExternalChange: (() -> Void)?

    private var cache: [String: String] = [:]
    private var decodedCache: [String: Any] = [:]
    private var signals: [String: SettingKeySignal] = [:]
    private var pendingDeferredWrites: [String: String] = [:]
    private var deferredFlushTask: Task<Void, Never>?
    private var broadcastTask: Task<Void, Never>?
    private var pendingExternalBroadcast = false

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

    private func signal(for keyName: String) -> SettingKeySignal {
        if let existing = signals[keyName] {
            return existing
        }
        let created = SettingKeySignal()
        signals[keyName] = created
        return created
    }

    private func notifyKeyChanged(_ keyName: String) {
        decodedCache.removeValue(forKey: keyName)
        signals[keyName]?.revision &+= 1
    }

    private func scheduleExternalBroadcast() {
        pendingExternalBroadcast = true
        guard broadcastTask == nil else { return }
        broadcastTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.pendingExternalBroadcast else {
                self?.broadcastTask = nil
                return
            }
            self.pendingExternalBroadcast = false
            self.broadcastTask = nil
            self.postExternalChangeNotification()
        }
    }

    private func postExternalChangeNotification() {
        let payload = "\(ProcessInfo.processInfo.processIdentifier)|\(database.path)"
        DistributedNotificationCenter.default().postNotificationName(
            Self.changeNotification,
            object: payload,
            userInfo: nil,
            deliverImmediately: false
        )
    }

    @discardableResult
    public func reload() -> Bool {
        let fresh = Self.loadAll(from: database)
        guard fresh != cache else { return false }
        let old = cache
        cache = fresh
        for key in Set(old.keys).union(fresh.keys) where old[key] != fresh[key] {
            notifyKeyChanged(key)
        }
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
            _ = signal(for: key.name).revision
            if let box = decodedCache[key.name] as? DecodedBox<Value> {
                return box.value
            }
            let resolved: Value
            if let json = cache[key.name],
               let data = json.data(using: .utf8),
               let value = try? JSONDecoder().decode(Wrapper<Value>.self, from: data).v {
                resolved = value
            } else {
                resolved = key.defaultValue
            }
            decodedCache[key.name] = DecodedBox(value: resolved)
            return resolved
        }
        set {
            guard let data = try? JSONEncoder().encode(Wrapper(v: newValue)),
                  let json = String(data: data, encoding: .utf8) else { return }
            // 值没变就什么都不做：不写库、不触发界面刷新（避免 SwiftUI 绑定回写造成的刷新死循环）。
            guard cache[key.name] != json else { return }
            cache[key.name] = json
            decodedCache[key.name] = DecodedBox(value: newValue)
            pendingDeferredWrites.removeValue(forKey: key.name)
            signals[key.name]?.revision &+= 1

            let name = key.name
            try? database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO setting(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [name, json]
                )
            }
            scheduleExternalBroadcast()
        }
    }

    /// 更新内存缓存并防抖批量写入 SQLite，适用于高频 UI 导航状态持久化（如上次选中页），避免切页阻塞主线程。
    public func setDeferred<Value>(_ value: Value, for key: SettingKey<Value>, broadcastExternally: Bool = false) {
        guard let data = try? JSONEncoder().encode(Wrapper(v: value)),
              let json = String(data: data, encoding: .utf8) else { return }
        guard cache[key.name] != json else { return }
        cache[key.name] = json
        decodedCache[key.name] = DecodedBox(value: value)
        signals[key.name]?.revision &+= 1
        pendingDeferredWrites[key.name] = json

        if broadcastExternally {
            scheduleExternalBroadcast()
        }

        deferredFlushTask?.cancel()
        deferredFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushDeferredWrites()
        }
    }

    /// 立即将所有待延迟落盘的设置项批量写入 SQLite。
    public func flushDeferredWrites() {
        deferredFlushTask?.cancel()
        deferredFlushTask = nil
        guard !pendingDeferredWrites.isEmpty else { return }
        let batch = pendingDeferredWrites
        pendingDeferredWrites.removeAll()
        try? database.pool.write { db in
            for (name, json) in batch {
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
