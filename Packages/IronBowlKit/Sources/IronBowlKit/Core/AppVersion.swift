import Foundation

/// 应用版本信息（从 `Bundle.main.infoDictionary` 解析并统一格式化）。
public nonisolated struct AppVersionInfo: Sendable, Equatable {
    public let shortVersion: String
    public let buildVersion: String

    public init(shortVersion: String, buildVersion: String = "") {
        self.shortVersion = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        self.buildVersion = buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 展示用短版本号，例如 `v0.1.0`。
    public var displayVersion: String {
        guard !shortVersion.isEmpty else { return "v0.0.0" }
        if shortVersion.hasPrefix("v") {
            return shortVersion
        }
        if shortVersion.hasPrefix("V") {
            return "v" + shortVersion.dropFirst()
        }
        return "v" + shortVersion
    }

    /// 完整版本信息（含构建号），例如 `v0.1.0 (1)`。
    public var fullVersion: String {
        guard !buildVersion.isEmpty else { return displayVersion }
        return "\(displayVersion) (\(buildVersion))"
    }

    public static func from(infoDictionary: [String: Any]?) -> AppVersionInfo {
        let short = (infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let build = (infoDictionary?["CFBundleVersion"] as? String) ?? ""
        return AppVersionInfo(shortVersion: short, buildVersion: build)
    }

    public static var current: AppVersionInfo {
        from(infoDictionary: Bundle.main.infoDictionary)
    }
}

public nonisolated extension Bundle {
    var shortVersion: String {
        AppVersionInfo.from(infoDictionary: infoDictionary).shortVersion
    }

    var buildVersion: String {
        AppVersionInfo.from(infoDictionary: infoDictionary).buildVersion
    }

    var displayVersion: String {
        AppVersionInfo.from(infoDictionary: infoDictionary).displayVersion
    }

    var fullVersion: String {
        AppVersionInfo.from(infoDictionary: infoDictionary).fullVersion
    }
}
