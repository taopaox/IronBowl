import Foundation
import GRDB
import Observation

/// 首页「今天」多对话工作台状态与 SQLite 持久化管理。
@Observable
public final class ChatStore {
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let providers: AIProviderStore

    public var threads: [ChatThread] = []
    public var selectedThreadID: String?
    public var messagesByThread: [String: [ChatMessage]] = [:]
    public var runningThreadIDs: Set<String> = []

    @ObservationIgnored private var activeRuns: [String: ActiveRun] = [:]
    @ObservationIgnored private var loadedMessageThreadIDs: Set<String> = []
    @ObservationIgnored public var onTurnCompleted: (() -> Void)?

    public init(database: AppDatabase, settings: SettingsStore, providers: AIProviderStore) {
        self.database = database
        self.settings = settings
        self.providers = providers
        loadThreads()
    }

    // MARK: - 偏好设置

    public var detailLevel: ChatOutputDetailLevel {
        get { settings[ChatKeys.detailLevel] }
        set { settings[ChatKeys.detailLevel] = newValue }
    }

    public var sidebarCollapsed: Bool {
        get { settings[ChatKeys.sidebarCollapsed] }
        set { settings[ChatKeys.sidebarCollapsed] = newValue }
    }

    public var workbenchBridgeEnabled: Bool {
        get { settings[ChatKeys.workbenchBridgeEnabled] }
        set { settings[ChatKeys.workbenchBridgeEnabled] = newValue }
    }

    public var defaultWorkspacePath: String {
        get {
            let saved = settings[ChatKeys.defaultWorkspace].trimmingCharacters(in: .whitespacesAndNewlines)
            if !saved.isEmpty {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: saved, isDirectory: &isDir), isDir.boolValue {
                    return saved
                }
            }
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        set {
            settings[ChatKeys.defaultWorkspace] = newValue
        }
    }

    public func preferredModel(for kind: AIProviderKind) -> String {
        settings[ChatKeys.lastModelByProvider][kind.rawValue] ?? ""
    }

    public func setPreferredModel(_ model: String, for kind: AIProviderKind) {
        var map = settings[ChatKeys.lastModelByProvider]
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: kind.rawValue)
        } else {
            map[kind.rawValue] = trimmed
        }
        settings[ChatKeys.lastModelByProvider] = map
    }

    public var selectedThread: ChatThread? {
        guard let selectedThreadID else { return nil }
        return threads.first { $0.id == selectedThreadID }
    }

    public var currentMessages: [ChatMessage] {
        guard let selectedThreadID else { return [] }
        return messagesByThread[selectedThreadID] ?? []
    }

    public func isRunning(_ threadID: String) -> Bool {
        runningThreadIDs.contains(threadID)
    }

    // MARK: - 加载与增删改

    public func ensureMessagesLoaded(for threadID: String) {
        guard !loadedMessageThreadIDs.contains(threadID) else { return }
        loadedMessageThreadIDs.insert(threadID)
        let loaded = (try? database.pool.read { db in
            try ChatMessageRow.fetchAll(
                db,
                sql: "SELECT * FROM chatMessage WHERE threadID = ? ORDER BY createdAt ASC",
                arguments: [threadID]
            ).map { $0.toMessage() }
        }) ?? []

        if let existing = messagesByThread[threadID], !existing.isEmpty {
            let existingIDs = Set(existing.map(\.id))
            let merged = loaded.filter { !existingIDs.contains($0.id) } + existing
            messagesByThread[threadID] = merged.sorted { $0.createdAt < $1.createdAt }
        } else {
            messagesByThread[threadID] = loaded
        }
    }

    public func loadThreads() {
        let loadedThreads = (try? database.pool.write { db -> [ChatThread] in
            // 仅修正上次异常退出的流式消息，避免冷启动全表反序列化历史消息。
            try db.execute(
                sql: """
                UPDATE chatMessage
                SET status = 'cancelled',
                    errorMessage = COALESCE(errorMessage, '上次生成在完成前被中断。')
                WHERE status = 'streaming'
                """
            )
            let threadRows = try ChatThreadRow.fetchAll(
                db,
                sql: "SELECT * FROM chatThread ORDER BY isPinned DESC, updatedAt DESC"
            )
            return threadRows.map { $0.toThread() }
        }) ?? []

        self.threads = loadedThreads
        self.messagesByThread = [:]
        self.loadedMessageThreadIDs = []

        if let lastID = settings[ChatKeys.lastThreadID], threads.contains(where: { $0.id == lastID }) {
            selectedThreadID = lastID
            ensureMessagesLoaded(for: lastID)
        } else {
            selectedThreadID = nil
        }
    }

    public func startNewDraft() {
        selectedThreadID = nil
        settings[ChatKeys.lastThreadID] = nil
    }

    @discardableResult
    public func createThread(
        title: String = "新对话",
        providerKind: AIProviderKind? = nil,
        model: String? = nil,
        workspacePath: String? = nil,
        permissionMode: ChatPermissionMode = .agent
    ) -> ChatThread {
        let now = Date()
        let resolvedProvider = providerKind ?? providers.defaultKind
        let resolvedModel = model ?? preferredModel(for: resolvedProvider)
        let resolvedWorkspace = (workspacePath?.isEmpty == false) ? workspacePath! : defaultWorkspacePath
        defaultWorkspacePath = resolvedWorkspace
        let thread = ChatThread(
            title: title,
            providerKind: resolvedProvider,
            model: resolvedModel,
            workspacePath: resolvedWorkspace,
            permissionMode: permissionMode,
            remoteSessionID: nil,
            isPinned: false,
            createdAt: now,
            updatedAt: now
        )
        threads.append(thread)
        sortThreads()
        messagesByThread[thread.id] = []
        loadedMessageThreadIDs.insert(thread.id)
        persistThread(thread)
        selectThread(thread.id)
        return thread
    }

    public func selectThread(_ id: String?) {
        selectedThreadID = id
        settings[ChatKeys.lastThreadID] = id
        if let id {
            ensureMessagesLoaded(for: id)
        }
    }

    public func renameThread(_ id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].title = trimmed
        threads[idx].updatedAt = Date()
        let updated = threads[idx]
        sortThreads()
        persistThread(updated)
    }

    public func togglePinThread(_ id: String) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].isPinned.toggle()
        let updated = threads[idx]
        sortThreads()
        persistThread(updated)
    }

    public func updateThread(
        _ id: String,
        providerKind: AIProviderKind? = nil,
        model: String? = nil,
        workspacePath: String? = nil,
        permissionMode: ChatPermissionMode? = nil
    ) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        var switchedProvider = false
        if let providerKind, threads[idx].providerKind != providerKind {
            threads[idx].providerKind = providerKind
            // 切换底层 CLI 提供者后清空远端 session ID，下一轮自动带最近上下文续聊。
            threads[idx].remoteSessionID = nil
            switchedProvider = true
            changed = true
        }
        if let model {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if threads[idx].model != trimmed {
                threads[idx].model = trimmed
                changed = true
            }
            setPreferredModel(trimmed, for: threads[idx].providerKind)
        } else if switchedProvider {
            let nextModel = preferredModel(for: threads[idx].providerKind)
            if threads[idx].model != nextModel {
                threads[idx].model = nextModel
                changed = true
            }
        }
        if let workspacePath, !workspacePath.isEmpty, threads[idx].workspacePath != workspacePath {
            threads[idx].workspacePath = workspacePath
            defaultWorkspacePath = workspacePath
            changed = true
        }
        if let permissionMode, threads[idx].permissionMode != permissionMode {
            threads[idx].permissionMode = permissionMode
            changed = true
        }
        guard changed else { return }
        threads[idx].updatedAt = Date()
        let updated = threads[idx]
        sortThreads()
        persistThread(updated)
    }

    public func deleteThread(_ id: String) {
        stopGeneration(threadID: id)
        threads.removeAll { $0.id == id }
        messagesByThread.removeValue(forKey: id)
        loadedMessageThreadIDs.remove(id)
        try? database.pool.write { db in
            try db.execute(sql: "DELETE FROM chatThread WHERE id = ?", arguments: [id])
        }
        if selectedThreadID == id {
            let nextID = threads.first?.id
            selectThread(nextID)
        }
    }

    // MARK: - 功能卡片与快捷动作

    @discardableResult
    public func insertCards(_ cards: [ChatCardAttachment], into threadID: String? = nil) -> String {
        guard !cards.isEmpty else { return threadID ?? selectedThreadID ?? "" }
        let targetThread: ChatThread
        if let tid = threadID ?? selectedThreadID, let existing = threads.first(where: { $0.id == tid }) {
            targetThread = existing
            ensureMessagesLoaded(for: existing.id)
        } else {
            let title = cards.count == 1 ? "\(cards[0].label)卡片" : "今日功能卡片"
            targetThread = createThread(title: title)
        }

        let summary = cards.count == 1 ? "已插入功能卡片：\(cards[0].label)" : "已插入 \(cards.count) 张今日功能卡片"
        let message = ChatMessage(
            threadID: targetThread.id,
            role: .card,
            content: summary,
            status: .completed,
            cards: cards
        )
        appendMessage(message, to: targetThread.id)
        return targetThread.id
    }

    public func recordPluginActionTurn(
        userText: String,
        card: ChatCardAttachment,
        replyText: String,
        into threadID: String? = nil
    ) {
        let targetThread: ChatThread
        if let tid = threadID ?? selectedThreadID, let existing = threads.first(where: { $0.id == tid }) {
            targetThread = existing
            ensureMessagesLoaded(for: existing.id)
        } else {
            targetThread = createThread(title: Self.makeTitle(from: userText))
        }

        let userMsg = ChatMessage(
            threadID: targetThread.id,
            role: .user,
            content: userText,
            status: .completed
        )
        let replyMsg = ChatMessage(
            threadID: targetThread.id,
            role: .assistant,
            content: replyText,
            status: card.isError ? .failed : .completed,
            cards: [card],
            errorMessage: card.isError ? replyText : nil
        )
        appendMessage(userMsg, to: targetThread.id)
        appendMessage(replyMsg, to: targetThread.id)
    }

    // MARK: - 发送消息与流式执行

    public func runPluginIntentTurn(
        _ rawText: String,
        attachedCards: [ChatCardAttachment] = [],
        providerKind: AIProviderKind,
        model: String = "",
        workspacePath: String,
        permissionMode: ChatPermissionMode,
        in explicitThreadID: String? = nil,
        executor: @escaping @MainActor (@escaping @MainActor (ChatActivityItem) -> Void) async -> ChatPluginExecutionResult
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let thread = resolveOrCreateThread(
            titleSeed: text,
            providerKind: providerKind,
            model: model,
            workspacePath: workspacePath,
            permissionMode: permissionMode,
            in: explicitThreadID
        )
        guard !runningThreadIDs.contains(thread.id) else { return }

        let userMessage = ChatMessage(
            threadID: thread.id,
            role: .user,
            content: text,
            status: .completed,
            cards: attachedCards
        )
        appendMessage(userMessage, to: thread.id)

        let assistantMessage = ChatMessage(
            threadID: thread.id,
            role: .assistant,
            content: "",
            status: .streaming,
            providerKind: nil,
            modelName: "工作台规则"
        )
        appendMessage(assistantMessage, to: thread.id)

        let threadID = thread.id
        let messageID = assistantMessage.id
        runningThreadIDs.insert(threadID)

        let runState = ActiveRun()
        runState.workingMessage = assistantMessage
        activeRuns[threadID] = runState
        let startedAt = Date()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await executor { [weak self] activity in
                self?.handlePluginProgress(activity, threadID: threadID, messageID: messageID)
            }
            self.finalizePluginRun(
                threadID: threadID,
                messageID: messageID,
                result: result,
                duration: Date().timeIntervalSince(startedAt)
            )
        }
        runState.task = task
    }

    public func sendMessage(
        _ rawText: String,
        attachedCards: [ChatCardAttachment] = [],
        providerKind: AIProviderKind,
        model: String = "",
        workspacePath: String,
        permissionMode: ChatPermissionMode,
        in explicitThreadID: String? = nil
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let thread = resolveOrCreateThread(
            titleSeed: text,
            providerKind: providerKind,
            model: model,
            workspacePath: workspacePath,
            permissionMode: permissionMode,
            in: explicitThreadID
        )

        guard !runningThreadIDs.contains(thread.id) else { return }

        let priorMessages = messagesByThread[thread.id] ?? []
        var workbenchPreamble: String?
        if workbenchBridgeEnabled, thread.remoteSessionID == nil,
           let cliURL = try? WorkbenchBridgeCLI.ensureInstalled() {
            workbenchPreamble = WorkbenchBridgeCLI.promptPreamble(
                cliPath: cliURL.path,
                databasePath: database.path,
                permissionMode: permissionMode
            )
        }
        let promptToSend = Self.composePrompt(
            userText: text,
            attachedCards: attachedCards,
            priorMessages: priorMessages,
            hasRemoteSession: thread.remoteSessionID != nil,
            workbenchPreamble: workbenchPreamble
        )

        let userMessage = ChatMessage(
            threadID: thread.id,
            role: .user,
            content: text,
            status: .completed,
            cards: attachedCards
        )
        appendMessage(userMessage, to: thread.id)

        var config = providers.config(providerKind)
        if !thread.model.isEmpty {
            config.model = thread.model
        }
        let resolvedModelLabel = providers.modelDisplayName(id: config.model, for: providerKind)
            ?? (config.model.isEmpty ? nil : config.model)
        let assistantMessage = ChatMessage(
            threadID: thread.id,
            role: .assistant,
            content: "",
            status: .streaming,
            providerKind: providerKind,
            modelName: resolvedModelLabel
        )
        appendMessage(assistantMessage, to: thread.id)

        let threadID = thread.id
        let messageID = assistantMessage.id
        let resumeID = thread.remoteSessionID
        let workspaceURL = URL(fileURLWithPath: thread.workspacePath, isDirectory: true)

        runningThreadIDs.insert(threadID)

        let runState = ActiveRun()
        runState.workingMessage = assistantMessage
        activeRuns[threadID] = runState

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await AIChatRunner.stream(
                    config: config,
                    prompt: promptToSend,
                    workspaceURL: workspaceURL,
                    permissionMode: permissionMode,
                    resumeSessionID: resumeID,
                    onHandle: { handle in
                        Task { @MainActor [weak self] in
                            self?.activeRuns[threadID]?.handle = handle
                        }
                    },
                    onEvent: { event, rawLine in
                        Task { @MainActor [weak self] in
                            self?.handleStreamEvent(
                                event,
                                rawLine: rawLine,
                                threadID: threadID,
                                messageID: messageID
                            )
                        }
                    }
                )
                await MainActor.run {
                    self.finalizeRun(
                        threadID: threadID,
                        messageID: messageID,
                        result: result
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.markCancelled(threadID: threadID, messageID: messageID)
                }
            } catch {
                await MainActor.run {
                    self.markFailed(
                        threadID: threadID,
                        messageID: messageID,
                        errorText: error.localizedDescription
                    )
                }
            }
        }
        runState.task = task
    }

    public func stopGeneration(threadID: String) {
        ensureMessagesLoaded(for: threadID)
        guard let run = activeRuns[threadID] else { return }
        run.uiFlushTask?.cancel()
        run.uiFlushTask = nil
        if let working = run.workingMessage,
           let idx = messagesByThread[threadID]?.firstIndex(where: { $0.id == working.id }) {
            messagesByThread[threadID]?[idx] = working
        }
        run.handle?.cancel()
        run.task?.cancel()
        activeRuns.removeValue(forKey: threadID)
        runningThreadIDs.remove(threadID)

        if let messages = messagesByThread[threadID],
           let lastStreaming = messages.last(where: { $0.role == .assistant && $0.status == .streaming }) {
            markCancelled(threadID: threadID, messageID: lastStreaming.id)
        }
    }

    public func retryMessage(_ assistantMessageID: String, in threadID: String) {
        guard !runningThreadIDs.contains(threadID),
              let thread = threads.first(where: { $0.id == threadID }) else { return }
        ensureMessagesLoaded(for: threadID)
        guard let messages = messagesByThread[threadID],
              let targetIdx = messages.firstIndex(where: { $0.id == assistantMessageID }) else { return }

        guard let userMsg = messages[..<targetIdx].last(where: { $0.role == .user }) else { return }
        sendMessage(
            userMsg.content,
            attachedCards: userMsg.cards,
            providerKind: thread.providerKind,
            model: thread.model,
            workspacePath: thread.workspacePath,
            permissionMode: thread.permissionMode,
            in: threadID
        )
    }

    // MARK: - 流式事件处理

    private func flushWorkingMessageToUI(threadID: String, messageID: String) {
        guard let runState = activeRuns[threadID] else { return }
        runState.uiFlushTask?.cancel()
        runState.uiFlushTask = nil
        guard let working = runState.workingMessage,
              let msgIndex = messagesByThread[threadID]?.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        runState.lastUIFlushedAt = Date()
        messagesByThread[threadID]?[msgIndex] = working
    }

    private func handleStreamEvent(
        _ event: AIChatStreamEvent?,
        rawLine: String,
        threadID: String,
        messageID: String
    ) {
        guard let msgIndex = messagesByThread[threadID]?.firstIndex(where: { $0.id == messageID }) else { return }
        let runState = activeRuns[threadID]
        guard var msg = runState?.workingMessage ?? messagesByThread[threadID]?[msgIndex] else { return }

        if !rawLine.isEmpty {
            msg.rawEvents.append(rawLine)
            if msg.rawEvents.count > 160 {
                msg.rawEvents.removeFirst(msg.rawEvents.count - 160)
            }
        }

        var isImmediateUIEvent = false
        if let event {
            switch event {
            case .sessionStarted(let sessionID, _):
                isImmediateUIEvent = true
                if let tIdx = threads.firstIndex(where: { $0.id == threadID }) {
                    threads[tIdx].remoteSessionID = sessionID
                    persistThread(threads[tIdx])
                }

            case .textDelta(let delta):
                if runState?.sawActivitySinceText == true,
                   !msg.content.isEmpty,
                   !msg.content.hasSuffix("\n") {
                    msg.content += "\n\n"
                }
                runState?.sawActivitySinceText = false
                msg.content += delta

            case .textSnapshot(let itemID, let text, _):
                if let runState {
                    if let previousID = runState.activeCodexTextItemID,
                       previousID != itemID {
                        let prevText = runState.codexTexts[previousID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !prevText.isEmpty {
                            let noteItem = ChatActivityItem(
                                id: "codex-note-\(previousID)",
                                kind: .note,
                                title: "阶段说明",
                                outputText: prevText,
                                status: .completed,
                                finishedAt: Date()
                            )
                            upsertActivity(noteItem, into: &msg.activities)
                        }
                    }
                    runState.activeCodexTextItemID = itemID
                    runState.codexTexts[itemID] = text
                }
                msg.content = text

            case .activityUpsert(let item):
                if !msg.content.isEmpty {
                    runState?.sawActivitySinceText = true
                }
                upsertActivity(item, into: &msg.activities)

            case .completed(let duration, let usage, let finalText):
                isImmediateUIEvent = true
                if msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let finalText, !finalText.isEmpty {
                    msg.content = finalText
                }
                if let duration { msg.durationSeconds = duration }
                if let usage { msg.usage = usage }
                markActivitiesFinished(&msg.activities, succeeded: true)
                msg.status = .completed

            case .failed(let errorMsg):
                isImmediateUIEvent = true
                msg.errorMessage = errorMsg
                markActivitiesFinished(&msg.activities, succeeded: false)
                msg.status = .failed
            }
        }

        let now = Date()
        msg.updatedAt = now
        runState?.workingMessage = msg

        // 对高频流式增量以 ~30fps（32ms）节流合并写回 @Observable 数组，降低 SwiftUI 重排与 Markdown 重解析频率。
        if let runState, msg.status == .streaming, !isImmediateUIEvent {
            let elapsed = now.timeIntervalSince(runState.lastUIFlushedAt)
            let uiInterval: TimeInterval = 0.032
            if elapsed >= uiInterval {
                runState.uiFlushTask?.cancel()
                runState.uiFlushTask = nil
                runState.lastUIFlushedAt = now
                messagesByThread[threadID]?[msgIndex] = msg
            } else if runState.uiFlushTask == nil {
                let remainingMs = max(1, Int(((uiInterval - elapsed) * 1000).rounded(.up)))
                runState.uiFlushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(remainingMs))
                    guard !Task.isCancelled else { return }
                    self?.flushWorkingMessageToUI(threadID: threadID, messageID: messageID)
                }
            }
        } else {
            runState?.uiFlushTask?.cancel()
            runState?.uiFlushTask = nil
            runState?.lastUIFlushedAt = now
            messagesByThread[threadID]?[msgIndex] = msg
        }

        if msg.status != .streaming {
            runState?.lastPersistedAt = now
            persistMessage(msg)
        } else if now.timeIntervalSince(runState?.lastPersistedAt ?? .distantPast) >= 0.8 {
            runState?.lastPersistedAt = now
            persistStreamingCheckpointAsync(msg)
        }
    }

    private func finalizeRun(threadID: String, messageID: String, result: ShellStreamResult) {
        flushWorkingMessageToUI(threadID: threadID, messageID: messageID)
        activeRuns.removeValue(forKey: threadID)?.uiFlushTask?.cancel()
        runningThreadIDs.remove(threadID)

        guard let msgIndex = messagesByThread[threadID]?.firstIndex(where: { $0.id == messageID }),
              var msg = messagesByThread[threadID]?[msgIndex] else { return }

        if result.wasCancelled {
            if msg.status == .streaming {
                msg.status = .cancelled
                if msg.content.isEmpty && msg.activities.isEmpty {
                    msg.errorMessage = "已停止生成。"
                }
            }
            markActivitiesFinished(&msg.activities, succeeded: false)
        } else if msg.status == .failed {
            markActivitiesFinished(&msg.activities, succeeded: false)
        } else if result.status != 0 {
            msg.status = .failed
            if msg.errorMessage == nil {
                let tail = result.stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
                msg.errorMessage = tail.isEmpty ? "CLI 返回退出码 \(result.status)" : tail
            }
            markActivitiesFinished(&msg.activities, succeeded: false)
        } else {
            msg.status = .completed
            markActivitiesFinished(&msg.activities, succeeded: true)
        }

        if msg.durationSeconds == nil {
            msg.durationSeconds = result.duration
        }
        msg.updatedAt = Date()
        messagesByThread[threadID]?[msgIndex] = msg
        persistMessage(msg)

        if let tIdx = threads.firstIndex(where: { $0.id == threadID }) {
            threads[tIdx].updatedAt = Date()
            let updated = threads[tIdx]
            sortThreads()
            persistThread(updated)
        }
        onTurnCompleted?()
    }

    private func markCancelled(threadID: String, messageID: String) {
        flushWorkingMessageToUI(threadID: threadID, messageID: messageID)
        activeRuns.removeValue(forKey: threadID)?.uiFlushTask?.cancel()
        runningThreadIDs.remove(threadID)
        guard let msgIndex = messagesByThread[threadID]?.firstIndex(where: { $0.id == messageID }),
              var msg = messagesByThread[threadID]?[msgIndex] else { return }
        guard msg.status == .streaming else { return }
        msg.status = .cancelled
        if msg.content.isEmpty && msg.activities.isEmpty {
            msg.errorMessage = "已停止生成。"
        }
        markActivitiesFinished(&msg.activities, succeeded: false)
        msg.updatedAt = Date()
        messagesByThread[threadID]?[msgIndex] = msg
        persistMessage(msg)
    }

    private func markFailed(threadID: String, messageID: String, errorText: String) {
        flushWorkingMessageToUI(threadID: threadID, messageID: messageID)
        activeRuns.removeValue(forKey: threadID)?.uiFlushTask?.cancel()
        runningThreadIDs.remove(threadID)
        guard let msgIndex = messagesByThread[threadID]?.firstIndex(where: { $0.id == messageID }),
              var msg = messagesByThread[threadID]?[msgIndex] else { return }
        msg.status = .failed
        msg.errorMessage = errorText
        markActivitiesFinished(&msg.activities, succeeded: false)
        msg.updatedAt = Date()
        messagesByThread[threadID]?[msgIndex] = msg
        persistMessage(msg)
    }

    private func resolveOrCreateThread(
        titleSeed: String,
        providerKind: AIProviderKind,
        model: String,
        workspacePath: String,
        permissionMode: ChatPermissionMode,
        in explicitThreadID: String?
    ) -> ChatThread {
        if let tid = explicitThreadID ?? selectedThreadID,
           let existing = threads.first(where: { $0.id == tid }) {
            ensureMessagesLoaded(for: existing.id)
            var thread = existing
            if thread.providerKind != providerKind || thread.model != model || thread.workspacePath != workspacePath || thread.permissionMode != permissionMode {
                updateThread(tid, providerKind: providerKind, model: model, workspacePath: workspacePath, permissionMode: permissionMode)
                thread = threads.first(where: { $0.id == tid }) ?? thread
            }
            if (messagesByThread[thread.id] ?? []).isEmpty || thread.title == "新对话" {
                renameThread(thread.id, title: Self.makeTitle(from: titleSeed))
                thread = threads.first(where: { $0.id == tid }) ?? thread
            }
            return thread
        }
        return createThread(
            title: Self.makeTitle(from: titleSeed),
            providerKind: providerKind,
            model: model,
            workspacePath: workspacePath,
            permissionMode: permissionMode
        )
    }

    private func handlePluginProgress(
        _ activity: ChatActivityItem,
        threadID: String,
        messageID: String
    ) {
        guard let msgIndex = messagesByThread[threadID]?.firstIndex(where: { $0.id == messageID }),
              var msg = messagesByThread[threadID]?[msgIndex] else { return }
        upsertActivity(activity, into: &msg.activities)
        msg.updatedAt = Date()
        messagesByThread[threadID]?[msgIndex] = msg
    }

    private func finalizePluginRun(
        threadID: String,
        messageID: String,
        result: ChatPluginExecutionResult,
        duration: TimeInterval
    ) {
        activeRuns.removeValue(forKey: threadID)
        runningThreadIDs.remove(threadID)

        guard let msgIndex = messagesByThread[threadID]?.firstIndex(where: { $0.id == messageID }),
              var msg = messagesByThread[threadID]?[msgIndex] else { return }

        for item in result.activities {
            upsertActivity(item, into: &msg.activities)
        }
        markActivitiesFinished(&msg.activities, succeeded: !result.isError)
        msg.content = result.replyText
        msg.cards = result.cards
        msg.durationSeconds = duration
        msg.status = result.isError ? .failed : .completed
        if result.isError {
            msg.errorMessage = result.replyText
        }
        msg.updatedAt = Date()
        messagesByThread[threadID]?[msgIndex] = msg
        persistMessage(msg)

        if let tIdx = threads.firstIndex(where: { $0.id == threadID }) {
            threads[tIdx].updatedAt = Date()
            let updated = threads[tIdx]
            sortThreads()
            persistThread(updated)
        }
        onTurnCompleted?()
    }

    // MARK: - 内部辅助

    private func upsertActivity(_ item: ChatActivityItem, into list: inout [ChatActivityItem]) {
        if let idx = list.firstIndex(where: { $0.id == item.id }) {
            list[idx].merge(with: item)
        } else {
            list.append(item)
        }
    }

    private func markActivitiesFinished(_ list: inout [ChatActivityItem], succeeded: Bool) {
        let now = Date()
        for i in list.indices where list[i].status == .running {
            list[i].status = succeeded ? .completed : .failed
            list[i].finishedAt = now
        }
    }

    private func appendMessage(_ message: ChatMessage, to threadID: String) {
        ensureMessagesLoaded(for: threadID)
        messagesByThread[threadID, default: []].append(message)
        persistMessage(message)
        if let idx = threads.firstIndex(where: { $0.id == threadID }) {
            threads[idx].updatedAt = Date()
            let updated = threads[idx]
            sortThreads()
            persistThread(updated)
        }
    }

    private func sortThreads() {
        threads.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func persistThread(_ thread: ChatThread) {
        let row = ChatThreadRow(from: thread)
        try? database.pool.write { db in
            try row.save(db)
        }
    }

    private func persistMessage(_ message: ChatMessage) {
        let row = ChatMessageRow(from: message)
        try? database.pool.write { db in
            try row.save(db)
        }
    }

    private func persistStreamingCheckpointAsync(_ message: ChatMessage) {
        let row = ChatMessageRow(from: message)
        let db = database
        Task.detached(priority: .utility) {
            // 仅在仍处于 streaming 状态时落盘中间态，避免覆盖终态记录。
            try? db.pool.write { dbConn in
                try dbConn.execute(
                    sql: """
                    UPDATE chatMessage
                    SET content = ?, usageJSON = ?, activitiesJSON = ?, rawEventsJSON = ?, updatedAt = ?
                    WHERE id = ? AND status = 'streaming'
                    """,
                    arguments: [
                        row.content,
                        row.usageJSON,
                        row.activitiesJSON,
                        row.rawEventsJSON,
                        row.updatedAt,
                        row.id
                    ]
                )
            }
        }
    }

    private static func makeTitle(from text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 26 else { return singleLine.isEmpty ? "新对话" : singleLine }
        return String(singleLine.prefix(26)) + "…"
    }

    static func composePrompt(
        userText: String,
        attachedCards: [ChatCardAttachment],
        priorMessages: [ChatMessage],
        hasRemoteSession: Bool,
        workbenchPreamble: String? = nil
    ) -> String {
        var sections: [String] = []

        if !hasRemoteSession, let workbenchPreamble, !workbenchPreamble.isEmpty {
            sections.append(workbenchPreamble)
        }

        if !hasRemoteSession {
            let history = priorMessages
                .filter { $0.role == .user || $0.role == .assistant }
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .suffix(6)
            if !history.isEmpty {
                var block = "[之前对话上下文]"
                for msg in history {
                    let speaker = msg.role == .user ? "用户" : "助手"
                    let body = msg.content.count > 600 ? String(msg.content.prefix(600)) + "…" : msg.content
                    block += "\n\(speaker)：\(body)"
                }
                sections.append(block)
            }
        }

        if !attachedCards.isEmpty {
            var block = "[工作台当前卡片信息]"
            for card in attachedCards {
                let detail = card.detailSnapshot.map { "（\($0)）" } ?? ""
                block += "\n- \(card.label)：\(card.valueSnapshot)\(detail)"
            }
            sections.append(block)
        }

        if sections.isEmpty {
            return userText
        }
        sections.append(userText)
        return sections.joined(separator: "\n\n")
    }
}

private final class ActiveRun {
    var task: Task<Void, Never>?
    var handle: ShellProcessHandle?
    var workingMessage: ChatMessage?
    var uiFlushTask: Task<Void, Never>?
    var lastUIFlushedAt: Date = .distantPast
    var lastPersistedAt: Date = .distantPast
    var sawActivitySinceText = false
    var activeCodexTextItemID: String?
    var codexTexts: [String: String] = [:]
}

// MARK: - GRDB 映射行

private nonisolated struct ChatThreadRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chatThread"

    var id: String
    var title: String
    var providerKind: String
    var model: String
    var workspacePath: String
    var permissionMode: String
    var remoteSessionID: String?
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(from thread: ChatThread) {
        id = thread.id
        title = thread.title
        providerKind = thread.providerKind.rawValue
        model = thread.model
        workspacePath = thread.workspacePath
        permissionMode = thread.permissionMode.rawValue
        remoteSessionID = thread.remoteSessionID
        isPinned = thread.isPinned
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
    }

    func toThread() -> ChatThread {
        ChatThread(
            id: id,
            title: title,
            providerKind: AIProviderKind(rawValue: providerKind) ?? .agy,
            model: model,
            workspacePath: workspacePath,
            permissionMode: ChatPermissionMode(rawValue: permissionMode) ?? .agent,
            remoteSessionID: remoteSessionID,
            isPinned: isPinned,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private nonisolated struct ChatMessageRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chatMessage"

    var id: String
    var threadID: String
    var role: String
    var content: String
    var status: String
    var providerKind: String?
    var modelName: String?
    var durationSeconds: Double?
    var usageJSON: String?
    var activitiesJSON: String
    var rawEventsJSON: String
    var cardsJSON: String
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    init(from msg: ChatMessage) {
        let encoder = JSONEncoder()
        id = msg.id
        threadID = msg.threadID
        role = msg.role.rawValue
        content = msg.content
        status = msg.status.rawValue
        providerKind = msg.providerKind?.rawValue
        modelName = msg.modelName
        durationSeconds = msg.durationSeconds
        usageJSON = msg.usage.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        activitiesJSON = (try? encoder.encode(msg.activities)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        rawEventsJSON = (try? encoder.encode(msg.rawEvents)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        cardsJSON = (try? encoder.encode(msg.cards)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        errorMessage = msg.errorMessage
        createdAt = msg.createdAt
        updatedAt = msg.updatedAt
    }

    func toMessage() -> ChatMessage {
        let decoder = JSONDecoder()
        let usage = usageJSON?.data(using: .utf8).flatMap { try? decoder.decode(ChatTokenUsage.self, from: $0) }
        let activities = (activitiesJSON.data(using: .utf8).flatMap { try? decoder.decode([ChatActivityItem].self, from: $0) }) ?? []
        let rawEvents = (rawEventsJSON.data(using: .utf8).flatMap { try? decoder.decode([String].self, from: $0) }) ?? []
        let cards = (cardsJSON.data(using: .utf8).flatMap { try? decoder.decode([ChatCardAttachment].self, from: $0) }) ?? []
        return ChatMessage(
            id: id,
            threadID: threadID,
            role: ChatMessageRole(rawValue: role) ?? .assistant,
            content: content,
            status: ChatMessageStatus(rawValue: status) ?? .completed,
            providerKind: providerKind.flatMap(AIProviderKind.init(rawValue:)),
            modelName: modelName,
            durationSeconds: durationSeconds,
            usage: usage,
            activities: activities,
            rawEvents: rawEvents,
            cards: cards,
            errorMessage: errorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
