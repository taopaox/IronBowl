import Foundation

public nonisolated enum ChatPermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case agent
    case readOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agent: "代理读写"
        case .readOnly: "只读沙箱"
        }
    }

    public var shortTitle: String {
        switch self {
        case .agent: "代理读写"
        case .readOnly: "只读"
        }
    }

    public var detail: String {
        switch self {
        case .agent: "允许在选定工作目录读写文件与执行命令（T3 Code 模式）。"
        case .readOnly: "仅允许只读分析，禁止修改文件或写入工作区。"
        }
    }

    public var systemImage: String {
        switch self {
        case .agent: "terminal"
        case .readOnly: "lock.shield"
        }
    }
}

public nonisolated enum ChatOutputDetailLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case all
    case hideSuccessful
    case zen

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "全部详情"
        case .hideSuccessful: "隐藏已成功"
        case .zen: "仅最终回复"
        }
    }

    public var detail: String {
        switch self {
        case .all: "展开显示全部命令、工具调用、思考与文件改动详情。"
        case .hideSuccessful: "运行时显示进度，完成后自动折叠已成功步骤，仅保留失败项。"
        case .zen: "完成后折叠全部中间过程，仅展示最终回复与摘要徽标。"
        }
    }
}

public nonisolated struct ChatTokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var thinkingTokens: Int
    public var cachedInputTokens: Int
    public var totalTokens: Int

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        thinkingTokens: Int = 0,
        cachedInputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalTokens = totalTokens
    }

    public var summaryText: String? {
        var parts: [String] = []
        if totalTokens > 0 {
            parts.append("\(Self.compactCount(totalTokens)) tokens")
        } else if inputTokens > 0 || outputTokens > 0 {
            parts.append("入 \(Self.compactCount(inputTokens)) · 出 \(Self.compactCount(outputTokens))")
        }
        if thinkingTokens > 0 {
            parts.append("思考 \(Self.compactCount(thinkingTokens))")
        }
        if cachedInputTokens > 0 {
            parts.append("缓存 \(Self.compactCount(cachedInputTokens))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func compactCount(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000.0)
        }
        return "\(value)"
    }
}

public nonisolated enum ChatActivityKind: String, Codable, Sendable {
    case thinking
    case command
    case tool
    case fileChange
    case note
    case error

    public var label: String {
        switch self {
        case .thinking: "思考"
        case .command: "命令"
        case .tool: "工具"
        case .fileChange: "文件"
        case .note: "过程"
        case .error: "错误"
        }
    }

    public var systemImage: String {
        switch self {
        case .thinking: "brain"
        case .command: "terminal"
        case .tool: "wrench.and.screwdriver"
        case .fileChange: "doc.badge.gearshape"
        case .note: "text.bubble"
        case .error: "exclamationmark.triangle"
        }
    }
}

public nonisolated enum ChatActivityStatus: String, Codable, Sendable {
    case running
    case completed
    case failed
}

public nonisolated struct ChatActivityItem: Codable, Sendable, Identifiable, Equatable {
    public static let maxOutputCharacters = 32_768

    public var id: String
    public var kind: ChatActivityKind
    public var title: String
    public var subtitle: String?
    public var inputText: String?
    public var outputText: String?
    public var exitCode: Int?
    public var status: ChatActivityStatus
    public var durationSeconds: Double?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: String,
        kind: ChatActivityKind,
        title: String,
        subtitle: String? = nil,
        inputText: String? = nil,
        outputText: String? = nil,
        exitCode: Int? = nil,
        status: ChatActivityStatus = .running,
        durationSeconds: Double? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.inputText = inputText
        self.outputText = Self.truncatedOutput(outputText)
        self.exitCode = exitCode
        self.status = status
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public mutating func merge(with incoming: ChatActivityItem) {
        kind = incoming.kind
        if !incoming.title.isEmpty { title = incoming.title }
        if let incomingSubtitle = incoming.subtitle, !incomingSubtitle.isEmpty {
            subtitle = incomingSubtitle
        }
        if let incomingInput = incoming.inputText, !incomingInput.isEmpty {
            inputText = incomingInput
        }
        if let incomingOutput = incoming.outputText, !incomingOutput.isEmpty {
            outputText = Self.truncatedOutput(incomingOutput)
        }
        if let incomingExit = incoming.exitCode {
            exitCode = incomingExit
        }
        status = incoming.status
        if let incomingDuration = incoming.durationSeconds {
            durationSeconds = incomingDuration
        }
        if let incomingFinished = incoming.finishedAt {
            finishedAt = incomingFinished
        } else if incoming.status != .running, finishedAt == nil {
            finishedAt = Date()
        }
    }

    public static func truncatedOutput(_ text: String?) -> String? {
        guard let text else { return nil }
        guard text.count > maxOutputCharacters else { return text }
        let suffix = text.suffix(maxOutputCharacters)
        return "…（已截断早期输出，保留末尾 \(maxOutputCharacters) 字符）\n" + suffix
    }
}

public nonisolated struct ChatCardAttachment: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var cardID: String
    public var label: String
    public var valueSnapshot: String
    public var detailSnapshot: String?
    public var actionSummary: String?
    public var isError: Bool
    public var insertedAt: Date

    public init(
        id: String = UUID().uuidString,
        cardID: String,
        label: String,
        valueSnapshot: String,
        detailSnapshot: String? = nil,
        actionSummary: String? = nil,
        isError: Bool = false,
        insertedAt: Date = Date()
    ) {
        self.id = id
        self.cardID = cardID
        self.label = label
        self.valueSnapshot = valueSnapshot
        self.detailSnapshot = detailSnapshot
        self.actionSummary = actionSummary
        self.isError = isError
        self.insertedAt = insertedAt
    }
}

public nonisolated enum ChatMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case card
}

public nonisolated enum ChatMessageStatus: String, Codable, Sendable {
    case streaming
    case completed
    case failed
    case cancelled
}

public nonisolated struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var threadID: String
    public var role: ChatMessageRole
    public var content: String
    public var status: ChatMessageStatus
    public var providerKind: AIProviderKind?
    public var modelName: String?
    public var durationSeconds: Double?
    public var usage: ChatTokenUsage?
    public var activities: [ChatActivityItem]
    public var rawEvents: [String]
    public var cards: [ChatCardAttachment]
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        role: ChatMessageRole,
        content: String = "",
        status: ChatMessageStatus = .completed,
        providerKind: AIProviderKind? = nil,
        modelName: String? = nil,
        durationSeconds: Double? = nil,
        usage: ChatTokenUsage? = nil,
        activities: [ChatActivityItem] = [],
        rawEvents: [String] = [],
        cards: [ChatCardAttachment] = [],
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.content = content
        self.status = status
        self.providerKind = providerKind
        self.modelName = modelName
        self.durationSeconds = durationSeconds
        self.usage = usage
        self.activities = activities
        self.rawEvents = rawEvents
        self.cards = cards
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var hasDetails: Bool {
        !activities.isEmpty || !rawEvents.isEmpty
    }

    public var activitySummaryText: String {
        guard !activities.isEmpty else {
            return status == .streaming ? "正在准备执行…" : "查看原始事件（\(rawEvents.count) 条）"
        }
        var cmdCount = 0
        var toolCount = 0
        var fileCount = 0
        var thinkCount = 0
        var noteCount = 0
        var errCount = 0
        for item in activities {
            switch item.kind {
            case .command: cmdCount += 1
            case .tool: toolCount += 1
            case .fileChange: fileCount += 1
            case .thinking: thinkCount += 1
            case .note: noteCount += 1
            case .error: errCount += 1
            }
        }
        var parts: [String] = []
        if cmdCount > 0 { parts.append("执行 \(cmdCount) 条命令") }
        if fileCount > 0 { parts.append("改动 \(fileCount) 个文件") }
        if toolCount > 0 { parts.append("调用 \(toolCount) 个工具") }
        if thinkCount > 0 { parts.append("思考 \(thinkCount) 次") }
        if noteCount > 0 { parts.append("\(noteCount) 条过程说明") }
        if errCount > 0 { parts.append("\(errCount) 个错误") }
        return parts.joined(separator: " · ")
    }
}

public nonisolated struct ChatThread: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var providerKind: AIProviderKind
    public var workspacePath: String
    public var permissionMode: ChatPermissionMode
    public var remoteSessionID: String?
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        providerKind: AIProviderKind,
        workspacePath: String,
        permissionMode: ChatPermissionMode = .agent,
        remoteSessionID: String? = nil,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.providerKind = providerKind
        self.workspacePath = workspacePath
        self.permissionMode = permissionMode
        self.remoteSessionID = remoteSessionID
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var workspaceName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workspacePath == home { return "~" }
        let name = URL(fileURLWithPath: workspacePath).lastPathComponent
        return name.isEmpty ? workspacePath : name
    }
}

public nonisolated enum ChatKeys {
    public static let defaultWorkspace = SettingKey<String>("chat.defaultWorkspace", default: "")
    public static let detailLevel = SettingKey<ChatOutputDetailLevel>("chat.detailLevel", default: .all)
    public static let sidebarCollapsed = SettingKey<Bool>("chat.sidebarCollapsed", default: false)
    public static let lastThreadID = SettingKey<String?>("chat.lastThreadID", default: nil)
}
