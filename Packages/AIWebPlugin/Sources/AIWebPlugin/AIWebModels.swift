import Foundation
import IronBowlKit

public enum AIWebKeys {
    /// nil 表示首次使用，启动时写入内置主流 AI；非 nil（含空数组）表示已初始化。
    public static let apps = SettingKey<[AIWebApp]?>("aiweb.apps", default: nil)
    /// 当前选中的 AI ID；nil 代表停留在 AI 目录总览页。
    public static let activeAppID = SettingKey<String?>("aiweb.activeAppID", default: nil)
}

public nonisolated enum AICategory: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case general
    case search
    case coding
    case creative
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: "通用对话"
        case .search: "AI 搜索"
        case .coding: "编程开发"
        case .creative: "创作效率"
        case .custom: "自定义"
        }
    }

    public var detail: String {
        switch self {
        case .general: "日常问答、总结与通用对话助手。"
        case .search: "联网检索、资料查证与引用回答。"
        case .coding: "代码编写、调试与研发辅助。"
        case .creative: "写作、设计、音视频等创作工具。"
        case .custom: "用户自行添加或归类的 AI 工具。"
        }
    }
}

public nonisolated enum AILogoSource: Codable, Hashable, Sendable {
    case bundled(name: String, isTemplate: Bool = false)
    case localFile(filename: String)
    case remoteURL(String)
    case symbol(String)

    public var defaultSymbolFallback: String {
        if case let .symbol(name) = self, !name.isEmpty {
            return name
        }
        return "sparkles"
    }
}

public nonisolated struct AIWebApp: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    public var description: String
    public var category: AICategory
    public var logo: AILogoSource
    public var isPinned: Bool
    public var neverSuspend: Bool
    public var isBuiltIn: Bool
    public var presetID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, description, category, logo, isPinned, neverSuspend, isBuiltIn, presetID
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        description: String = "",
        category: AICategory = .custom,
        logo: AILogoSource = .symbol("sparkles"),
        isPinned: Bool = false,
        neverSuspend: Bool = false,
        isBuiltIn: Bool = false,
        presetID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.description = description
        self.category = category
        self.logo = logo
        self.isPinned = isPinned
        self.neverSuspend = neverSuspend
        self.isBuiltIn = isBuiltIn
        self.presetID = presetID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try c.decodeIfPresent(AICategory.self, forKey: .category) ?? .custom
        logo = try c.decodeIfPresent(AILogoSource.self, forKey: .logo) ?? .symbol("sparkles")
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        neverSuspend = try c.decodeIfPresent(Bool.self, forKey: .neverSuspend) ?? false
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
    }

    public var hostDisplay: String {
        if let parsed = WebURL.normalize(url), let host = parsed.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return url
    }
}
