import Foundation
import IronBowlKit

public enum FeishuKeys {
    public static let homeURL = SettingKey<String>("feishu.homeURL", default: FeishuURL.defaultHomeURL)
    public static let pinnedPages = SettingKey<[FeishuPinnedPage]>("feishu.pinnedPages", default: [])
    public static let lastPageID = SettingKey<String>("feishu.lastPageID", default: FeishuModel.homePageID)
}

/// 固定在主窗口左侧栏的网页条目。
public nonisolated struct FeishuPinnedPage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var systemImage: String
    public var neverSuspend: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, url, systemImage, neverSuspend
    }

    public init(
        id: String = UUID().uuidString,
        title: String,
        url: String,
        systemImage: String = "doc.text",
        neverSuspend: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.systemImage = systemImage
        self.neverSuspend = neverSuspend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        systemImage = try c.decode(String.self, forKey: .systemImage)
        neverSuspend = try c.decodeIfPresent(Bool.self, forKey: .neverSuspend) ?? false
    }

    public static let iconOptions: [(symbol: String, label: String)] = [
        ("doc.text", "文档"),
        ("book.pages", "知识库"),
        ("tablecells", "表格"),
        ("checklist", "清单"),
        ("folder", "文件夹"),
        ("pin", "图钉"),
        ("star", "收藏"),
        ("globe", "网页"),
    ]
}

/// 飞书网页地址与标题规范化工具（基于通用 WebURL）。
public nonisolated enum FeishuURL {
    public static let defaultHomeURL = "https://my.feishu.cn/"
    private static let titleSuffixes = [" - 飞书云文档", " - 飞书知识库", " - 飞书", " - Lark Docs", " - Lark"]

    public static func normalize(_ raw: String) -> URL? {
        WebURL.normalize(raw)
    }

    public static func cleanTitle(_ raw: String?, fallbackURL: String) -> String {
        WebURL.cleanTitle(raw, fallbackURL: fallbackURL, stripSuffixes: titleSuffixes)
    }

    public static func isSamePage(_ lhs: String, _ rhs: String) -> Bool {
        WebURL.isSamePage(lhs, rhs)
    }
}
