import AppKit
import IronBowlKit
import SwiftUI

struct AIWebMainView: View {
    @Bindable var model: AIWebModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    @State private var filter: DirectoryFilter = .all
    @State private var searchQuery = ""
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    @State private var copiedLink = false

    private enum DirectoryFilter: Hashable {
        case all
        case pinned
        case category(AICategory)
    }

    var body: some View {
        Group {
            if let app = model.activeApp, let session = model.activeSession {
                webView(app: app, session: session)
            } else {
                directoryView
            }
        }
        .background(DS.canvas)
        .sheet(item: $model.editorTarget) { target in
            AIAppEditorSheet(model: model, editingApp: target.app) {
                model.editorTarget = nil
            }
        }
        .onAppear {
            if let session = model.activeSession {
                addressText = session.currentURL
            }
        }
        .onChange(of: model.activeAppID) {
            addressFocused = false
            addressText = model.activeSession?.currentURL ?? ""
        }
    }

    // MARK: - AI 目录总览

    private var directoryView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("AI 目录").font(DS.pageTitle)
                Text("\(model.pinnedApps.count) 个已固定 · 共 \(model.apps.count) 个")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                Spacer()
                Button("添加 AI") {
                    model.beginCreating()
                }
                .buttonStyle(.dsPrimary)
            }
            .padding(.leading, sidebarCollapsed ? 120 : 28)
            .padding(.trailing, 28)
            .frame(height: 52)
            .windowTitleBar()

            HStack(spacing: 10) {
                DSTabs(selection: $filter, options: filterOptions)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.font(12))
                        .foregroundStyle(DS.textTertiary)
                    TextField("搜索 AI 名称或网址", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(DS.font(13))
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DS.font(12))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: DS.s(210), height: DS.s(28))
                .background(DS.well, in: .rect(cornerRadius: DS.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.border) }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)

            Rectangle().fill(DS.border).frame(height: 1)

            let items = filteredApps
            if items.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的 AI", systemImage: "sparkles")
                } description: {
                    Text(model.apps.isEmpty ? "点击右上角「添加 AI」，或前往设置恢复内置主流 AI。" : "换个筛选条件或搜索词试试。")
                } actions: {
                    if model.apps.isEmpty {
                        Button("添加 AI") { model.beginCreating() }.buttonStyle(.dsPrimary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(items) { app in
                            AIAppCard(
                                app: app,
                                logoStore: model.logoStore,
                                hasLiveSession: model.hasOpenSession(appID: app.id),
                                isSuspended: model.isSuspended(appID: app.id),
                                onOpen: { model.selectApp(app.id) },
                                onClose: { model.closeApp(id: app.id) },
                                onTogglePin: { model.togglePin(id: app.id) },
                                onEdit: { model.beginEditing(appID: app.id) },
                                onDelete: { model.deleteApp(id: app.id) },
                                onOpenInBrowser: {
                                    if let url = WebURL.normalize(app.url) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var filterOptions: [(DirectoryFilter, String)] {
        var opts: [(DirectoryFilter, String)] = [
            (.all, "全部"),
            (.pinned, "已固定"),
        ]
        for cat in AICategory.allCases {
            if model.apps.contains(where: { $0.category == cat }) {
                opts.append((.category(cat), cat.displayName))
            }
        }
        return opts
    }

    private var filteredApps: [AIWebApp] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.apps.filter { app in
            switch filter {
            case .all: break
            case .pinned: guard app.isPinned else { return false }
            case let .category(cat): guard app.category == cat else { return false }
            }
            guard !q.isEmpty else { return true }
            return app.name.localizedCaseInsensitiveContains(q)
                || app.url.localizedCaseInsensitiveContains(q)
                || app.description.localizedCaseInsensitiveContains(q)
                || app.category.displayName.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - 内嵌网页视图

    private func webView(app: AIWebApp, session: WebSession) -> some View {
        VStack(spacing: 0) {
            webToolbar(app: app, session: session)

            if let error = session.errorMessage {
                HStack(spacing: 8) {
                    DSBanner(.danger, error)
                    Button("重试") { session.reload() }.buttonStyle(.dsSecondary)
                    Button { session.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.dsGhost)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(DS.canvas)
                .overlay(alignment: .bottom) { Rectangle().fill(DS.border).frame(height: 1) }
            }

            if let notice = session.downloadNotice {
                HStack(spacing: 8) {
                    DSBanner(.info, notice)
                    Button { session.downloadNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.dsGhost)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(DS.canvas)
                .overlay(alignment: .bottom) { Rectangle().fill(DS.border).frame(height: 1) }
            }

            WebContainerView(session: session, manager: model.webSessions) {
                model.closeApp(id: app.id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: session.currentURL) { _, newURL in
            if !addressFocused {
                addressText = newURL
            }
        }
    }

    private func webToolbar(app: AIWebApp, session: WebSession) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { model.selectDirectory() } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(.dsGhost)
                    .help("返回 AI 目录")

                Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.dsGhost)
                    .disabled(!session.canGoBack)
                    .help("后退")

                Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.dsGhost)
                    .disabled(!session.canGoForward)
                    .help("前进")

                Button {
                    if session.isLoading { session.stopLoading() } else { session.reload() }
                } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.dsGhost)
                .help(session.isLoading ? "停止加载" : "刷新")

                Button { session.goHome() } label: { Image(systemName: "house") }
                    .buttonStyle(.dsGhost)
                    .help("回到 \(app.name) 首页")
            }

            addressBar(app: app, session: session)

            HStack(spacing: 6) {
                Button {
                    model.togglePin(id: app.id)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: app.isPinned ? "pin.fill" : "pin")
                            .foregroundStyle(app.isPinned ? DS.brand : DS.textSecondary)
                        Text(app.isPinned ? "已固定" : "固定到目录")
                    }
                }
                .buttonStyle(.dsSecondary)
                .help(app.isPinned ? "从左侧 AI 目录取消固定" : "固定到左侧 AI 目录")

                Button {
                    model.beginEditing(appID: app.id)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.dsGhost)
                .help("修改名称、Logo 或链接")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.currentURL, forType: .string)
                    copiedLink = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedLink = false
                    }
                } label: {
                    Image(systemName: copiedLink ? "checkmark" : "link")
                        .foregroundStyle(copiedLink ? DS.success : DS.textSecondary)
                }
                .buttonStyle(.dsGhost)
                .help(copiedLink ? "已复制链接" : "复制当前链接")

                Button {
                    if let url = WebURL.normalize(session.currentURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.dsGhost)
                .help("在默认浏览器中打开")

                Rectangle()
                    .fill(DS.border)
                    .frame(width: 1, height: DS.s(16))

                Button {
                    Task { await model.suspendApp(id: app.id) }
                } label: {
                    Image(systemName: "moon.zzz")
                }
                .buttonStyle(.dsGhost)
                .disabled(session.isTombstoned)
                .help(session.isTombstoned ? "当前页面已处于休眠状态" : "立即休眠释放内存")
                .accessibilityLabel("立即休眠")

                Button {
                    model.closeApp(id: app.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.dsGhost)
                .help("关闭网页")
                .accessibilityLabel("关闭网页")
            }
        }
        .padding(.leading, sidebarCollapsed ? 120 : 14)
        .padding(.trailing, 14)
        .frame(height: DS.s(46))
        .windowTitleBar()
        .background(DS.canvas)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Rectangle().fill(DS.border).frame(height: 1)
                if session.isLoading {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(DS.brand)
                            .frame(width: geo.size.width * max(0.08, min(1, session.estimatedProgress)), height: 2)
                            .animation(.easeOut(duration: 0.18), value: session.estimatedProgress)
                    }
                    .frame(height: 2)
                }
            }
        }
    }

    private func addressBar(app: AIWebApp, session: WebSession) -> some View {
        let cleaned = WebURL.cleanTitle(session.title, fallbackURL: session.currentURL)
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                AILogoView(logo: app.logo, logoStore: model.logoStore, size: DS.s(14), cornerRadius: 3)
                Text(app.name)
                    .font(DS.font(12, .medium))
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(DS.card, in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(DS.border) }
            .lineLimit(1)

            TextField("输入网址，按回车访问", text: $addressText)
                .textFieldStyle(.plain)
                .font(DS.font(13))
                .focused($addressFocused)
                .onSubmit {
                    session.load(urlString: addressText)
                    addressFocused = false
                }

            if !addressFocused, !cleaned.isEmpty, cleaned != addressText {
                Text(cleaned)
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: DS.s(30))
        .background(addressFocused ? DS.card : DS.well, in: .rect(cornerRadius: DS.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DS.controlRadius)
                .strokeBorder(addressFocused ? DS.borderStrong : DS.border)
        }
    }
}

private struct AIAppCard: View {
    let app: AIWebApp
    let logoStore: AILogoStore
    let hasLiveSession: Bool
    let isSuspended: Bool
    let onOpen: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenInBrowser: () -> Void

    @State private var hovering = false

    var body: some View {
        DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DS.well)
                        AILogoView(logo: app.logo, logoStore: logoStore, size: DS.s(26), cornerRadius: 6)
                    }
                    .frame(width: DS.s(36), height: DS.s(36))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(DS.rowTitle)
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        Text(app.hostDisplay)
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Button(action: onTogglePin) {
                        Image(systemName: app.isPinned ? "pin.fill" : "pin")
                            .font(DS.font(13))
                            .foregroundStyle(app.isPinned ? DS.brand : DS.textTertiary)
                    }
                    .buttonStyle(.dsGhost)
                    .help(app.isPinned ? "从左侧 AI 目录取消固定" : "固定到左侧 AI 目录")
                }

                Text(app.description.isEmpty ? app.category.displayName : app.description)
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                    .frame(minHeight: DS.s(32), alignment: .topLeading)

                HStack(spacing: 6) {
                    if hasLiveSession {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isSuspended ? DS.textTertiary : DS.success)
                                .frame(width: 6, height: 6)
                            Text(isSuspended ? "已休眠" : "运行中")
                                .font(DS.font(11.5))
                                .foregroundStyle(DS.textTertiary)
                        }
                    } else {
                        Text(app.category.displayName)
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.textTertiary)
                    }

                    Spacer()

                    if hasLiveSession {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(DS.font(12))
                        }
                        .buttonStyle(.dsGhost)
                        .help("关闭网页")
                    }

                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(DS.font(12))
                    }
                    .buttonStyle(.dsGhost)
                    .help("编辑")

                    Menu {
                        Button("打开网页", action: onOpen)
                        if hasLiveSession {
                            Button("关闭网页", action: onClose)
                        }
                        Button(app.isPinned ? "取消固定" : "固定到左侧目录", action: onTogglePin)
                        Button("编辑…", action: onEdit)
                        Button("在默认浏览器打开", action: onOpenInBrowser)
                        Divider()
                        Button("删除", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(DS.font(12))
                            .foregroundStyle(DS.textSecondary)
                            .frame(width: DS.s(26), height: DS.s(26))
                            .contentShape(.rect)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .overlay {
            if hovering {
                RoundedRectangle(cornerRadius: DS.radius)
                    .strokeBorder(DS.borderStrong)
            }
        }
        .contentShape(.rect(cornerRadius: DS.radius))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("打开网页", action: onOpen)
            if hasLiveSession {
                Button("关闭网页", action: onClose)
            }
            Button(app.isPinned ? "取消固定" : "固定到左侧目录", action: onTogglePin)
            Button("编辑…", action: onEdit)
            Button("在默认浏览器打开", action: onOpenInBrowser)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}
