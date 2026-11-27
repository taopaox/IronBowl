import AIWebPlugin
import AppKit
import FeishuPlugin
import IronBowlKit
import Observation
import SwiftUI

/// 主窗口：左边浅灰侧栏，右边白色内容区（WorkBuddy 风格）。
struct MainView: View {
    static let sidebarAnimation: Animation = .spring(duration: 0.26, bounce: 0)

    @Bindable var app: AppModel
    @AppStorage("sidebarCollapsed") private var storedCollapsed = false
    @State private var collapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")

    private func setSidebarCollapsed(_ next: Bool) {
        guard collapsed != next else { return }
        withAnimation(Self.sidebarAnimation) {
            collapsed = next
        }
        storedCollapsed = next
    }

    var body: some View {
        let sidebarWidth = DS.s(216)
        let totalSidebarWidth = sidebarWidth + 1

        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Sidebar(app: app, isVisible: !collapsed && app.isMainWindowOpen)
                        .frame(width: sidebarWidth)
                    Rectangle().fill(DS.border).frame(width: 1)
                }
                .frame(width: totalSidebarWidth)
                .frame(width: collapsed ? 0 : totalSidebarWidth, alignment: .trailing)
                .clipped()
                .allowsHitTesting(!collapsed)
                .accessibilityHidden(collapsed)

                detail
                    .environment(\.sidebarCollapsed, collapsed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.canvas)
            }

            Button {
                setSidebarCollapsed(!collapsed)
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.dsGhost)
            .help(collapsed ? "展开侧边栏" : "收起侧边栏")
            .padding(.leading, collapsed ? 82 : sidebarWidth - DS.s(32) - 10)
            .padding(.top, collapsed ? 10 : 6)
        }
        .animation(Self.sidebarAnimation, value: collapsed)
        .onChange(of: storedCollapsed) { _, newValue in
            guard collapsed != newValue else { return }
            withAnimation(Self.sidebarAnimation) {
                collapsed = newValue
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 600)
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
    }

    @ViewBuilder
    private var detail: some View {
        let enabledIDs = app.enabledIDs
        let selectedWebPlugin: IronBowlPlugin? = {
            guard let selection = app.selection,
                  selection == FeishuPlugin.pluginID || selection == AIWebPlugin.pluginID,
                  let plugin = app.plugin(selection),
                  enabledIDs.contains(plugin.id) else {
                return nil
            }
            return plugin
        }()

        let activeNativeID: String? = {
            guard selectedWebPlugin == nil else { return nil }
            if app.selection == AppModel.remindersID {
                return AppModel.remindersID
            }
            if let plugin = app.plugin(app.selection), enabledIDs.contains(plugin.id) {
                return plugin.id
            }
            return AppModel.homeID
        }()

        let validNativeIDs: Set<String> = {
            var set: Set<String> = [AppModel.homeID, AppModel.remindersID]
            for p in app.enabledPlugins where p.id != FeishuPlugin.pluginID && p.id != AIWebPlugin.pluginID {
                set.insert(p.id)
            }
            return set
        }()

        ZStack {
            NativePageDeck(
                app: app,
                activePageID: activeNativeID,
                validPageIDs: validNativeIDs,
                sidebarCollapsed: collapsed,
                trimToken: app.pageDeckTrimToken
            )
            .id(app.pageDeckResetToken)
            .allowsHitTesting(selectedWebPlugin == nil)
            .accessibilityHidden(selectedWebPlugin != nil)

            if app.isMainWindowOpen, let selectedWebPlugin {
                selectedWebPlugin.makeMainView()
                    .id(selectedWebPlugin.id)
            }
        }
    }
}

@Observable
private final class PageDeckEnvironment {
    var activePageID: String?
    var sidebarCollapsed = false
}

private struct PageDeckWrapperView: View {
    let pageID: String
    let deckEnv: PageDeckEnvironment
    let content: AnyView

    var body: some View {
        content
            .environment(\.sidebarCollapsed, deckEnv.sidebarCollapsed)
            .environment(\.isPageActive, deckEnv.activePageID == pageID)
            .environment(\.locale, CN.locale)
    }
}

/// 原生页面 AppKit 保活容器：按 pageID 缓存 NSHostingView（sizingOptions = []），切页仅切换 isHidden，兼顾瞬时切换与滚动/编辑器状态保留。
private struct NativePageDeck: NSViewRepresentable {
    let app: AppModel
    let activePageID: String?
    let validPageIDs: Set<String>
    let sidebarCollapsed: Bool
    let trimToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PageDeckContainerView {
        let view = PageDeckContainerView()
        updateView(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: PageDeckContainerView, context: Context) {
        updateView(nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: PageDeckContainerView, coordinator: Coordinator) {
        nsView.clearAll()
    }

    private func updateView(_ container: PageDeckContainerView, coordinator: Coordinator) {
        coordinator.environment.sidebarCollapsed = sidebarCollapsed
        coordinator.environment.activePageID = activePageID
        if coordinator.lastTrimToken != trimToken {
            coordinator.lastTrimToken = trimToken
            container.trimInactivePages(keepActiveID: activePageID)
        }
        container.syncPages(
            activePageID: activePageID,
            validPageIDs: validPageIDs,
            deckEnv: coordinator.environment
        ) { pageID in
            makePageContent(for: pageID)
        }
    }

    private func makePageContent(for pageID: String) -> AnyView {
        if pageID == AppModel.homeID {
            return AnyView(HomeView(app: app))
        }
        if pageID == AppModel.remindersID {
            return AnyView(RemindersView(app: app))
        }
        if let plugin = app.plugin(pageID) {
            return plugin.makeMainView()
        }
        return AnyView(HomeView(app: app))
    }

    final class Coordinator {
        let environment = PageDeckEnvironment()
        var lastTrimToken = 0
    }
}

private final class PageDeckContainerView: NSView {
    private static let maxCachedPages = 8

    private var cachedHostingViews: [String: NSHostingView<PageDeckWrapperView>] = [:]
    private var lruOrder: [String] = []
    private var currentActiveID: String?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for host in cachedHostingViews.values where !host.isHidden {
            if host.frame != bounds {
                host.frame = bounds
            }
        }
    }

    func syncPages(
        activePageID: String?,
        validPageIDs: Set<String>,
        deckEnv: PageDeckEnvironment,
        makeContent: (String) -> AnyView
    ) {
        // 移除已被停用或无效的插件页缓存
        let obsoleteIDs = cachedHostingViews.keys.filter { !validPageIDs.contains($0) }
        for id in obsoleteIDs {
            evictPage(id: id)
        }

        if let activePageID, cachedHostingViews[activePageID] == nil {
            let wrapper = PageDeckWrapperView(
                pageID: activePageID,
                deckEnv: deckEnv,
                content: makeContent(activePageID)
            )
            let host = NSHostingView(rootView: wrapper)
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            host.frame = bounds
            host.isHidden = true
            addSubview(host)
            cachedHostingViews[activePageID] = host
        }

        if let activePageID {
            lruOrder.removeAll { $0 == activePageID }
            lruOrder.append(activePageID)
        }

        // 先切换显隐再做淘汰，避免闪烁
        if currentActiveID != activePageID || activePageID == nil {
            for (id, host) in cachedHostingViews {
                let shouldShow = (id == activePageID)
                if shouldShow && host.frame != bounds {
                    host.frame = bounds
                }
                if host.isHidden == shouldShow {
                    host.isHidden = !shouldShow
                }
            }
            currentActiveID = activePageID
        } else if let activePageID, let activeHost = cachedHostingViews[activePageID], activeHost.frame != bounds {
            activeHost.frame = bounds
        }

        isHidden = (activePageID == nil)

        while cachedHostingViews.count > Self.maxCachedPages {
            guard let victim = lruOrder.first(where: { $0 != activePageID && $0 != AppModel.homeID })
                    ?? lruOrder.first(where: { $0 != activePageID }) else {
                break
            }
            evictPage(id: victim)
        }
    }

    func trimInactivePages(keepActiveID: String?) {
        let toRemove = cachedHostingViews.keys.filter { $0 != AppModel.homeID && $0 != keepActiveID }
        for id in toRemove {
            evictPage(id: id)
        }
    }

    func clearAll() {
        for host in cachedHostingViews.values {
            host.removeFromSuperview()
        }
        cachedHostingViews.removeAll()
        lruOrder.removeAll()
        currentActiveID = nil
    }

    private func evictPage(id: String) {
        if let host = cachedHostingViews.removeValue(forKey: id) {
            host.removeFromSuperview()
        }
        lruOrder.removeAll { $0 == id }
    }
}

struct Sidebar: View {
    let app: AppModel
    let isVisible: Bool
    @AppStorage("sidebarCollapsedDirs") private var collapsedDirsRaw = ""
    @State private var renamingItem: SidebarPinnedItem?
    @State private var renameText = ""
    @State private var editingProfile = false
    @State private var hoveringProfile = false

    private var collapsedDirs: Set<String> {
        Set(collapsedDirsRaw.split(separator: ",").map(String.init))
    }

    private func isDirCollapsed(_ id: String) -> Bool {
        collapsedDirs.contains(id)
    }

    private func toggleDir(_ id: String) {
        var set = collapsedDirs
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedDirsRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：给红绿灯与展开/收起按钮留位置
            Color.clear
                .frame(height: 40)
                .windowTitleBar()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(AppBrand.name).font(DS.font(17, .semibold))
                    Text(Bundle.main.displayVersion)
                        .font(DS.font(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(DS.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DS.well, in: .capsule)
                        .help("当前版本 \(Bundle.main.fullVersion)")
                }

                DSSloganView(style: .sidebar)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Button {
                app.commandPalette.show()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.font(12))
                        .foregroundStyle(DS.textTertiary)
                    Text("搜索或命令…")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: 0)
                    Text("⌘K")
                        .font(DS.font(10.5, .medium))
                        .foregroundStyle(DS.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(DS.card, in: .rect(cornerRadius: 4))
                }
                .padding(.horizontal, 9)
                .frame(height: DS.s(28))
                .background(DS.selected, in: .rect(cornerRadius: DS.controlRadius))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("打开全局命令面板与全文搜索 (⌘K / ⌃⌥⌘K)")
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let partitioned = SidebarPluginGrouping.partition(app.enabledPlugins)
                    let unreadCount = app.reminders.unreadCount

                    DSSidebarItem("今天", systemImage: "house", selected: app.selection == AppModel.homeID) {
                        app.select(AppModel.homeID)
                    }
                    DSSidebarItem(
                        "消息提醒",
                        systemImage: unreadCount > 0 ? "bell.badge" : "bell",
                        selected: app.selection == AppModel.remindersID,
                        badge: unreadCount > 0 ? (unreadCount > 99 ? "99+" : "\(unreadCount)") : nil,
                        badgeColor: unreadCount > 0 ? DS.danger : nil
                    ) {
                        app.select(AppModel.remindersID)
                    }
                    ForEach(partitioned.ungrouped, id: \.id) { plugin in
                        pluginRow(plugin)
                    }

                    ForEach(partitioned.sections) { section in
                        DSSidebarSection(section.title)
                        ForEach(section.plugins, id: \.id) { plugin in
                            pluginRow(plugin)
                        }
                    }

                    let pinned = app.enabledPlugins.flatMap(\.sidebarPinnedItems)
                    if !pinned.isEmpty {
                        DSSidebarSection("固定网页")
                        ForEach(pinned) { item in
                            PinnedSidebarRow(
                                item: item,
                                selected: app.selection == item.pluginID && item.isSelected,
                                onStartRename: {
                                    renameText = item.title
                                    renamingItem = item
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            ResourceCard(app: app, isVisible: isVisible).padding(.horizontal, 10).padding(.bottom, 8)
            TodayCard(app: app).padding(.horizontal, 10).padding(.bottom, 8)

            let slogan = app.userProfile.effectiveSlogan
            let hasSlogan = slogan != nil
            HStack(spacing: 4) {
                Button {
                    editingProfile = true
                } label: {
                    HStack(spacing: 8) {
                        UserProfileAvatarView(
                            image: app.userProfile.avatarImage,
                            size: hasSlogan ? DS.s(28) : DS.s(22)
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.userProfile.effectiveDisplayName)
                                .font(DS.font(13.5, .medium))
                                .foregroundStyle(DS.text)
                                .lineLimit(1)
                            if let slogan {
                                Text(slogan)
                                    .font(DS.font(11))
                                    .foregroundStyle(DS.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(hoveringProfile ? DS.hover : .clear, in: .rect(cornerRadius: DS.controlRadius))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hoveringProfile = $0 }
                .help(profileHelpText(name: app.userProfile.effectiveDisplayName, slogan: slogan))

                Button { app.openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.dsGhost)
                    .help("设置")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, hasSlogan ? 6 : 4)
            .frame(minHeight: hasSlogan ? DS.s(52) : DS.s(44))
            .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
        }
        .background(DS.sidebar)
        .sheet(isPresented: $editingProfile) {
            UserProfileEditorSheet(profile: app.userProfile) {
                editingProfile = false
            }
        }
        .sheet(item: $renamingItem) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("重命名固定网页").font(DS.sectionTitle)
                TextField("名称", text: $renameText)
                    .textFieldStyle(.ds)
                    .onSubmit {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { item.onRename?(trimmed) }
                        renamingItem = nil
                    }
                HStack {
                    Spacer()
                    Button("取消") { renamingItem = nil }.buttonStyle(.dsSecondary)
                    Button("保存") {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { item.onRename?(trimmed) }
                        renamingItem = nil
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(18)
            .frame(width: DS.s(320))
            .background(DS.card)
        }
    }

    private func profileHelpText(name: String, slogan: String?) -> String {
        if let slogan {
            return "\(name)\n\(slogan)\n点击编辑个人资料"
        }
        return "\(name)\n点击编辑个人资料"
    }

    @ViewBuilder
    private func pluginRow(_ plugin: IronBowlPlugin) -> some View {
        let children = plugin.sidebarChildren
        let hasSelectedChild = app.selection == plugin.id && (
            plugin.sidebarPinnedItems.contains(where: \.isSelected) ||
            children.contains(where: \.isSelected)
        )
        if plugin.isSidebarDirectory {
            SidebarDirectoryHeader(
                title: plugin.sidebarTitle,
                systemImage: plugin.systemImage,
                selected: app.selection == plugin.id && !hasSelectedChild,
                isCollapsed: isDirCollapsed(plugin.id),
                hasChildren: !children.isEmpty,
                onSelect: {
                    plugin.onSidebarSelect()
                    app.select(plugin.id)
                },
                onToggleCollapse: {
                    withAnimation(.snappy(duration: 0.18)) {
                        toggleDir(plugin.id)
                    }
                }
            )
            if !isDirCollapsed(plugin.id), !children.isEmpty {
                ForEach(children) { item in
                    PinnedSidebarRow(
                        item: item,
                        selected: app.selection == item.pluginID && item.isSelected,
                        indent: 14,
                        onStartRename: {
                            renameText = item.title
                            renamingItem = item
                        }
                    )
                }
            }
        } else if plugin.isSidebarWebOpen {
            SidebarWebPluginRow(
                plugin: plugin,
                selected: app.selection == plugin.id && !hasSelectedChild,
                onSelect: {
                    plugin.onSidebarSelect()
                    app.select(plugin.id)
                }
            )
        } else {
            let badge = plugin.sidebarBadge
            DSSidebarItem(
                plugin.sidebarTitle,
                systemImage: plugin.systemImage,
                selected: app.selection == plugin.id && !hasSelectedChild,
                badge: plugin.isComingSoon ? "即将推出" : badge?.text,
                badgeColor: plugin.isComingSoon ? nil : badge?.color
            ) {
                plugin.onSidebarSelect()
                app.select(plugin.id)
            }
        }
    }
}

private struct SidebarWebPluginRow: View {
    let plugin: IronBowlPlugin
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        let badge = plugin.sidebarBadge
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Image(systemName: plugin.systemImage)
                        .font(DS.font(15))
                        .frame(width: DS.s(18))
                    Text(plugin.sidebarTitle)
                        .font(DS.font(14.5))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge.text)
                            .font(DS.font(10.5, .semibold))
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge.color.opacity(0.14), in: .capsule)
                            .overlay { Capsule().strokeBorder(badge.color.opacity(0.32)) }
                    }
                }
                .foregroundStyle(DS.text)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if hovering {
                HStack(spacing: 2) {
                    Menu {
                        menuContent()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(DS.font(12))
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: DS.s(22), height: DS.s(22))
                            .contentShape(.rect)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    Button {
                        plugin.onSidebarCloseWeb()
                    } label: {
                        Image(systemName: "xmark")
                            .font(DS.font(11, .medium))
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: DS.s(20), height: DS.s(20))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("关闭网页")
                }
            } else if badge == nil {
                if plugin.isSidebarWebSuspended {
                    Image(systemName: "moon.zzz")
                        .font(DS.font(11))
                        .foregroundStyle(DS.textTertiary)
                        .padding(.trailing, 3)
                } else {
                    Circle()
                        .fill(DS.success)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 5)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DS.s(30))
        .background(selected ? DS.selected : hovering ? DS.hover : .clear, in: .rect(cornerRadius: DS.controlRadius))
        .contentShape(.rect)
        .help(plugin.isSidebarWebSuspended ? "\(plugin.sidebarTitle)（已休眠省内存，点击唤醒）" : plugin.sidebarTitle)
        .onHover { hovering = $0 }
        .contextMenu { menuContent() }
    }

    @ViewBuilder
    private func menuContent() -> some View {
        Button("打开\(plugin.sidebarTitle)", action: onSelect)
        Divider()
        Button("立即休眠") {
            plugin.onSidebarSuspendWeb()
        }
        .disabled(plugin.isSidebarWebSuspended || !plugin.isSidebarWebOpen)
        Button(plugin.isSidebarWebNeverSuspend ? "取消免休眠" : "设为免休眠") {
            plugin.onSidebarToggleNeverSuspend()
        }
        Button("关闭网页") {
            plugin.onSidebarCloseWeb()
        }
    }
}

private struct SidebarDirectoryHeader: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let isCollapsed: Bool
    let hasChildren: Bool
    let onSelect: () -> Void
    let onToggleCollapse: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                        .font(DS.font(15))
                        .frame(width: DS.s(18))
                    Text(title)
                        .font(DS.font(14.5))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.text)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if hasChildren {
                Button(action: onToggleCollapse) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(DS.font(11, .semibold))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: DS.s(20), height: DS.s(20))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "展开 \(title) 目录" : "收起 \(title) 目录")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DS.s(30))
        .background(selected ? DS.selected : hovering ? DS.hover : .clear, in: .rect(cornerRadius: DS.controlRadius))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

private struct PinnedSidebarRow: View {
    let item: SidebarPinnedItem
    let selected: Bool
    var indent: CGFloat = 0
    let onStartRename: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: item.action) {
                HStack(spacing: 9) {
                    if let iconImage = item.iconImage {
                        Group {
                            if item.iconIsTemplate {
                                Image(nsImage: iconImage)
                                    .resizable()
                                    .renderingMode(.template)
                                    .scaledToFit()
                                    .foregroundStyle(item.isSuspended ? DS.textSecondary : DS.text)
                            } else {
                                Image(nsImage: iconImage)
                                    .resizable()
                                    .scaledToFit()
                                    .opacity(item.isSuspended ? 0.7 : 1)
                            }
                        }
                        .frame(width: DS.s(16), height: DS.s(16))
                        .clipShape(.rect(cornerRadius: 4))
                        .frame(width: DS.s(18))
                    } else {
                        Image(systemName: item.systemImage)
                            .font(DS.font(14))
                            .frame(width: DS.s(18))
                    }
                    Text(item.title)
                        .font(DS.font(14))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(item.isSuspended ? DS.textSecondary : DS.text)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if hovering {
                HStack(spacing: 2) {
                    Menu {
                        menuContent()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(DS.font(12))
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: DS.s(22), height: DS.s(22))
                            .contentShape(.rect)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    if item.isOpen, let onClose = item.onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(DS.font(11, .medium))
                                .foregroundStyle(DS.textSecondary)
                                .frame(width: DS.s(20), height: DS.s(20))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("关闭网页")
                    }
                }
            } else if item.isSuspended {
                Image(systemName: "moon.zzz")
                    .font(DS.font(11))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.trailing, 3)
            } else if item.isOpen {
                Circle()
                    .fill(DS.success)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 5)
            }
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 10)
        .frame(height: DS.s(28))
        .background(selected ? DS.selected : hovering ? DS.hover : .clear, in: .rect(cornerRadius: DS.controlRadius))
        .contentShape(.rect)
        .help(item.isSuspended ? "\(item.subtitle ?? item.title)（已休眠省内存，点击唤醒）" : (item.subtitle ?? item.title))
        .onHover { hovering = $0 }
        .contextMenu { menuContent() }
    }

    @ViewBuilder
    private func menuContent() -> some View {
        if let onEdit = item.onEdit {
            Button("编辑…") { onEdit() }
        }
        if item.onRename != nil {
            Button("重命名…") { onStartRename() }
        }
        if let onMoveUp = item.onMoveUp {
            Button("上移") { onMoveUp() }.disabled(!item.canMoveUp)
        }
        if let onMoveDown = item.onMoveDown {
            Button("下移") { onMoveDown() }.disabled(!item.canMoveDown)
        }
        if item.onSuspendNow != nil || item.onToggleNeverSuspend != nil || (item.isOpen && item.onClose != nil) {
            Divider()
        }
        if let onSuspendNow = item.onSuspendNow {
            Button("立即休眠") { onSuspendNow() }.disabled(item.isSuspended || !item.isOpen)
        }
        if let onToggleNeverSuspend = item.onToggleNeverSuspend {
            Button(item.isNeverSuspend ? "取消免休眠" : "设为免休眠") { onToggleNeverSuspend() }
        }
        if item.isOpen, let onClose = item.onClose {
            Button("关闭网页") { onClose() }
        }
        if let onOpenInBrowser = item.onOpenInBrowser {
            Divider()
            Button("在浏览器中打开") { onOpenInBrowser() }
        }
        if item.onUnpin != nil || item.onDelete != nil {
            Divider()
        }
        if let onUnpin = item.onUnpin {
            Button("取消固定", role: .destructive) { onUnpin() }
        }
        if let onDelete = item.onDelete {
            Button("删除", role: .destructive) { onDelete() }
        }
    }
}

/// 侧栏底部的小卡：实时 CPU 与内存占用（支持系统 / 饭碗切换及明细查看）。
private struct ResourceCard: View {
    let app: AppModel
    let isVisible: Bool
    @AppStorage("sidebarResourceScope") private var scopeRaw = ResourceScope.system.rawValue
    @State private var showDetail = false

    private var scope: ResourceScope {
        ResourceScope(rawValue: scopeRaw) ?? .system
    }

    var body: some View {
        let snap = app.systemMonitor.snapshot
        let cpuRatio = scope == .system ? snap.systemCPUUsage : snap.appCPUUsage
        let memoryRatio = scope == .system ? snap.systemMemoryUsage : snap.appMemoryUsage
        let memoryText = scope == .system
            ? SystemResourceFormat.memoryPair(used: snap.systemMemoryUsedBytes, total: snap.systemMemoryTotalBytes)
            : SystemResourceFormat.memory(snap.appMemoryBytes)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(scope == .system ? "系统资源" : "饭碗占用")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 0)
                HStack(spacing: 1) {
                    ForEach(ResourceScope.allCases, id: \.self) { option in
                        let selected = scope == option
                        Button {
                            scopeRaw = option.rawValue
                        } label: {
                            Text(option.title)
                                .font(DS.font(11, selected ? .medium : .regular))
                                .foregroundStyle(selected ? DS.text : DS.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(selected ? DS.selected : .clear, in: .rect(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border) }
            }

            VStack(alignment: .leading, spacing: 7) {
                ResourceMeterRow(
                    label: "CPU",
                    valueText: SystemResourceFormat.cpu(cpuRatio),
                    ratio: cpuRatio ?? 0,
                    tint: meterColor(for: cpuRatio ?? 0)
                )
                ResourceMeterRow(
                    label: "内存",
                    valueText: memoryText,
                    ratio: memoryRatio,
                    tint: meterColor(for: memoryRatio)
                )
            }

            if scope == .app, !snap.appItems.isEmpty {
                Divider().overlay(DS.border)

                Button {
                    showDetail = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(snap.appItems.prefix(3)) { item in
                            HStack(spacing: 5) {
                                Image(systemName: iconName(for: item.kind))
                                    .font(DS.font(10))
                                    .foregroundStyle(iconColor(for: item.kind))
                                    .frame(width: DS.s(12))
                                Text(item.name)
                                    .font(DS.font(11.5))
                                    .foregroundStyle(DS.text)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(SystemResourceFormat.memory(item.memoryBytes))
                                    .font(DS.font(11, .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(DS.textSecondary)
                                    .layoutPriority(1)
                                Text(SystemResourceFormat.cpu(item.cpuUsage))
                                    .font(DS.font(10.5))
                                    .monospacedDigit()
                                    .foregroundStyle(DS.textTertiary)
                                    .frame(minWidth: DS.s(30), alignment: .trailing)
                                    .layoutPriority(1)
                            }
                        }

                        HStack(spacing: 4) {
                            Text("查看明细（共 \(snap.appItems.count) 项）")
                                .font(DS.font(11))
                                .foregroundStyle(DS.textTertiary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(DS.font(9.5, .semibold))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .padding(.top, 2)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }
        .help(tooltipText(for: snap))
        .onChange(of: scopeRaw) { _, _ in
            if scope == .system {
                showDetail = false
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible {
                showDetail = false
            }
        }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            ResourceDetailPopover(app: app, isPresented: $showDetail)
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            await app.systemMonitor.run()
        }
    }

    private func iconName(for kind: AppResourceKind) -> String {
        switch kind {
        case .mainApp: "macwindow"
        case .webPage: "globe"
        case .childProcess: "terminal"
        }
    }

    private func iconColor(for kind: AppResourceKind) -> Color {
        switch kind {
        case .mainApp: DS.brand
        case .webPage: DS.toggle
        case .childProcess: DS.textTertiary
        }
    }

    private func meterColor(for ratio: Double) -> Color {
        if ratio >= 0.85 { return DS.danger }
        if ratio >= 0.70 { return DS.warning }
        return DS.toggle
    }

    private func tooltipText(for snap: SystemResourceSnapshot) -> String {
        if scope == .system {
            let memPct = SystemResourceFormat.percent(snap.systemMemoryUsage)
            return "整机 \(snap.cpuCoreCount) 核 · CPU \(SystemResourceFormat.cpu(snap.systemCPUUsage)) · 内存已用 \(SystemResourceFormat.memory(snap.systemMemoryUsedBytes)) / \(SystemResourceFormat.memory(snap.systemMemoryTotalBytes))（\(memPct)）"
        } else {
            let memPct = SystemResourceFormat.percent(snap.appMemoryUsage)
            return "饭碗共 \(snap.appProcessCount) 个进程（含活跃网页）· CPU \(SystemResourceFormat.cpu(snap.appCPUUsage)) · 物理内存 \(SystemResourceFormat.memory(snap.appMemoryBytes))（占整机 \(memPct)），点击明细可查看并休眠后台网页"
        }
    }
}

private struct ResourceDetailPopover: View {
    let app: AppModel
    @Binding var isPresented: Bool

    enum SortMode: String, CaseIterable {
        case memory
        case cpu

        var title: String {
            switch self {
            case .memory: "按内存"
            case .cpu: "按 CPU"
            }
        }
    }

    @State private var sortMode: SortMode = .memory

    var body: some View {
        let snap = app.systemMonitor.snapshot
        let items = sortedItems(snap.appItems)
        let hasSuspendable = items.contains(where: \.canSuspend)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("饭碗资源占用明细")
                        .font(DS.font(14, .semibold))
                        .foregroundStyle(DS.text)
                    Text("总内存 \(SystemResourceFormat.memory(snap.appMemoryBytes))（占整机 \(SystemResourceFormat.percent(snap.appMemoryUsage))）· CPU \(SystemResourceFormat.cpu(snap.appCPUUsage))")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 1) {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        let selected = sortMode == mode
                        Button {
                            sortMode = mode
                        } label: {
                            Text(mode.title)
                                .font(DS.font(11, selected ? .medium : .regular))
                                .foregroundStyle(selected ? DS.text : DS.textTertiary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(selected ? DS.selected : .clear, in: .rect(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(DS.border)

            if items.isEmpty {
                Text("暂无进程占用数据")
                    .font(DS.body)
                    .foregroundStyle(DS.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: DS.s(120))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ResourceDetailRow(
                                item: item,
                                totalAppMemory: snap.appMemoryBytes,
                                sortMode: sortMode,
                                onSuspend: {
                                    Task {
                                        for sid in item.sessionIDs {
                                            await app.webSessions.suspend(id: sid, force: true)
                                        }
                                        try? await Task.sleep(for: .milliseconds(300))
                                        app.systemMonitor.sampleNow()
                                    }
                                },
                                onClose: item.kind == .webPage && !item.sessionIDs.isEmpty ? {
                                    for sid in item.sessionIDs {
                                        app.closeWebSession(id: sid)
                                    }
                                    Task {
                                        try? await Task.sleep(for: .milliseconds(300))
                                        app.systemMonitor.sampleNow()
                                    }
                                } : nil
                            )
                            if index < items.count - 1 {
                                Divider().overlay(DS.border).padding(.horizontal, 14)
                            }
                        }
                    }
                }
                .frame(maxHeight: DS.s(320))
            }

            Divider().overlay(DS.border)

            HStack(spacing: 8) {
                Text("活跃网页 \(app.webSessions.liveCount) · 已休眠 \(app.webSessions.tombstonedCount)")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.textTertiary)
                Spacer(minLength: 4)
                if hasSuspendable {
                    Button("休眠后台网页") {
                        Task {
                            _ = await app.webSessions.suspendAllInactive()
                            try? await Task.sleep(for: .milliseconds(300))
                            app.systemMonitor.sampleNow()
                        }
                    }
                    .buttonStyle(.dsSecondary)
                }
                Button("设置") {
                    isPresented = false
                    app.openSettings(page: "web")
                }
                .buttonStyle(.dsGhost)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: DS.s(376))
        .background(DS.canvas)
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
    }

    private func sortedItems(_ items: [AppResourceItem]) -> [AppResourceItem] {
        items.sorted { lhs, rhs in
            switch sortMode {
            case .memory:
                if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                let lCPU = lhs.cpuUsage ?? -1
                let rCPU = rhs.cpuUsage ?? -1
                if lCPU != rCPU { return lCPU > rCPU }
                return lhs.pid < rhs.pid
            case .cpu:
                let lCPU = lhs.cpuUsage ?? -1
                let rCPU = rhs.cpuUsage ?? -1
                if lCPU != rCPU { return lCPU > rCPU }
                if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                return lhs.pid < rhs.pid
            }
        }
    }
}

private struct ResourceDetailRow: View {
    let item: AppResourceItem
    let totalAppMemory: UInt64
    let sortMode: ResourceDetailPopover.SortMode
    let onSuspend: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        let memoryShare = totalAppMemory > 0 ? min(1, max(0, Double(item.memoryBytes) / Double(totalAppMemory))) : 0
        let barRatio = sortMode == .memory ? memoryShare : min(1, max(0, item.cpuUsage ?? 0))
        let detailPart = item.detail.map { " · \($0)" } ?? ""

        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(DS.font(12))
                .foregroundStyle(iconColor)
                .frame(width: DS.s(26), height: DS.s(26))
                .background(DS.well, in: .rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(DS.font(13, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    if item.kind == .webPage {
                        if item.isVisible {
                            Tag("显示中", color: DS.toggle)
                        } else if item.neverSuspend {
                            Tag("免休眠", color: DS.warning)
                        }
                    }
                }

                Text("\(item.kind.label)\(detailPart) · PID \(item.pid)")
                    .font(DS.font(11))
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)

                GeometryReader { geo in
                    let width = barRatio > 0 ? max(3, geo.size.width * barRatio) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.well)
                        if width > 0 {
                            Capsule().fill(iconColor).frame(width: width)
                        }
                    }
                }
                .frame(height: 3)
                .padding(.top, 1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(SystemResourceFormat.memory(item.memoryBytes))
                    .font(DS.font(12.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.text)
                Text("CPU \(SystemResourceFormat.cpu(item.cpuUsage))")
                    .font(DS.font(11))
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
            }

            let canManualSuspend = item.kind == .webPage && !item.sessionIDs.isEmpty
            if canManualSuspend || onClose != nil {
                HStack(spacing: 2) {
                    if canManualSuspend {
                        Button(action: onSuspend) {
                            Image(systemName: "moon.zzz")
                                .font(DS.font(12))
                        }
                        .buttonStyle(.dsGhost)
                        .help("立即休眠释放内存")
                    }
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(DS.font(12))
                        }
                        .buttonStyle(.dsGhost)
                        .help("关闭网页")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var iconName: String {
        switch item.kind {
        case .mainApp: "macwindow"
        case .webPage: "globe"
        case .childProcess: "terminal"
        }
    }

    private var iconColor: Color {
        switch item.kind {
        case .mainApp: DS.brand
        case .webPage: DS.toggle
        case .childProcess: DS.textSecondary
        }
    }
}

private struct ResourceMeterRow: View {
    let label: String
    let valueText: String
    let ratio: Double
    let tint: Color

    var body: some View {
        let clamped = min(1, max(0, ratio))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(DS.font(12))
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 4)
                Text(valueText)
                    .font(DS.font(12.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                let width = clamped > 0 ? max(4, geo.size.width * clamped) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.well)
                    if width > 0 {
                        Capsule().fill(tint).frame(width: width)
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

/// 侧栏底部的小卡：今日上班时间、下班时间与下班倒计时。
private struct TodayCard: View {
    let app: AppModel

    var body: some View {
        let _ = app.now
        let now = Date()
        let cal = app.workCalendar
        let info = cal.dayInfo(now)
        let ot = cal.overtimeHours(on: now)
        let end = cal.effectiveWorkEnd(on: now)
        let hasClockIn = cal.clockIn(on: now) != nil

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if info.isWorkday {
                    Text("今天上班")
                        .font(DS.font(12))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if ot > 0 {
                        Text("加班 +\(WorkCalendar.hoursText(ot))h")
                            .font(DS.font(11.5, .medium).monospacedDigit())
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                    } else if hasClockIn {
                        Text("已打卡")
                            .font(DS.font(11))
                            .foregroundStyle(DS.success)
                            .lineLimit(1)
                    }
                } else {
                    Text(info.name ?? "今天休息")
                        .font(DS.font(12))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if ot > 0 {
                        Text("加班 +\(WorkCalendar.hoursText(ot))h")
                            .font(DS.font(11.5, .medium).monospacedDigit())
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                    }
                }
            }

            if info.isWorkday {
                if let end, end > now {
                    Text("距下班 \(remainingTimeText(to: end, from: now))")
                        .font(DS.font(15, .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    let progress = cal.workProgress(on: now) ?? 0
                    GeometryReader { geo in
                        let width = progress > 0 ? max(4, geo.size.width * progress) : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.well)
                            if width > 0 {
                                Capsule().fill(ot > 0 ? .purple : DS.brand).frame(width: width)
                            }
                        }
                    }
                    .frame(height: 4)
                } else {
                    Text("已下班，辛苦了")
                        .font(DS.font(15, .semibold))
                }

                HStack(spacing: 4) {
                    Text("上班 \(cal.onWorkTimeText(on: now))")
                        .font(DS.font(11.5).monospacedDigit())
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let endText = cal.offWorkTimeText(on: now) {
                        Text("下班 \(endText)")
                            .font(DS.font(11.5).monospacedDigit())
                            .foregroundStyle(ot > 0 ? .purple : DS.textSecondary)
                            .lineLimit(1)
                    }
                }
            } else if ot > 0 {
                Text("辛苦加班").font(DS.font(15, .semibold))
            } else {
                Text("好好休息").font(DS.font(15, .semibold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }
        .help(info.isWorkday ? cal.scheduleText(on: now) : (info.name ?? "今天休息"))
    }
}
