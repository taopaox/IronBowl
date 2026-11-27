import AppKit
import Foundation
import IronBowlKit
import Observation
import SwiftUI
import ZentaoLogPlugin

@Observable
final class DevToolsModel {
    private static let workspaceExtraReposKey = SettingKey<[String]>("workspace.extraRepos", default: [])

    let context: PluginContext
    var ports: [ListeningPortItem] = []
    var isScanningPorts = false
    var portQuery = ""
    var portGroupScope: PortGroupScope = .all
    var portStatusMessage: String?
    var portErrorMessage: String?

    @ObservationIgnored private var cachedDevDirsKey: (gitRoot: String, extra: [String], custom: [String])?
    @ObservationIgnored private var cachedDevDirEntries: [DevDirectoryEntry] = []
    @ObservationIgnored private var cachedAllPartitionKey: (ports: [ListeningPortItem], dirPaths: [String])?
    @ObservationIgnored private var cachedAllPartitionValue: PortPartition?
    @ObservationIgnored private var cachedFilteredPartitionKey: (ports: [ListeningPortItem], query: String, dirPaths: [String])?
    @ObservationIgnored private var cachedFilteredPartitionValue: PortPartition?

    init(context: PluginContext) {
        self.context = context
    }

    var watchedPorts: [Int] {
        get { context.settings[DevToolsKeys.watchedPorts] }
        set { context.settings[DevToolsKeys.watchedPorts] = newValue }
    }

    var customDevDirectories: [String] {
        get { context.settings[DevToolsKeys.devDirectories] }
        set { context.settings[DevToolsKeys.devDirectories] = newValue }
    }

    var effectiveDevDirectoryEntries: [DevDirectoryEntry] {
        let gitRoot = GitScanner.configuredGitRoot(settings: context.settings)
        let extra = context.settings[Self.workspaceExtraReposKey]
        let custom = customDevDirectories
        if let cachedKey = cachedDevDirsKey,
           cachedKey.gitRoot == gitRoot && cachedKey.extra == extra && cachedKey.custom == custom {
            return cachedDevDirEntries
        }

        var candidates: [(String, DevDirectorySource)] = []
        if !gitRoot.isEmpty {
            candidates.append((gitRoot, .gitRoot))
        }
        for repo in extra {
            candidates.append((repo, .workspaceExtra))
        }
        for dir in custom {
            candidates.append((dir, .custom))
        }

        var seen = Set<String>()
        var result: [DevDirectoryEntry] = []
        for (raw, source) in candidates {
            let normalized = PortDirectoryMatcher.normalizePath(raw, resolveSymlinks: true)
            guard PortDirectoryMatcher.isUsableRootDirectory(normalized),
                  seen.insert(normalized).inserted else {
                continue
            }
            result.append(DevDirectoryEntry(path: normalized, source: source))
        }
        cachedDevDirsKey = (gitRoot, extra, custom)
        cachedDevDirEntries = result
        return result
    }

    var effectiveDevDirectoryPaths: [String] {
        effectiveDevDirectoryEntries.map(\.path)
    }

    var activeWatchedCount: Int {
        let watched = Set(watchedPorts)
        return Set(ports.map(\.port)).intersection(watched).count
    }

    var allPartition: PortPartition {
        let currentPorts = ports
        let dirPaths = effectiveDevDirectoryPaths
        if let key = cachedAllPartitionKey,
           let val = cachedAllPartitionValue,
           key.ports == currentPorts && key.dirPaths == dirPaths {
            return val
        }
        let computed = PortDirectoryMatcher.partition(currentPorts, devDirectories: dirPaths)
        cachedAllPartitionKey = (currentPorts, dirPaths)
        cachedAllPartitionValue = computed
        return computed
    }

    var filteredPorts: [ListeningPortItem] {
        let q = portQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ports }
        let devDirs = effectiveDevDirectoryPaths
        return ports.filter { item in
            if "\(item.port)".contains(q)
                || item.processName.localizedCaseInsensitiveContains(q)
                || item.commandLine.localizedCaseInsensitiveContains(q)
                || item.workingDirectory.localizedCaseInsensitiveContains(q)
                || "\(item.pid)".contains(q) {
                return true
            }
            if let match = PortDirectoryMatcher.match(item: item, devDirectories: devDirs),
               match.projectLabel.localizedCaseInsensitiveContains(q)
                || match.matchedDirectory.localizedCaseInsensitiveContains(q) {
                return true
            }
            return false
        }
    }

    var filteredPartition: PortPartition {
        let currentPorts = ports
        let q = portQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirPaths = effectiveDevDirectoryPaths
        if q.isEmpty {
            return allPartition
        }
        if let key = cachedFilteredPartitionKey,
           let val = cachedFilteredPartitionValue,
           key.ports == currentPorts && key.query == q && key.dirPaths == dirPaths {
            return val
        }
        let computed = PortDirectoryMatcher.partition(filteredPorts, devDirectories: dirPaths)
        cachedFilteredPartitionKey = (currentPorts, q, dirPaths)
        cachedFilteredPartitionValue = computed
        return computed
    }

    func refreshPorts() async {
        guard !isScanningPorts else { return }
        isScanningPorts = true
        defer { isScanningPorts = false }
        ports = await PortScanner.scanListeningPorts()
    }

    func addDevDirectory(_ rawPath: String) {
        portErrorMessage = nil
        portStatusMessage = nil

        let normalized = PortDirectoryMatcher.normalizePath(rawPath, resolveSymlinks: true)
        var isDir: ObjCBool = false
        guard PortDirectoryMatcher.isUsableRootDirectory(normalized) else {
            portErrorMessage = "不能选择根目录或用户主目录作为开发目录，请选择具体的代码项目目录。"
            return
        }
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDir), isDir.boolValue else {
            portErrorMessage = "所选路径不存在或不是文件夹：\(rawPath)"
            return
        }
        if effectiveDevDirectoryPaths.contains(normalized) {
            portStatusMessage = "目录「\((normalized as NSString).lastPathComponent)」已在开发目录监控范围内"
            return
        }

        var list = customDevDirectories
        list.append(normalized)
        customDevDirectories = list
        portStatusMessage = "已添加开发目录：\((normalized as NSString).lastPathComponent)"
    }

    func removeDevDirectory(_ path: String) {
        portErrorMessage = nil
        portStatusMessage = nil
        let target = PortDirectoryMatcher.normalizePath(path, resolveSymlinks: true)
        let targetRaw = PortDirectoryMatcher.normalizePath(path, resolveSymlinks: false)
        customDevDirectories = customDevDirectories.filter { entry in
            let norm = PortDirectoryMatcher.normalizePath(entry, resolveSymlinks: true)
            let rawNorm = PortDirectoryMatcher.normalizePath(entry, resolveSymlinks: false)
            return norm != target && rawNorm != targetRaw && entry != path
        }
        portStatusMessage = "已移除自定义开发目录：\((target as NSString).lastPathComponent)"
    }

    func revealDirectory(_ path: String) {
        let normalized = PortDirectoryMatcher.normalizePath(path, resolveSymlinks: true)
        guard !normalized.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: normalized, isDirectory: true)])
    }

    func openRepoRootSettings() {
        context.openSettings(ZentaoLogPlugin.settingsReposID)
    }

    func killPort(_ item: ListeningPortItem, force: Bool) async {
        portErrorMessage = nil
        portStatusMessage = nil
        switch PortScanner.terminateProcess(pid: item.pid, force: force) {
        case .success:
            portStatusMessage = "已向 \(item.processName)（PID \(item.pid) · 端口 \(item.port)）发送\(force ? "强制终止" : "优雅退出")信号"
            try? await Task.sleep(for: .milliseconds(400))
            await refreshPorts()
        case .failure(let err):
            portErrorMessage = err.localizedDescription
        }
    }
}

/// 研发工具箱插件：本地端口管家与常用离线编解码工具。
public final class DevToolsPlugin: IronBowlPlugin {
    public static let pluginID = "devtools"
    public static let settingsID = "devtools.settings"

    public let id = DevToolsPlugin.pluginID
    public let title = "研发工具"
    public let sidebarSection: String? = "研发"
    public let systemImage = "wrench.and.screwdriver"

    var model: DevToolsModel?

    public init() {}

    public func start(context: PluginContext) {
        let m = DevToolsModel(context: context)
        self.model = m
        Task { await m.refreshPorts() }
    }

    public func stop() {
        model = nil
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(DevToolsMainView(model: model))
    }

    public var settingsPages: [SettingsPage] {
        guard let model else { return [] }
        return [
            SettingsPage(id: Self.settingsID, title: "研发工具", systemImage: systemImage) {
                AnyView(DevToolsSettingsView(model: model))
            },
        ]
    }

    public var menuBarItems: [MenuBarItem] {
        guard let model else { return [] }
        return [
            MenuBarItem(id: "devtools.ports", title: "关注端口活跃数") {
                let count = model.activeWatchedCount
                return count > 0 ? "端口 \(count)" : nil
            },
        ]
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "devtools.ports", title: "查看本地端口", systemImage: "network") {
                model.context.openPlugin(Self.pluginID)
                Task { await model.refreshPorts() }
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(
                id: "devtools.ports",
                label: "监听端口",
                value: { "\(model.ports.count) 个" },
                detail: {
                    let devCount = model.allPartition.devDirectoryItems.count
                    let watched = model.activeWatchedCount
                    if devCount > 0 && watched > 0 {
                        return "开发目录 \(devCount) 个 · 常用端口 \(watched) 个"
                    }
                    if devCount > 0 {
                        return "我的开发目录 \(devCount) 个监听中"
                    }
                    return watched > 0 ? "含常用开发端口 \(watched) 个" : "本地 TCP 监听 & 离线工具"
                },
                action: {
                    model.context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}
