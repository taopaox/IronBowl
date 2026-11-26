import AppKit
import IronBowlKit
import SwiftUI

private enum HomeInputMode: String, CaseIterable {
    case chat
    case quickLog

    var title: String {
        switch self {
        case .chat: "AI 对话"
        case .quickLog: "记日志"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "sparkles"
        case .quickLog: "square.and.pencil"
        }
    }
}

/// 首页「今天」：T3 Code 风格可折叠多对话工作台，支持流式输出详情与功能卡片插入。
struct HomeView: View {
    let app: AppModel

    @Environment(\.sidebarCollapsed) private var mainSidebarCollapsed
    @State private var input = ""
    @State private var inputMode: HomeInputMode = .chat
    @State private var pendingCards: [ChatCardAttachment] = []
    @State private var draftWorkspacePath = ""
    @State private var draftPermissionMode: ChatPermissionMode = .agent
    @State private var draftModel = ""
    @State private var sendingQuickLog = false
    @State private var showTopCardPicker = false
    @State private var showComposerCardPicker = false
    @State private var renamingCurrentThread = false
    @State private var renameText = ""
    @FocusState private var focused: Bool

    private var activeThread: ChatThread? {
        app.chat.selectedThread
    }

    private var activeWorkspacePath: String {
        if let thread = activeThread { return thread.workspacePath }
        return draftWorkspacePath.isEmpty ? app.chat.defaultWorkspacePath : draftWorkspacePath
    }

    private var activeWorkspaceName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if activeWorkspacePath == home { return "~" }
        let name = URL(fileURLWithPath: activeWorkspacePath).lastPathComponent
        return name.isEmpty ? activeWorkspacePath : name
    }

    private var activePermissionMode: ChatPermissionMode {
        activeThread?.permissionMode ?? draftPermissionMode
    }

    private var activeProviderKind: AIProviderKind {
        activeThread?.providerKind ?? app.providers.defaultKind
    }

    private var activeModel: String {
        activeThread?.model ?? draftModel
    }

    private var modelPickerOptions: [DSPickerOption<String>] {
        let configuredDefault = app.providers.config(activeProviderKind).model
        let defaultName = configuredDefault.isEmpty
            ? "默认模型"
            : (app.providers.modelDisplayName(id: configuredDefault, for: activeProviderKind) ?? configuredDefault)
        let defaultTitle = configuredDefault.isEmpty ? "默认模型" : "默认（\(defaultName)）"
        let defaultSubtitle = configuredDefault.isEmpty
            ? "使用 \(activeProviderKind.shortName) CLI 默认模型。"
            : "当前默认配置为：\(configuredDefault)"

        var options: [DSPickerOption<String>] = [
            DSPickerOption("", title: defaultTitle, subtitle: defaultSubtitle, triggerTitle: defaultName),
        ]
        let known = app.providers.models(for: activeProviderKind)
        for item in known {
            options.append(DSPickerOption(
                item.id,
                title: item.name,
                subtitle: item.detail ?? (item.id == item.name ? nil : item.id),
                triggerTitle: item.name
            ))
        }
        if !activeModel.isEmpty, !known.contains(where: { $0.id == activeModel }) {
            options.append(DSPickerOption(
                activeModel,
                title: activeModel,
                subtitle: "当前对话已选模型",
                triggerTitle: activeModel
            ))
        }
        return options
    }

    private var isCurrentRunning: Bool {
        guard let threadID = activeThread?.id else { return false }
        return app.chat.isRunning(threadID)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !app.chat.sidebarCollapsed {
                HomeChatSidebar(app: app, onNewDraft: startNewDraft)
                    .frame(width: DS.s(236))
                    .transition(.move(edge: .leading))
                Rectangle().fill(DS.border).frame(width: 1)
            }

            VStack(spacing: 0) {
                topBar
                Divider().overlay(DS.border)

                if activeThread == nil || app.chat.currentMessages.isEmpty {
                    welcomeArea
                } else {
                    HomeChatTimeline(
                        app: app,
                        messages: app.chat.currentMessages,
                        detailLevel: app.chat.detailLevel,
                        onAttachCardsToAsk: { cards in
                            attachCards(cards)
                        },
                        onRetry: { messageID in
                            if let threadID = activeThread?.id {
                                app.chat.retryMessage(messageID, in: threadID)
                            }
                        }
                    )
                }

                Divider().overlay(DS.border)
                composerArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.canvas)
        }
        .onAppear {
            if draftWorkspacePath.isEmpty {
                draftWorkspacePath = app.chat.defaultWorkspacePath
            }
            if draftModel.isEmpty {
                draftModel = app.chat.preferredModel(for: app.providers.defaultKind)
            }
        }
        .task(id: activeProviderKind) {
            await app.providers.loadModels(for: activeProviderKind)
        }
        .sheet(isPresented: $renamingCurrentThread) {
            if let thread = activeThread {
                VStack(alignment: .leading, spacing: 14) {
                    Text("重命名对话").font(DS.sectionTitle)
                    TextField("对话标题", text: $renameText)
                        .textFieldStyle(.ds)
                        .onSubmit {
                            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { app.chat.renameThread(thread.id, title: trimmed) }
                            renamingCurrentThread = false
                        }
                    HStack {
                        Spacer()
                        Button("取消") { renamingCurrentThread = false }.buttonStyle(.dsSecondary)
                        Button("保存") {
                            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { app.chat.renameThread(thread.id, title: trimmed) }
                            renamingCurrentThread = false
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

    // MARK: - 顶栏

    private var topBarLeadingPadding: CGFloat {
        (app.chat.sidebarCollapsed && mainSidebarCollapsed) ? 116 : 16
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if app.chat.sidebarCollapsed {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        app.chat.sidebarCollapsed = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.dsGhost)
                .help("展开对话列表")

                Button(action: startNewDraft) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.dsGhost)
                .help("新建对话")
            }

            if let thread = activeThread {
                Button {
                    renameText = thread.title
                    renamingCurrentThread = true
                } label: {
                    Text(thread.title)
                        .font(DS.font(14.5, .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("点击重命名对话")
            } else {
                Text("今天")
                    .font(DS.font(14.5, .semibold))
                    .foregroundStyle(DS.text)
            }

            Button(action: chooseWorkspaceDirectory) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                    Text(activeWorkspaceName)
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: DS.s(26))
                .background(DS.well, in: .rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border) }
            }
            .buttonStyle(.plain)
            .help("当前工作目录：\(activeWorkspacePath)（点击切换）")

            Menu {
                ForEach(ChatPermissionMode.allCases) { mode in
                    Button {
                        setPermissionMode(mode)
                    } label: {
                        Label(mode.displayName, systemImage: mode.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: activePermissionMode.systemImage)
                        .font(DS.font(11))
                    Text(activePermissionMode.shortTitle)
                        .font(DS.font(12, .medium))
                }
                .foregroundStyle(activePermissionMode == .agent ? DS.text : DS.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: DS.s(26))
                .background(DS.well, in: .rect(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(activePermissionMode.detail)

            Spacer(minLength: 8)

            DSPicker(
                selection: Binding(
                    get: { app.chat.detailLevel },
                    set: { app.chat.detailLevel = $0 }
                ),
                options: ChatOutputDetailLevel.allCases.map {
                    DSPickerOption($0, title: $0.displayName, subtitle: $0.detail, triggerTitle: $0.displayName)
                }
            )
            .help("控制命令与工具执行详情的展开方式")

            Button {
                showTopCardPicker.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                    Text("插入卡片")
                }
                .font(DS.font(12.5, .medium))
            }
            .buttonStyle(.dsSecondary)
            .popover(isPresented: $showTopCardPicker, arrowEdge: .bottom) {
                HomeCardPickerPopover(
                    app: app,
                    onInsertCards: { cards in
                        insertCardsIntoChat(cards)
                        showTopCardPicker = false
                    },
                    onAttachCard: { card in
                        attachCards([card])
                        showTopCardPicker = false
                    },
                    onSwitchToLogMode: {
                        inputMode = .quickLog
                        showTopCardPicker = false
                        focused = true
                    }
                )
            }
        }
        .padding(.leading, topBarLeadingPadding)
        .padding(.trailing, 16)
        .frame(height: 52)
        .windowTitleBar()
    }

    // MARK: - 欢迎与功能卡片网格

    private var welcomeArea: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer().frame(height: 36)
                Text(greeting).font(DS.heroTitle)

                Text("已绑定目录「\(activeWorkspaceName)」· \(activePermissionMode.displayName) · 支持多轮对话与执行详情")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)

                let actions = app.enabledPlugins.flatMap(\.quickActions)
                if !actions.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(suggestedChatIntents, id: \.title) { item in
                                Button {
                                    sendSuggestedIntent(item.prompt)
                                } label: {
                                    Label(item.title, systemImage: item.systemImage)
                                }
                                .buttonStyle(.dsChip)
                            }
                            ForEach(actions) { action in
                                Button { action.action() } label: {
                                    Label(action.title, systemImage: action.systemImage)
                                }
                                .buttonStyle(.dsChip)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }

                let cards = HomeCardCatalog.allCards(for: app)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("今日工作台")
                            .font(DS.font(13, .medium))
                            .foregroundStyle(DS.textSecondary)
                        Spacer()
                        Button {
                            insertCardsIntoChat(cards.map(HomeCardCatalog.snapshot(of:)))
                        } label: {
                            Label("全部插入对话", systemImage: "plus.bubble")
                                .font(DS.font(12, .medium))
                        }
                        .buttonStyle(.dsGhost)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(cards) { card in
                            WelcomeCardCell(card: card) {
                                insertCardsIntoChat([HomeCardCatalog.snapshot(of: card)])
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 740)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: app.now)
        let part = switch h {
        case 5..<11: "早上好"
        case 11..<13: "中午好"
        case 13..<18: "下午好"
        default: "晚上好"
        }
        return "饭碗，\(part)"
    }

    // MARK: - 底部输入框

    private var composerArea: some View {
        VStack(spacing: 8) {
            if !pendingCards.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(pendingCards) { card in
                            HStack(spacing: 6) {
                                Image(systemName: "square.grid.2x2")
                                    .font(DS.font(11))
                                    .foregroundStyle(DS.brand)
                                Text("\(card.label)：\(card.valueSnapshot)")
                                    .font(DS.font(12, .medium))
                                    .lineLimit(1)
                                Button {
                                    pendingCards.removeAll { $0.id == card.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(DS.font(10, .semibold))
                                        .foregroundStyle(DS.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(DS.well, in: .capsule)
                            .overlay { Capsule().strokeBorder(DS.border) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(HomeInputMode.allCases, id: \.self) { mode in
                        let selected = inputMode == mode
                        Button {
                            inputMode = mode
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.systemImage)
                                    .font(DS.font(11))
                                Text(mode.title)
                                    .font(DS.font(12, selected ? .semibold : .regular))
                            }
                            .foregroundStyle(selected ? DS.text : DS.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(selected ? DS.selected : .clear, in: .rect(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showComposerCardPicker.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text("卡片")
                        }
                        .font(DS.font(12))
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.well, in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showComposerCardPicker, arrowEdge: .top) {
                        HomeCardPickerPopover(
                            app: app,
                            onInsertCards: { cards in
                                insertCardsIntoChat(cards)
                                showComposerCardPicker = false
                            },
                            onAttachCard: { card in
                                attachCards([card])
                                showComposerCardPicker = false
                            },
                            onSwitchToLogMode: {
                                inputMode = .quickLog
                                showComposerCardPicker = false
                                focused = true
                            }
                        )
                    }

                    Spacer()
                    Text("Enter 发送 · Shift+Enter 换行")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textTertiary)
                }

                ZStack(alignment: .topLeading) {
                    if input.isEmpty {
                        Text(placeholderText)
                            .font(DS.body)
                            .foregroundStyle(DS.textTertiary)
                            .padding(.top, 1)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $input)
                        .font(DS.body)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .frame(minHeight: 44, maxHeight: 132)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            Task { await submitInput() }
                            return .handled
                        }
                }

                HStack(spacing: 8) {
                    if inputMode == .chat {
                        DSPicker(
                            selection: Binding(
                                get: { activeProviderKind },
                                set: { setProviderKind($0) }
                            ),
                            options: AIProviderKind.allCases.map {
                                DSPickerOption($0, title: $0.displayName, subtitle: $0.detail, triggerTitle: $0.shortName)
                            }
                        )

                        DSPicker(
                            selection: Binding(
                                get: { activeModel },
                                set: { setModel($0) }
                            ),
                            options: modelPickerOptions
                        )
                        .help("切换当前对话使用的模型")

                        Button {
                            Task { await app.providers.loadModels(for: activeProviderKind, force: true) }
                        } label: {
                            if app.providers.loadingModels.contains(activeProviderKind) {
                                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(DS.font(11.5))
                            }
                        }
                        .buttonStyle(.dsGhost)
                        .help("刷新 \(activeProviderKind.shortName) 可用模型列表")
                    } else {
                        Text("将调用禅道日志插件解析并添加到今天草稿")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                    }

                    Spacer()

                    if isCurrentRunning {
                        Button {
                            if let threadID = activeThread?.id {
                                app.chat.stopGeneration(threadID: threadID)
                            }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(DS.font(12, .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(DS.danger, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help("停止当前生成")
                    } else {
                        let emptyInput = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button {
                            Task { await submitInput() }
                        } label: {
                            Group {
                                if sendingQuickLog {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(DS.font(14, .bold))
                                }
                            }
                            .foregroundStyle(DS.onPrimary)
                            .frame(width: 30, height: 30)
                            .background(DS.primaryFill.opacity(emptyInput ? 0.3 : 1), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .disabled(emptyInput || sendingQuickLog)
                    }
                }
            }
            .padding(12)
            .background(DS.card, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(focused ? DS.borderStrong : DS.border)
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(DS.canvas)
    }

    private var placeholderText: String {
        switch inputMode {
        case .chat:
            "向 \(activeProviderKind.displayName) 提问，或在「\(activeWorkspaceName)」内读写文件与执行命令…"
        case .quickLog:
            "今天做了什么？说一句，帮你记成禅道日志。比如：下午和产品对需求 2 小时"
        }
    }

    // MARK: - 交互动作

    private func startNewDraft() {
        app.chat.startNewDraft()
        inputMode = .chat
        pendingCards = []
        draftModel = app.chat.preferredModel(for: app.providers.defaultKind)
        focused = true
    }

    private func chooseWorkspaceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工作目录"
        panel.directoryURL = URL(fileURLWithPath: activeWorkspacePath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        app.chat.defaultWorkspacePath = path
        if let threadID = activeThread?.id {
            app.chat.updateThread(threadID, workspacePath: path)
        } else {
            draftWorkspacePath = path
        }
    }

    private func setPermissionMode(_ mode: ChatPermissionMode) {
        if let threadID = activeThread?.id {
            app.chat.updateThread(threadID, permissionMode: mode)
        } else {
            draftPermissionMode = mode
        }
    }

    private func setProviderKind(_ kind: AIProviderKind) {
        app.providers.defaultKind = kind
        let rememberedModel = app.chat.preferredModel(for: kind)
        if let threadID = activeThread?.id {
            app.chat.updateThread(threadID, providerKind: kind, model: rememberedModel)
        } else {
            draftModel = rememberedModel
        }
        Task { await app.providers.loadModels(for: kind) }
    }

    private func setModel(_ model: String) {
        app.chat.setPreferredModel(model, for: activeProviderKind)
        if let threadID = activeThread?.id {
            app.chat.updateThread(threadID, model: model)
        } else {
            draftModel = model
        }
    }

    private func attachCards(_ cards: [ChatCardAttachment]) {
        for card in cards where !pendingCards.contains(where: { $0.cardID == card.cardID }) {
            pendingCards.append(card)
        }
        inputMode = .chat
        focused = true
    }

    private func insertCardsIntoChat(_ cards: [ChatCardAttachment]) {
        guard !cards.isEmpty else { return }
        _ = app.chat.insertCards(cards, into: activeThread?.id)
    }

    private var suggestedChatIntents: [(title: String, systemImage: String, prompt: String)] {
        var items: [(String, String, String)] = []
        if app.enabledPlugins.contains(where: { $0.id == "zentao.log" }) {
            items.append(("生成今日日报（对话卡片）", "doc.badge.plus", "生成今日日报"))
        }
        if app.enabledPlugins.contains(where: { $0.id == "report" }) {
            items.append(("生成本周周报（对话卡片）", "doc.text", "生成本周周报"))
        }
        if app.enabledPlugins.contains(where: { $0.id == "report.monthly" }) {
            items.append(("生成本月月报（对话卡片）", "doc.richtext", "生成本月月报"))
        }
        return items
    }

    private func sendSuggestedIntent(_ prompt: String) {
        input = prompt
        Task { await submitInput() }
    }

    private func submitInput() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        switch inputMode {
        case .chat:
            guard !isCurrentRunning else { return }
            let cardsToAttach = pendingCards
            input = ""
            pendingCards = []
            if let matchedPlugin = app.enabledPlugins.first(where: { $0.canHandleChatIntent(text) }) {
                app.chat.runPluginIntentTurn(
                    text,
                    attachedCards: cardsToAttach,
                    providerKind: activeProviderKind,
                    model: activeModel,
                    workspacePath: activeWorkspacePath,
                    permissionMode: activePermissionMode,
                    in: activeThread?.id
                ) { onProgress in
                    await matchedPlugin.handleChatIntent(text, onProgress: onProgress)
                        ?? ChatPluginExecutionResult(replyText: "未能处理该指令。", isError: true)
                }
            } else {
                app.chat.sendMessage(
                    text,
                    attachedCards: cardsToAttach,
                    providerKind: activeProviderKind,
                    model: activeModel,
                    workspacePath: activeWorkspacePath,
                    permissionMode: activePermissionMode,
                    in: activeThread?.id
                )
            }

        case .quickLog:
            guard !sendingQuickLog else { return }
            sendingQuickLog = true
            defer { sendingQuickLog = false }
            var reply: String?
            for plugin in app.enabledPlugins {
                if let r = await plugin.handleHomeInput(text) {
                    reply = r
                    break
                }
            }
            let finalReply = reply ?? "❌ 没有插件能处理这句话"
            let isError = finalReply.hasPrefix("❌")
            let card = ChatCardAttachment(
                cardID: isError ? "zentao.quickLog.error" : "zentao.today",
                label: isError ? "记日志结果" : "今日日志",
                valueSnapshot: isError ? "记录失败" : "已加入草稿",
                detailSnapshot: finalReply.replacingOccurrences(of: "❌ ", with: ""),
                isError: isError
            )
            app.chat.recordPluginActionTurn(
                userText: text,
                card: card,
                replyText: finalReply,
                into: activeThread?.id
            )
            if !isError {
                input = ""
            }
        }
    }
}

private struct WelcomeCardCell: View {
    let card: HomeCard
    let onInsert: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                card.action?()
            } label: {
                DSMetric(card.label, value: card.value(), detail: card.detail())
            }
            .buttonStyle(.plain)
            .disabled(card.action == nil)

            if hovering {
                Button(action: onInsert) {
                    Image(systemName: "plus.bubble")
                        .font(DS.font(11.5, .medium))
                        .foregroundStyle(DS.text)
                        .padding(5)
                        .background(DS.card, in: .circle)
                        .overlay { Circle().strokeBorder(DS.borderStrong) }
                }
                .buttonStyle(.plain)
                .padding(7)
                .help("插入这张卡片到对话")
            }
        }
        .onHover { hovering = $0 }
    }
}
