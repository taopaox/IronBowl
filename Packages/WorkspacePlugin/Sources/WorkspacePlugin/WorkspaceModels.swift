import AppKit
import Foundation
import IronBowlKit

/// 代码仓库工作台设置键。
public enum WorkspaceKeys {
    public static let defaultEditor = SettingKey<String>("workspace.defaultEditor", default: "auto")
    public static let defaultTerminal = SettingKey<String>("workspace.defaultTerminal", default: "auto")
    public static let pinnedRepos = SettingKey<[String]>("workspace.pinnedRepos", default: [])
    public static let extraRepos = SettingKey<[String]>("workspace.extraRepos", default: [])
}

/// 支持的外部代码编辑器。
public nonisolated enum ExternalEditorOption: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case cursor
    case vscode
    case windsurf
    case zed
    case xcode
    case idea
    case androidStudio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "自动识别"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        case .xcode: "Xcode"
        case .idea: "IntelliJ IDEA"
        case .androidStudio: "Android Studio"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .auto: []
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .vscode: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .windsurf: ["com.exafunction.windsurf"]
        case .zed: ["dev.zed.Zed"]
        case .xcode: ["com.apple.dt.Xcode"]
        case .idea: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .androidStudio: ["com.google.android.studio"]
        }
    }

    public var appNames: [String] {
        switch self {
        case .auto: []
        case .cursor: ["Cursor"]
        case .vscode: ["Visual Studio Code"]
        case .windsurf: ["Windsurf"]
        case .zed: ["Zed"]
        case .xcode: ["Xcode"]
        case .idea: ["IntelliJ IDEA", "IntelliJ IDEA CE"]
        case .androidStudio: ["Android Studio"]
        }
    }

    @MainActor
    public func resolvedAppURL() -> URL? {
        if self == .auto {
            for candidate in Self.allCases where candidate != .auto {
                if let url = candidate.resolvedAppURL() { return url }
            }
            return nil
        }
        for bid in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        let fm = FileManager.default
        for name in appNames {
            let paths = [
                "/Applications/\(name).app",
                "\(NSHomeDirectory())/Applications/\(name).app",
            ]
            if let found = paths.first(where: { fm.fileExists(atPath: $0) }) {
                return URL(fileURLWithPath: found)
            }
        }
        return nil
    }

    @MainActor
    private static var cachedInstalledOptions: (expiresAt: Date, options: [ExternalEditorOption])?

    @MainActor
    public static func installedOptions() -> [ExternalEditorOption] {
        let now = Date()
        if let cached = cachedInstalledOptions, cached.expiresAt > now {
            return cached.options
        }
        let resolved = allCases.filter { $0 != .auto && $0.resolvedAppURL() != nil }
        cachedInstalledOptions = (now.addingTimeInterval(60), resolved)
        return resolved
    }
}

/// 支持的外部终端应用。
public nonisolated enum ExternalTerminalOption: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto
    case ghostty
    case iterm
    case warp
    case terminal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "自动识别"
        case .ghostty: "Ghostty"
        case .iterm: "iTerm2"
        case .warp: "Warp"
        case .terminal: "系统终端 (Terminal)"
        }
    }

    public var bundleIdentifiers: [String] {
        switch self {
        case .auto: []
        case .ghostty: ["com.mitchellh.ghostty"]
        case .iterm: ["com.googlecode.iterm2"]
        case .warp: ["dev.warp.Warp-Stable"]
        case .terminal: ["com.apple.Terminal"]
        }
    }

    @MainActor
    public func resolvedAppURL() -> URL? {
        if self == .auto {
            for candidate in Self.allCases where candidate != .auto {
                if let url = candidate.resolvedAppURL() { return url }
            }
            return nil
        }
        for bid in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        return nil
    }

    @MainActor
    private static var cachedInstalledOptions: (expiresAt: Date, options: [ExternalTerminalOption])?

    @MainActor
    public static func installedOptions() -> [ExternalTerminalOption] {
        let now = Date()
        if let cached = cachedInstalledOptions, cached.expiresAt > now {
            return cached.options
        }
        let resolved = allCases.filter { $0 != .auto && $0.resolvedAppURL() != nil }
        cachedInstalledOptions = (now.addingTimeInterval(60), resolved)
        return resolved
    }
}

/// 代码仓库视图筛选类型。
public nonisolated enum WorkspaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case attention = "待处理"
    case todayActive = "今日活跃"
    case pinned = "已收藏"

    public var id: String { rawValue }
}

/// 单个本地 Git 仓库的聚合展示模型。
public nonisolated struct WorkspaceRepoItem: Identifiable, Sendable, Equatable {
    public let path: String
    public let name: String
    public let branch: String
    public let uncommittedCount: Int
    public let unpushedCount: Int
    public let hasUpstream: Bool
    public let lastCommitSubject: String
    public let lastCommitAuthor: String
    public let lastCommitDate: Date?
    public let mappedProjectName: String?
    public let isPinned: Bool
    public let isExtra: Bool
    public let isTodayActive: Bool

    public var id: String { path }
    public var needsAttention: Bool { uncommittedCount > 0 || unpushedCount > 0 }

    public init(
        path: String,
        name: String? = nil,
        branch: String = "",
        uncommittedCount: Int = 0,
        unpushedCount: Int = 0,
        hasUpstream: Bool = false,
        lastCommitSubject: String = "",
        lastCommitAuthor: String = "",
        lastCommitDate: Date? = nil,
        mappedProjectName: String? = nil,
        isPinned: Bool = false,
        isExtra: Bool = false,
        isTodayActive: Bool = false
    ) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.branch = branch
        self.uncommittedCount = uncommittedCount
        self.unpushedCount = unpushedCount
        self.hasUpstream = hasUpstream
        self.lastCommitSubject = lastCommitSubject
        self.lastCommitAuthor = lastCommitAuthor
        self.lastCommitDate = lastCommitDate
        self.mappedProjectName = mappedProjectName
        self.isPinned = isPinned
        self.isExtra = isExtra
        self.isTodayActive = isTodayActive
    }
}

/// 纯函数：仓库排序（收藏优先 -> 待处理优先 -> 今日活跃优先 -> 名称升序）与筛选。
public nonisolated enum WorkspaceRepoSorter {
    public static func sortAndFilter(
        _ items: [WorkspaceRepoItem],
        filter: WorkspaceFilter,
        query: String
    ) -> [WorkspaceRepoItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { item in
                switch filter {
                case .all: break
                case .attention: if !item.needsAttention { return false }
                case .todayActive: if !item.isTodayActive { return false }
                case .pinned: if !item.isPinned { return false }
                }
                if !q.isEmpty {
                    let hit = item.name.localizedCaseInsensitiveContains(q)
                        || item.branch.localizedCaseInsensitiveContains(q)
                        || item.lastCommitSubject.localizedCaseInsensitiveContains(q)
                        || (item.mappedProjectName?.localizedCaseInsensitiveContains(q) == true)
                    if !hit { return false }
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention && !rhs.needsAttention }
                if lhs.isTodayActive != rhs.isTodayActive { return lhs.isTodayActive && !rhs.isTodayActive }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
