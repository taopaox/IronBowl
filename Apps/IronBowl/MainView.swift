import IronBowlKit
import SwiftUI

/// 主窗口：左边浅灰侧栏，右边白色内容区（WorkBuddy 风格）。
struct MainView: View {
    @Bindable var app: AppModel
    @AppStorage("sidebarCollapsed") private var collapsed = false

    var body: some View {
        HStack(spacing: 0) {
            if !collapsed {
                Sidebar(app: app, collapsed: $collapsed)
                    .frame(width: DS.s(216))
                    .transition(.move(edge: .leading))
                Rectangle().fill(DS.border).frame(width: 1)
            }
            ZStack(alignment: .topLeading) {
                detail
                    .environment(\.sidebarCollapsed, collapsed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.canvas)
                if collapsed {
                    Button { withAnimation(.snappy) { collapsed = false } } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.dsGhost)
                        .help("展开侧边栏")
                        .padding(.leading, 82)
                        .padding(.top, 10)
                }
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 600)
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
        .onAppear { app.mainWindow(isOpen: true) }
        .onDisappear { app.mainWindow(isOpen: false) }
    }

    @ViewBuilder
    private var detail: some View {
        if app.selection == AppModel.homeID {
            HomeView(app: app)
        } else if let plugin = app.plugin(app.selection), app.enabledIDs.contains(plugin.id) {
            plugin.makeMainView().id(plugin.id)
        } else {
            HomeView(app: app)
        }
    }
}

struct Sidebar: View {
    let app: AppModel
    @Binding var collapsed: Bool
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebarCollapsedDirs") private var collapsedDirsRaw = ""
    @State private var renamingItem: SidebarPinnedItem?
    @State private var renameText = ""

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
            // 顶部：给红绿灯留位置，右边是收起按钮
            HStack {
                Spacer()
                Button { withAnimation(.snappy) { collapsed = true } } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.dsGhost)
                    .help("收起侧边栏")
            }
            .frame(height: 40)
            .padding(.horizontal, 10)
            .windowTitleBar()

            HStack(spacing: 6) {
                Text("饭碗").font(DS.font(16, .semibold))
                Text(Bundle.main.shortVersion).font(DS.font(12)).foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    DSSidebarItem("今天", systemImage: "house", selected: app.selection == AppModel.homeID) {
                        app.select(AppModel.homeID)
                    }
                    ForEach(app.enabledPlugins, id: \.id) { plugin in
                        let children = plugin.sidebarChildren
                        let hasSelectedChild = app.selection == plugin.id && (
                            plugin.sidebarPinnedItems.contains(where: \.isSelected) ||
                            children.contains(where: \.isSelected)
                        )
                        if plugin.isSidebarDirectory {
                            SidebarDirectoryHeader(
                                title: plugin.title,
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
                        } else {
                            DSSidebarItem(plugin.title, systemImage: plugin.systemImage,
                                          selected: app.selection == plugin.id && !hasSelectedChild,
                                          badge: plugin.isComingSoon ? "即将推出" : nil) {
                                plugin.onSidebarSelect()
                                app.select(plugin.id)
                            }
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

                    let recents = app.enabledPlugins.flatMap(\.sidebarRecents)
                    if !recents.isEmpty {
                        DSSidebarSection("最近日志")
                        ForEach(recents) { item in
                            RecentRow(item: item)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            ResourceCard(app: app).padding(.horizontal, 10).padding(.bottom, 8)
            TodayCard(app: app).padding(.horizontal, 10).padding(.bottom, 8)

            HStack(spacing: 2) {
                Text("🍚").font(DS.font(16))
                Text(NSFullUserName().isEmpty ? "我" : NSFullUserName()).font(DS.font(13.5))
                    .lineLimit(1)
                Spacer()
                Button { openWindow(id: "settings") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.dsGhost)
                    .help("设置")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
        }
        .background(DS.sidebar)
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
            } else if item.isSuspended {
                Image(systemName: "moon.zzz")
                    .font(DS.font(11))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.trailing, 3)
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
        if item.onSuspendNow != nil || item.onToggleNeverSuspend != nil {
            Divider()
        }
        if let onSuspendNow = item.onSuspendNow {
            Button("立即休眠") { onSuspendNow() }.disabled(item.isSuspended)
        }
        if let onToggleNeverSuspend = item.onToggleNeverSuspend {
            Button(item.isNeverSuspend ? "取消免休眠" : "设为免休眠") { onToggleNeverSuspend() }
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

private struct RecentRow: View {
    let item: SidebarRecent
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            HStack {
                Text(item.title).font(DS.font(13.5)).lineLimit(1)
                Spacer(minLength: 6)
                Text(item.trailing).font(DS.font(12)).foregroundStyle(DS.textTertiary)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(hovering ? DS.hover : .clear, in: .rect(cornerRadius: DS.controlRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 侧栏底部的小卡：实时 CPU 与内存占用（支持系统 / 饭碗切换及明细查看）。
private struct ResourceCard: View {
    let app: AppModel
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
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            ResourceDetailPopover(app: app, isPresented: $showDetail)
        }
        .task {
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
                                }
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

            if item.canSuspend {
                Button(action: onSuspend) {
                    Image(systemName: "moon.zzz")
                        .font(DS.font(12))
                }
                .buttonStyle(.dsGhost)
                .help("立即休眠释放内存")
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

/// 侧栏底部的小卡：今日工时 + 下班倒计时。
private struct TodayCard: View {
    let app: AppModel

    var body: some View {
        let _ = app.now
        let now = Date()
        let cal = app.workCalendar
        let info = cal.dayInfo(now)
        let ot = cal.overtimeHours(on: now)
        let end = cal.effectiveWorkEnd(on: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if info.isWorkday {
                    Text(ot > 0 ? "加班 +\(WorkCalendar.hoursText(ot))h" : "今天上班")
                        .font(DS.font(12.5))
                        .foregroundStyle(ot > 0 ? .purple : DS.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let endText = cal.offWorkTimeText(on: now) {
                        Text("\(endText) 下班")
                            .font(DS.font(11.5).monospacedDigit())
                            .foregroundStyle(ot > 0 ? .purple : DS.textTertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text(info.name ?? "今天休息")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if ot > 0 {
                        Text("加班 +\(WorkCalendar.hoursText(ot))h")
                            .font(DS.font(11.5).monospacedDigit())
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                    }
                }
            }
            if info.isWorkday, let end, end > now {
                Text("距下班 \(countdown(to: end, from: now))").font(DS.font(15, .semibold)).monospacedDigit()
                ProgressView(value: workProgress(end: end, now: now))
                    .progressViewStyle(.linear)
                    .tint(ot > 0 ? .purple : DS.brand)
            } else if !info.isWorkday && ot > 0 {
                Text("辛苦加班").font(DS.font(15, .semibold))
            } else {
                Text(info.isWorkday ? "已下班，辛苦了" : "好好休息").font(DS.font(15, .semibold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }
    }

    func workProgress(end: Date, now: Date) -> Double {
        let start = app.workCalendar.workStart(on: now)
            ?? end.addingTimeInterval(-(app.workCalendar.defaultWorkHours * 3600 + Double(app.settings[WorkCalendar.lunchMinutesKey]) * 60))
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }
}

extension Bundle {
    var shortVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
}
