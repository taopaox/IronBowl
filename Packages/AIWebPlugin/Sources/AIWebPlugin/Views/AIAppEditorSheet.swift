import AppKit
import IronBowlKit
import SwiftUI
import UniformTypeIdentifiers

struct AIAppEditorSheet: View {
    let model: AIWebModel
    let editingApp: AIWebApp?
    let onClose: () -> Void

    @State private var name: String
    @State private var url: String
    @State private var descriptionText: String
    @State private var category: AICategory
    @State private var logo: AILogoSource
    @State private var isPinned: Bool
    @State private var neverSuspend: Bool

    @State private var remoteLogoInput = ""
    @State private var showIconGrid = false
    @State private var busyAction: String?
    @State private var error: String?
    @State private var confirmDelete = false

    init(model: AIWebModel, editingApp: AIWebApp?, onClose: @escaping () -> Void) {
        self.model = model
        self.editingApp = editingApp
        self.onClose = onClose
        _name = State(initialValue: editingApp?.name ?? "")
        _url = State(initialValue: editingApp?.url ?? "")
        _descriptionText = State(initialValue: editingApp?.description ?? "")
        _category = State(initialValue: editingApp?.category ?? .custom)
        _logo = State(initialValue: editingApp?.logo ?? .symbol("sparkles"))
        _isPinned = State(initialValue: editingApp?.isPinned ?? true)
        _neverSuspend = State(initialValue: editingApp?.neverSuspend ?? false)
        if case let .remoteURL(existingRemote) = editingApp?.logo {
            _remoteLogoInput = State(initialValue: existingRemote)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(editingApp == nil ? "添加 AI" : "编辑 AI")
                    .font(DS.pageTitle)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.dsGhost)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    logoSection
                    formFields
                    if let error {
                        DSBanner(.danger, error)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                if editingApp != nil {
                    Button {
                        confirmDelete = true
                    } label: {
                        Text("删除").foregroundStyle(DS.danger)
                    }
                    .buttonStyle(.dsSecondary)
                }
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(.dsSecondary)
                Button(editingApp == nil ? "添加" : "保存") {
                    save()
                }
                .buttonStyle(.dsPrimary)
                .disabled(busyAction != nil)
            }
        }
        .padding(18)
        .frame(width: DS.s(460))
        .frame(maxHeight: DS.s(620))
        .background(DS.card)
        .alert("删除「\(editingApp?.name ?? "")」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                if let editingApp {
                    model.deleteApp(id: editingApp.id)
                }
                onClose()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将关闭其内嵌网页会话；内置 AI 可在设置中随时补齐。")
        }
    }

    private var logoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Logo 图标").font(DS.caption).foregroundStyle(DS.textSecondary)

            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DS.well)
                    AILogoView(logo: logo, logoStore: model.logoStore, size: DS.s(36), cornerRadius: 8)
                }
                .frame(width: DS.s(54), height: DS.s(54))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Button("选择本地图片…") { pickLocalImage() }
                            .buttonStyle(.dsSecondary)

                        Button {
                            Task { await fetchSiteFavicon() }
                        } label: {
                            if busyAction == "favicon" {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small)
                                    Text("抓取中…")
                                }
                            } else {
                                Text("抓取网站图标")
                            }
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(busyAction != nil || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack(spacing: 6) {
                        Button(showIconGrid ? "收起官方图标库" : "官方图标库") {
                            showIconGrid.toggle()
                        }
                        .buttonStyle(.dsGhost)

                        if let presetID = editingApp?.presetID,
                           let preset = AIWebPresets.preset(for: presetID),
                           preset.logo != logo {
                            Button("恢复官方图标") {
                                error = nil
                                logo = preset.logo
                            }
                            .buttonStyle(.dsGhost)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("或粘贴图片链接 (https://...)", text: $remoteLogoInput)
                    .textFieldStyle(.ds)
                    .onSubmit { applyRemoteLink(downloadLocally: false) }
                Button("使用链接") {
                    applyRemoteLink(downloadLocally: false)
                }
                .buttonStyle(.dsSecondary)
                .disabled(remoteLogoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await downloadRemoteLogoLocally() }
                } label: {
                    if busyAction == "remote" {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("下载缓存")
                    }
                }
                .buttonStyle(.dsGhost)
                .disabled(busyAction != nil || remoteLogoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if showIconGrid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(AIWebPresets.bundledIconChoices, id: \.name) { choice in
                        let candidate = AILogoSource.bundled(name: choice.name, isTemplate: choice.isTemplate)
                        let selected = logo == candidate
                        Button {
                            error = nil
                            logo = candidate
                        } label: {
                            VStack(spacing: 3) {
                                AILogoView(logo: candidate, logoStore: model.logoStore, size: DS.s(22), cornerRadius: 5)
                                Text(choice.label)
                                    .font(DS.font(10.5))
                                    .foregroundStyle(DS.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(selected ? DS.selected : DS.well, in: .rect(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(selected ? DS.borderStrong : .clear)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(DS.canvas, in: .rect(cornerRadius: DS.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.border) }
            }
        }
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(DS.caption).foregroundStyle(DS.textSecondary)
                TextField("例如：ChatGPT / 公司内部 AI", text: $name)
                    .textFieldStyle(.ds)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("网址链接").font(DS.caption).foregroundStyle(DS.textSecondary)
                TextField("https://chatgpt.com", text: $url)
                    .textFieldStyle(.ds)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("简介（可选）").font(DS.caption).foregroundStyle(DS.textSecondary)
                TextField("简短说明用途", text: $descriptionText)
                    .textFieldStyle(.ds)
            }

            HStack {
                Text("分类").font(DS.font(13.5, .medium))
                Spacer()
                DSPicker(
                    selection: $category,
                    options: AICategory.allCases.map { DSPickerOption($0, title: $0.displayName, subtitle: $0.detail) }
                )
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("固定到左侧 AI 目录").font(DS.font(13.5, .medium))
                    Text("固定后可直接从左侧菜单一键打开").font(DS.caption).foregroundStyle(DS.textSecondary)
                }
                Spacer()
                DSToggle(isOn: $isPinned)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("免休眠").font(DS.font(13.5, .medium))
                    Text("切走后不自动释放网页内存").font(DS.caption).foregroundStyle(DS.textSecondary)
                }
                Spacer()
                DSToggle(isOn: $neverSuspend)
            }
        }
    }

    private func pickLocalImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .icns, .webP, .bmp]
        if panel.runModal() == .OK, let selected = panel.url {
            do {
                logo = try model.logoStore.saveLocalImage(from: selected)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func fetchSiteFavicon() async {
        busyAction = "favicon"
        error = nil
        defer { busyAction = nil }
        do {
            logo = try await model.logoStore.fetchWebsiteFavicon(for: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyRemoteLink(downloadLocally: Bool) {
        guard let normalized = WebURL.normalize(remoteLogoInput) else {
            error = "图标链接格式无效，请输入 http:// 或 https:// 图片地址"
            return
        }
        error = nil
        if !downloadLocally {
            logo = .remoteURL(normalized.absoluteString)
        }
    }

    private func downloadRemoteLogoLocally() async {
        busyAction = "remote"
        error = nil
        defer { busyAction = nil }
        do {
            logo = try await model.logoStore.downloadRemoteLogo(from: remoteLogoInput)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard let normalized = WebURL.normalize(url) else {
            error = "请输入有效的 http:// 或 https:// 网址"
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty
            ? WebURL.cleanTitle(nil, fallbackURL: normalized.absoluteString)
            : cleanName

        if let editingApp {
            model.updateApp(
                id: editingApp.id,
                name: finalName,
                url: normalized.absoluteString,
                description: descriptionText,
                category: category,
                logo: logo,
                isPinned: isPinned,
                neverSuspend: neverSuspend
            )
        } else {
            model.addApp(
                name: finalName,
                url: normalized.absoluteString,
                description: descriptionText,
                category: category,
                logo: logo,
                isPinned: isPinned,
                neverSuspend: neverSuspend
            )
        }
        onClose()
    }
}
