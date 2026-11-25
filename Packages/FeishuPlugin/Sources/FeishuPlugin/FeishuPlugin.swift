import AppKit
import IronBowlKit
import SwiftUI

/// 飞书知识库插件：内嵌 WKWebView 浏览飞书，支持把常用网页固定到工作台左侧栏与自动墓碑休眠。
public final class FeishuPlugin: IronBowlPlugin {
    public static let pluginID = "feishu"
    public let id = FeishuPlugin.pluginID
    public let title = "飞书知识库"
    public let systemImage = "book.pages"

    public private(set) var model: FeishuModel?

    public init() {}

    public func start(context: PluginContext) {
        model = FeishuModel(context: context)
    }

    public func stop() {
        model?.stop()
        model = nil
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(FeishuMainView(model: model))
    }

    public func onSidebarSelect() {
        model?.selectHome()
    }

    public var settingsPages: [SettingsPage] {
        guard let model else { return [] }
        return [
            SettingsPage(id: "feishu.general", title: "飞书与固定网页", systemImage: "book.pages") {
                AnyView(FeishuSettingsView(model: model))
            },
        ]
    }

    public var sidebarPinnedItems: [SidebarPinnedItem] {
        guard let model else { return [] }
        let pages = model.pinnedPages
        return pages.enumerated().map { index, page in
            SidebarPinnedItem(
                id: page.id,
                pluginID: Self.pluginID,
                title: page.title,
                subtitle: page.url,
                systemImage: page.systemImage,
                isSelected: model.activePageID == page.id,
                isSuspended: model.isSuspended(pageID: page.id),
                isNeverSuspend: page.neverSuspend,
                canMoveUp: index > 0,
                canMoveDown: index < pages.count - 1,
                action: {
                    model.selectPage(page.id)
                    model.openPlugin(Self.pluginID)
                },
                onRename: { newTitle in
                    model.renamePin(id: page.id, title: newTitle)
                },
                onMoveUp: {
                    model.movePin(id: page.id, delta: -1)
                },
                onMoveDown: {
                    model.movePin(id: page.id, delta: 1)
                },
                onToggleNeverSuspend: {
                    model.setNeverSuspend(!page.neverSuspend, id: page.id)
                },
                onSuspendNow: {
                    Task { await model.suspendPage(id: page.id) }
                },
                onUnpin: {
                    model.unpin(id: page.id)
                },
                onOpenInBrowser: {
                    if let url = FeishuURL.normalize(page.url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        }
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "feishu.open", title: "飞书知识库", systemImage: "book.pages") {
                model.selectHome()
                model.openPlugin(Self.pluginID)
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(
                id: "feishu.card",
                label: "飞书知识库",
                value: {
                    let count = model.pinnedPages.count
                    return count > 0 ? "\(count) 个固定页" : "已就绪"
                },
                detail: { model.pinnedPages.first?.title ?? "my.feishu.cn" },
                action: {
                    model.selectHome()
                    model.openPlugin(Self.pluginID)
                }
            ),
        ]
    }
}
