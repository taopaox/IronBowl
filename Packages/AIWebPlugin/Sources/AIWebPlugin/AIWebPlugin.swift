import AppKit
import IronBowlKit
import SwiftUI

/// AI 网页目录插件：仿 Cherry Studio 左侧 AI 菜单，内置主流 AI 预设与官方 Logo，支持自定义增删改查与墓碑休眠。
public final class AIWebPlugin: IronBowlPlugin {
    public static let pluginID = "aiweb"
    public let id = AIWebPlugin.pluginID
    public let title = "AI"
    public let systemImage = "sparkles"
    public let isSidebarDirectory = true

    public private(set) var model: AIWebModel?

    public init() {}

    public func start(context: PluginContext) {
        model = AIWebModel(context: context)
    }

    public func stop() {
        model?.stop()
        model = nil
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(AIWebMainView(model: model))
    }

    public func onSidebarSelect() {
        model?.selectDirectory()
    }

    public func closeWebSession(id: String) -> Bool {
        let prefix = "aiweb."
        guard id.hasPrefix(prefix) else { return false }
        let appID = String(id.dropFirst(prefix.count))
        model?.closeApp(id: appID)
        return true
    }

    public var settingsPages: [SettingsPage] {
        guard let model else { return [] }
        return [
            SettingsPage(id: "aiweb.manage", title: "AI 目录管理", systemImage: "sparkles") {
                AnyView(AIWebSettingsView(model: model))
            },
        ]
    }

    public var sidebarChildren: [SidebarPinnedItem] {
        guard let model else { return [] }
        let pinned = model.pinnedApps
        return pinned.enumerated().map { index, app in
            let resolvedLogo = model.logoStore.image(for: app.logo)
            return SidebarPinnedItem(
                id: app.id,
                pluginID: Self.pluginID,
                title: app.name,
                subtitle: app.url,
                systemImage: app.logo.defaultSymbolFallback,
                iconImage: resolvedLogo?.image,
                iconIsTemplate: resolvedLogo?.isTemplate ?? false,
                isSelected: model.activeAppID == app.id,
                isOpen: model.hasOpenSession(appID: app.id),
                isSuspended: model.isSuspended(appID: app.id),
                isNeverSuspend: app.neverSuspend,
                canMoveUp: index > 0,
                canMoveDown: index < pinned.count - 1,
                action: {
                    model.selectApp(app.id)
                    model.openPlugin(Self.pluginID)
                },
                onClose: {
                    model.closeApp(id: app.id)
                },
                onRename: { newName in
                    model.renameApp(id: app.id, name: newName)
                },
                onEdit: {
                    model.openPlugin(Self.pluginID)
                    model.beginEditing(appID: app.id)
                },
                onMoveUp: {
                    model.movePinnedApp(id: app.id, delta: -1)
                },
                onMoveDown: {
                    model.movePinnedApp(id: app.id, delta: 1)
                },
                onToggleNeverSuspend: {
                    model.setNeverSuspend(!app.neverSuspend, id: app.id)
                },
                onSuspendNow: {
                    Task { await model.suspendApp(id: app.id) }
                },
                onUnpin: {
                    model.setPinned(false, id: app.id)
                },
                onDelete: {
                    model.deleteApp(id: app.id)
                },
                onOpenInBrowser: {
                    if let url = WebURL.normalize(app.url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "aiweb.open", title: "AI 目录", systemImage: "sparkles") {
                model.selectDirectory()
                model.openPlugin(Self.pluginID)
            },
        ]
    }

    public var paletteCommands: [PaletteCommand] {
        guard let model else { return [] }
        return model.apps.map { app in
            PaletteCommand(
                id: "aiweb.app.\(app.id)",
                title: "打开 \(app.name)",
                subtitle: app.url,
                keywords: ["ai", app.name, app.url],
                systemImage: app.logo.defaultSymbolFallback,
                badge: "AI 网页"
            ) {
                model.selectApp(app.id)
                model.openPlugin(Self.pluginID)
            }
        }
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(
                id: "aiweb.card",
                label: "AI 目录",
                value: {
                    let count = model.pinnedApps.count
                    return count > 0 ? "\(count) 个已固定" : "\(model.apps.count) 个 AI"
                },
                detail: {
                    let names = model.pinnedApps.prefix(3).map(\.name)
                    return names.isEmpty ? "点击打开 AI 目录" : names.joined(separator: " · ")
                },
                action: {
                    model.selectDirectory()
                    model.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}
