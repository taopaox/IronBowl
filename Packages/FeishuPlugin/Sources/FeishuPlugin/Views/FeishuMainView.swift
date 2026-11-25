import AppKit
import IronBowlKit
import SwiftUI

struct FeishuMainView: View {
    @Bindable var model: FeishuModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    @State private var showPinPopover = false
    @State private var copiedLink = false

    var body: some View {
        let session = model.activeSession
        let matchingPin = model.activePinnedPage ?? model.pinnedPage(matchingURL: session.currentURL)

        VStack(spacing: 0) {
            toolbar(session: session, matchingPin: matchingPin)

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

            WebContainerView(session: session, manager: model.webSessions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.canvas)
        .onAppear {
            addressText = session.currentURL
        }
        .onChange(of: model.activePageID) {
            addressText = model.activeSession.currentURL
            addressFocused = false
        }
        .onChange(of: session.currentURL) { _, newURL in
            if !addressFocused {
                addressText = newURL
            }
        }
    }

    private func toolbar(session: WebSession, matchingPin: FeishuPinnedPage?) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
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

                Button { session.goHome() } label: {
                    Image(systemName: model.activePinnedPage == nil ? "house" : "pin.circle")
                }
                .buttonStyle(.dsGhost)
                .help(model.activePinnedPage == nil ? "回到飞书首页" : "回到该固定页初始地址")
            }

            addressBar(session: session)

            HStack(spacing: 6) {
                Button {
                    showPinPopover = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: matchingPin == nil ? "pin" : "pin.fill")
                            .foregroundStyle(matchingPin == nil ? DS.textSecondary : DS.brand)
                        Text(matchingPin == nil ? "固定到左侧" : "已固定")
                    }
                }
                .buttonStyle(.dsSecondary)
                .help(matchingPin == nil ? "把当前网页固定到主窗口左侧栏" : "编辑或取消该固定网页")
                .popover(isPresented: $showPinPopover, arrowEdge: .bottom) {
                    PinPageEditor(
                        model: model,
                        editingPage: matchingPin,
                        initialTitle: matchingPin?.title ?? FeishuURL.cleanTitle(session.title, fallbackURL: session.currentURL),
                        initialURL: session.currentURL,
                        initialIcon: matchingPin?.systemImage ?? "doc.text",
                        initialNeverSuspend: matchingPin?.neverSuspend ?? false,
                        onClose: { showPinPopover = false }
                    )
                }

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
                    if let url = FeishuURL.normalize(session.currentURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.dsGhost)
                .help("在默认浏览器中打开")
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

    private func addressBar(session: WebSession) -> some View {
        let cleaned = FeishuURL.cleanTitle(session.title, fallbackURL: session.currentURL)
        return HStack(spacing: 8) {
            if let page = model.activePinnedPage {
                Label(page.title, systemImage: page.systemImage)
                    .font(DS.font(12, .medium))
                    .foregroundStyle(DS.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DS.card, in: .rect(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(DS.border) }
                    .lineLimit(1)
            } else {
                Image(systemName: "globe")
                    .font(DS.font(12))
                    .foregroundStyle(DS.textTertiary)
            }

            TextField("输入飞书或网页地址，按回车访问", text: $addressText)
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
                    .frame(maxWidth: 180, alignment: .trailing)
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

/// 固定/编辑网页弹窗（顶栏弹出与设置页共用）。
struct PinPageEditor: View {
    let model: FeishuModel
    let editingPage: FeishuPinnedPage?
    let onClose: () -> Void

    @State private var title: String
    @State private var url: String
    @State private var systemImage: String
    @State private var neverSuspend: Bool
    @State private var error: String?

    init(
        model: FeishuModel,
        editingPage: FeishuPinnedPage? = nil,
        initialTitle: String,
        initialURL: String,
        initialIcon: String = "doc.text",
        initialNeverSuspend: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.editingPage = editingPage
        self.onClose = onClose
        _title = State(initialValue: initialTitle)
        _url = State(initialValue: initialURL)
        _systemImage = State(initialValue: initialIcon)
        _neverSuspend = State(initialValue: initialNeverSuspend)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingPage == nil ? "固定网页到左侧栏" : "编辑固定网页")
                .font(DS.sectionTitle)

            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(DS.caption).foregroundStyle(DS.textSecondary)
                TextField("例如：产品需求文档", text: $title)
                    .textFieldStyle(.ds)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("网址").font(DS.caption).foregroundStyle(DS.textSecondary)
                TextField("https://my.feishu.cn/...", text: $url)
                    .textFieldStyle(.ds)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("图标").font(DS.caption).foregroundStyle(DS.textSecondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(FeishuPinnedPage.iconOptions, id: \.symbol) { option in
                        let selected = systemImage == option.symbol
                        Button {
                            systemImage = option.symbol
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: option.symbol)
                                Text(option.label).lineLimit(1)
                            }
                            .font(DS.font(12))
                            .foregroundStyle(selected ? DS.onPrimary : DS.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: DS.s(26))
                            .background(selected ? DS.primaryFill : DS.well, in: .rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("免休眠").font(DS.font(13.5, .medium))
                    Text("切走后不自动释放内存").font(DS.caption).foregroundStyle(DS.textSecondary)
                }
                Spacer()
                DSToggle(isOn: $neverSuspend)
            }

            if let error {
                DSBanner(.danger, error)
            }

            HStack(spacing: 8) {
                if let editingPage {
                    Button {
                        model.unpin(id: editingPage.id)
                        onClose()
                    } label: {
                        Text("取消固定").foregroundStyle(DS.danger)
                    }
                    .buttonStyle(.dsSecondary)
                }
                Spacer()
                Button("取消") { onClose() }.buttonStyle(.dsSecondary)
                Button(editingPage == nil ? "固定" : "保存") {
                    save()
                }
                .buttonStyle(.dsPrimary)
            }
        }
        .padding(16)
        .frame(width: DS.s(360))
        .background(DS.card)
    }

    private func save() {
        guard let normalized = FeishuURL.normalize(url) else {
            error = "请输入有效的 http:// 或 https:// 网址"
            return
        }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = clean.isEmpty ? FeishuURL.cleanTitle(nil, fallbackURL: normalized.absoluteString) : clean
        if let editingPage {
            model.updatePin(
                id: editingPage.id,
                title: finalTitle,
                url: normalized.absoluteString,
                systemImage: systemImage,
                neverSuspend: neverSuspend
            )
        } else {
            model.pin(
                title: finalTitle,
                url: normalized.absoluteString,
                systemImage: systemImage,
                neverSuspend: neverSuspend
            )
        }
        onClose()
    }
}
