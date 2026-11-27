import Foundation
import IronBowlKit
import SwiftUI

/// 本地代码仓库工作台插件：集中展示分支、未提交/未推送状态、最近提交，支持一键打开编辑器/终端/AI 对话。
public final class WorkspacePlugin: IronBowlPlugin {
    public static let pluginID = "workspace"
    public static let settingsID = "workspace.settings"

    public let id = WorkspacePlugin.pluginID
    public let title = "代码仓库"
    public let sidebarSection: String? = "研发"
    public let systemImage = "folder.badge.gearshape"

    public var sidebarBadge: SidebarBadge? {
        guard let model, model.attentionCount > 0 else { return nil }
        return SidebarBadge("待推 \(model.attentionCount)", color: DS.warning)
    }

    var model: WorkspaceModel?

    public init() {}

    public func start(context: PluginContext) {
        let m = WorkspaceModel(context: context)
        self.model = m
        Task { await m.refresh() }
    }

    public func stop() {
        model = nil
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(WorkspaceMainView(model: model))
    }

    public var settingsPages: [SettingsPage] {
        guard let model else { return [] }
        return [
            SettingsPage(id: Self.settingsID, title: "代码仓库", systemImage: "folder.badge.gearshape") {
                AnyView(WorkspaceSettingsView(model: model))
            },
        ]
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "workspace.open", title: "巡检代码仓库", systemImage: "folder.badge.gearshape") {
                model.context.openPlugin(Self.pluginID)
                Task { await model.refresh() }
            },
        ]
    }

    public var paletteCommands: [PaletteCommand] {
        guard let model else { return [] }
        return model.repos.flatMap { repo in
            [
                PaletteCommand(
                    id: "workspace.editor.\(repo.path)",
                    title: "在编辑器打开 \(repo.name)",
                    subtitle: [repo.mappedProjectName, repo.branch, repo.path].compactMap { $0 }.joined(separator: " · "),
                    keywords: ["repo", "git", "code", "编辑器", repo.name, repo.branch, repo.mappedProjectName ?? ""],
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    badge: "代码仓库"
                ) {
                    model.openInEditor(repo.path)
                },
                PaletteCommand(
                    id: "workspace.chat.\(repo.path)",
                    title: "在 \(repo.name) 发起 AI 对话",
                    subtitle: repo.path,
                    keywords: ["chat", "ai", "对话", repo.name, repo.mappedProjectName ?? ""],
                    systemImage: "sparkles",
                    badge: "工作区对话"
                ) {
                    model.openChat(in: repo.path)
                },
            ]
        }
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(
                id: "workspace.repos",
                label: "代码仓库",
                value: {
                    if model.repos.isEmpty { return "待扫描" }
                    return model.attentionCount > 0 ? "\(model.attentionCount) 库待处理" : "全部干净"
                },
                detail: {
                    "共 \(model.repos.count) 个仓库 · 今日活跃 \(model.todayActiveCount) 个"
                },
                action: {
                    model.context.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}
