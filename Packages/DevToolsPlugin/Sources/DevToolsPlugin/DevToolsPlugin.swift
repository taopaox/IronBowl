import Foundation
import IronBowlKit
import Observation
import SwiftUI

@Observable
final class DevToolsModel {
    let context: PluginContext
    var ports: [ListeningPortItem] = []
    var isScanningPorts = false
    var portQuery = ""
    var portStatusMessage: String?
    var portErrorMessage: String?

    init(context: PluginContext) {
        self.context = context
    }

    var watchedPorts: [Int] {
        get { context.settings[DevToolsKeys.watchedPorts] }
        set { context.settings[DevToolsKeys.watchedPorts] = newValue }
    }

    var activeWatchedCount: Int {
        let watched = Set(watchedPorts)
        return Set(ports.map(\.port)).intersection(watched).count
    }

    var filteredPorts: [ListeningPortItem] {
        let q = portQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ports }
        return ports.filter {
            "\($0.port)".contains(q)
                || $0.processName.localizedCaseInsensitiveContains(q)
                || $0.commandLine.localizedCaseInsensitiveContains(q)
                || "\($0.pid)".contains(q)
        }
    }

    func refreshPorts() async {
        guard !isScanningPorts else { return }
        isScanningPorts = true
        defer { isScanningPorts = false }
        ports = await PortScanner.scanListeningPorts()
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
                    let watched = model.activeWatchedCount
                    return watched > 0 ? "含常用开发端口 \(watched) 个" : "本地 TCP 监听 & 离线工具"
                },
                action: {
                    model.context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}
