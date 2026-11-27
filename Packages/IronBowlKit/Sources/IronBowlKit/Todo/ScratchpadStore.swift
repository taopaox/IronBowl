import Foundation
import GRDB
import Observation
import SwiftUI

/// 随手便签颜色标签。
public nonisolated enum ScratchpadColorTag: String, Codable, Sendable, CaseIterable, Identifiable {
    case amber
    case green
    case blue
    case purple
    case rose
    case slate

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .amber: "琥珀"
        case .green: "松绿"
        case .blue: "海蓝"
        case .purple: "靛紫"
        case .rose: "朱红"
        case .slate: "素灰"
        }
    }

    @MainActor
    public var tint: Color {
        switch self {
        case .amber: DS.brand
        case .green: DS.success
        case .blue: .blue
        case .purple: .purple
        case .rose: DS.danger
        case .slate: DS.textSecondary
        }
    }
}

/// 随手便签数据模型。
public nonisolated struct ScratchpadNote: Sendable, Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "scratchpadNote"

    public var id: String
    public var title: String
    public var content: String
    public var colorTag: String
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        content: String = "",
        colorTag: ScratchpadColorTag = .amber,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.colorTag = colorTag.rawValue
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var tag: ScratchpadColorTag {
        get { ScratchpadColorTag(rawValue: colorTag) ?? .amber }
        set { colorTag = newValue.rawValue }
    }

    public var displayTitle: String {
        ScratchpadStore.derivedTitle(title: title, content: content)
    }
}

/// 随手便签 / 剪贴板暂存板持久化存储。
@Observable
public final class ScratchpadStore {
    @ObservationIgnored private let database: AppDatabase
    public private(set) var notes: [ScratchpadNote] = []

    public init(database: AppDatabase) {
        self.database = database
        reload()
    }

    public func reload() {
        let fetched: [ScratchpadNote] = (try? database.pool.read { db in
            try ScratchpadNote
                .order(Column("isPinned").desc, Column("updatedAt").desc)
                .fetchAll(db)
        }) ?? []
        notes = fetched
    }

    @discardableResult
    public func createNote(
        title: String = "",
        content: String = "",
        colorTag: ScratchpadColorTag = .amber,
        isPinned: Bool = false
    ) -> ScratchpadNote? {
        let now = Date()
        let note = ScratchpadNote(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content,
            colorTag: colorTag,
            isPinned: isPinned,
            createdAt: now,
            updatedAt: now
        )
        do {
            try database.pool.write { db in
                try note.insert(db)
            }
        } catch {
            return nil
        }
        reload()
        return note
    }

    public func update(_ note: ScratchpadNote) {
        var next = note
        next.updatedAt = Date()
        try? database.pool.write { db in
            try next.update(db)
        }
        reload()
    }

    public func togglePinned(id: String) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.isPinned.toggle()
        note.updatedAt = Date()
        try? database.pool.write { db in
            try note.update(db)
        }
        reload()
    }

    public func delete(id: String) {
        try? database.pool.write { db in
            _ = try ScratchpadNote.deleteOne(db, key: id)
        }
        reload()
    }

    // MARK: - 研发实用纯函数

    public nonisolated static func derivedTitle(title: String, content: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let firstLine = content
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            }
            .first { !$0.isEmpty }
        guard let firstLine, !firstLine.isEmpty else { return "无标题便签" }
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }

    public nonisolated static func formatJSON(_ text: String) -> Result<String, Error> {
        guard let data = text.data(using: .utf8) else {
            return .failure(NSError(domain: "ScratchpadJSON", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的 UTF-8 文本"]))
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            return .success(String(decoding: pretty, as: UTF8.self))
        } catch {
            return .failure(error)
        }
    }

    public nonisolated static func minifyJSON(_ text: String) -> Result<String, Error> {
        guard let data = text.data(using: .utf8) else {
            return .failure(NSError(domain: "ScratchpadJSON", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的 UTF-8 文本"]))
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let compact = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            return .success(String(decoding: compact, as: UTF8.self))
        } catch {
            return .failure(error)
        }
    }
}
