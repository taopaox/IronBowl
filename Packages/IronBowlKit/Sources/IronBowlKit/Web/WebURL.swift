import Foundation

/// 通用网页地址与标题规范化工具。
public nonisolated enum WebURL {
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    public static func cleanTitle(_ raw: String?, fallbackURL: String, stripSuffixes: [String] = []) -> String {
        var title = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in stripSuffixes where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if !title.isEmpty { return title }
        if let url = normalize(fallbackURL) {
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/" { return last }
            if let host = url.host, !host.isEmpty { return host }
        }
        return "未命名网页"
    }

    public static func isSamePage(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = normalize(lhs), let b = normalize(rhs) else {
            return lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return canonicalKey(for: a) == canonicalKey(for: b)
    }

    private static func canonicalKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? url.absoluteString
    }
}
