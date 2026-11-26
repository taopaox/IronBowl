import Foundation
import Testing
@testable import IronBowlKit

@Test func parsesAgyStreamEvents() throws {
    let warnLines = AIChatStreamParser.parseLine("warning: non-json output", provider: .agy)
    #expect(warnLines.isEmpty)

    let initLine = #"{"event":"init","conversation_id":"conv-123","init":{"cwd":"/tmp/demo"}}"#
    #expect(AIChatStreamParser.parseLine(initLine, provider: .agy) == [
        .sessionStarted(sessionID: "conv-123", cwd: "/tmp/demo")
    ])

    let thinkDone = #"{"event":"step_update","step_update":{"step_index":1,"state":"DONE","step_type":"agent_response","duration_seconds":1.5,"usage":{"input_tokens":100,"output_tokens":20,"thinking_tokens":45,"total_tokens":120}}}"#
    let thinkEvents = AIChatStreamParser.parseLine(thinkDone, provider: .agy)
    #expect(thinkEvents.count == 1)
    if case .activityUpsert(let item) = thinkEvents[0] {
        #expect(item.kind == .thinking)
        #expect(item.subtitle == "45 tokens")
        #expect(item.status == .completed)
    } else {
        Issue.record("Expected thinking activityUpsert")
    }

    let toolDone = #"{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.4,"tool_info":{"name":"run_command","parameters":{"CommandLine":"ls -la"},"output":"Command exited with code 1.\nNo such file"}}}"#
    let toolEvents = AIChatStreamParser.parseLine(toolDone, provider: .agy)
    #expect(toolEvents.count == 1)
    if case .activityUpsert(let item) = toolEvents[0] {
        #expect(item.id == "agy-step-2")
        #expect(item.kind == .command)
        #expect(item.subtitle == "ls -la")
        #expect(item.exitCode == 1)
        #expect(item.status == .failed)
    } else {
        Issue.record("Expected command activityUpsert")
    }

    let deltaLine = #"{"event":"step_update","step_update":{"step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"你好"}}"#
    #expect(AIChatStreamParser.parseLine(deltaLine, provider: .agy) == [.textDelta("你好")])

    let resultLine = #"{"event":"result","result":{"conversation_id":"conv-123","status":"SUCCESS","response":"你好世界","duration_seconds":2.5,"usage":{"input_tokens":200,"output_tokens":50,"thinking_tokens":45,"cache_read_tokens":100,"total_tokens":250}}}"#
    let resultEvents = AIChatStreamParser.parseLine(resultLine, provider: .agy)
    #expect(resultEvents == [
        .completed(
            durationSeconds: 2.5,
            usage: ChatTokenUsage(
                inputTokens: 200,
                outputTokens: 50,
                thinkingTokens: 45,
                cachedInputTokens: 100,
                totalTokens: 250
            ),
            finalText: "你好世界"
        )
    ])

    let failLine = #"{"event":"result","result":{"status":"ERROR","response":"quota exceeded"}}"#
    #expect(AIChatStreamParser.parseLine(failLine, provider: .agy) == [.failed("quota exceeded")])
}

@Test func parsesCodexStreamEvents() throws {
    let startLine = #"{"type":"thread.started","thread_id":"thread-abc"}"#
    #expect(AIChatStreamParser.parseLine(startLine, provider: .codex) == [
        .sessionStarted(sessionID: "thread-abc", cwd: nil)
    ])

    let reasonLine = #"{"type":"item.completed","item":{"id":"item_r","type":"reasoning","text":"Checking repo layout"}}"#
    if case .activityUpsert(let item) = AIChatStreamParser.parseLine(reasonLine, provider: .codex).first {
        #expect(item.id == "codex-item_r")
        #expect(item.kind == .thinking)
        #expect(item.outputText == "Checking repo layout")
        #expect(item.status == .completed)
    } else {
        Issue.record("Expected reasoning activity")
    }

    let cmdStart = #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"pwd","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#
    if case .activityUpsert(let item) = AIChatStreamParser.parseLine(cmdStart, provider: .codex).first {
        #expect(item.status == .running)
        #expect(item.subtitle == "pwd")
    } else {
        Issue.record("Expected running command")
    }

    let cmdFail = #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"false","aggregated_output":"boom","exit_code":1,"status":"completed"}}"#
    if case .activityUpsert(let item) = AIChatStreamParser.parseLine(cmdFail, provider: .codex).first {
        #expect(item.status == .failed)
        #expect(item.exitCode == 1)
        #expect(item.outputText == "boom")
    } else {
        Issue.record("Expected failed command")
    }

    let fileLine = #"{"type":"item.completed","item":{"id":"item_f","type":"file_change","changes":[{"path":"README.md","kind":"modify"}],"status":"completed"}}"#
    if case .activityUpsert(let item) = AIChatStreamParser.parseLine(fileLine, provider: .codex).first {
        #expect(item.kind == .fileChange)
        #expect(item.subtitle == "README.md")
        #expect(item.outputText == "[modify] README.md")
    } else {
        Issue.record("Expected fileChange activity")
    }

    let msgLine = #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Done"}}"#
    #expect(AIChatStreamParser.parseLine(msgLine, provider: .codex) == [
        .textSnapshot(itemID: "item_2", text: "Done", isFinal: true)
    ])

    let turnDone = #"{"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":200,"output_tokens":30,"reasoning_output_tokens":10}}"#
    #expect(AIChatStreamParser.parseLine(turnDone, provider: .codex) == [
        .completed(
            durationSeconds: nil,
            usage: ChatTokenUsage(
                inputTokens: 500,
                outputTokens: 30,
                thinkingTokens: 10,
                cachedInputTokens: 200,
                totalTokens: 530
            ),
            finalText: nil
        )
    ])

    let turnFail = #"{"type":"turn.failed","error":{"message":"network timeout"}}"#
    #expect(AIChatStreamParser.parseLine(turnFail, provider: .codex) == [.failed("network timeout")])
}

@Test func buildsRunnerArgumentsForAgyAndCodex() {
    var agyConfig = AIProviderConfig(kind: .agy)
    agyConfig.model = "gemini-pro"
    agyConfig.effort = "medium"

    let agyNew = AIChatRunner.buildArguments(
        config: agyConfig,
        prompt: "hi",
        workspacePath: "/tmp/proj",
        permissionMode: .agent,
        resumeSessionID: nil
    )
    #expect(!agyNew.contains("--mode"))
    #expect(agyNew.contains("--dangerously-skip-permissions"))
    #expect(agyNew.contains("--output-format"))
    #expect(agyNew.contains("stream-json"))
    #expect(!agyNew.contains("--resume"))

    let agyResumeReadOnly = AIChatRunner.buildArguments(
        config: agyConfig,
        prompt: "next",
        workspacePath: "/tmp/proj",
        permissionMode: .readOnly,
        resumeSessionID: "conv-99"
    )
    #expect(agyResumeReadOnly.starts(with: ["--resume", "conv-99"]))
    #expect(agyResumeReadOnly.contains("--sandbox"))
    #expect(!agyResumeReadOnly.contains("--dangerously-skip-permissions"))

    var codexConfig = AIProviderConfig(kind: .codex)
    codexConfig.model = "o3"
    codexConfig.effort = "high"

    let codexNew = AIChatRunner.buildArguments(
        config: codexConfig,
        prompt: "inspect",
        workspacePath: "/tmp/proj",
        permissionMode: .agent,
        resumeSessionID: nil
    )
    #expect(codexNew.starts(with: ["exec", "--skip-git-repo-check", "-s", "workspace-write"]))
    #expect(codexNew.contains("-C"))
    #expect(codexNew.contains("/tmp/proj"))
    #expect(codexNew.contains("--json"))
    #expect(codexNew.last == "inspect")

    let codexResume = AIChatRunner.buildArguments(
        config: codexConfig,
        prompt: "follow up",
        workspacePath: "/tmp/proj",
        permissionMode: .readOnly,
        resumeSessionID: "thread-42"
    )
    #expect(codexResume.starts(with: ["exec", "resume", "--skip-git-repo-check", "--json"]))
    #expect(!codexResume.contains("-s"))
    #expect(!codexResume.contains("-C"))
    #expect(codexResume.contains(#"sandbox_mode="read-only""#))
    #expect(codexResume.contains(#"approval_policy="never""#))
    #expect(codexResume.suffix(2) == ["thread-42", "follow up"])
}

@Test @MainActor func chatStorePersistsThreadsCardsAndRecoversStreaming() throws {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "ironbowl-chat-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let dbURL = dir.appending(path: "test.sqlite")
    let db = try AppDatabase(url: dbURL, migrations: [])
    let settings = SettingsStore(database: db)
    let providers = AIProviderStore(settings: settings)
    let store = ChatStore(database: db, settings: settings, providers: providers)

    let thread = store.createThread(
        title: "测试对话",
        providerKind: .agy,
        workspacePath: dir.path,
        permissionMode: .agent
    )
    #expect(store.threads.count == 1)
    #expect(store.selectedThreadID == thread.id)

    store.togglePinThread(thread.id)
    store.renameThread(thread.id, title: "置顶对话")
    #expect(store.threads.first?.isPinned == true)
    #expect(store.threads.first?.title == "置顶对话")

    let card = ChatCardAttachment(cardID: "core.lunar", label: "农历", valueSnapshot: "十月十七")
    let cardThreadID = store.insertCards([card], into: thread.id)
    #expect(cardThreadID == thread.id)
    #expect(store.messagesByThread[thread.id]?.count == 1)
    #expect(store.messagesByThread[thread.id]?.first?.role == .card)

    // 模拟已拿到远端 sessionID，切换 providerKind 后应自动清空。
    try db.pool.write { wdb in
        try wdb.execute(sql: "UPDATE chatThread SET remoteSessionID = 'remote-1' WHERE id = ?", arguments: [thread.id])
        try wdb.execute(
            sql: """
            INSERT INTO chatMessage(id, threadID, role, content, status, createdAt, updatedAt)
            VALUES ('stale-msg', ?, 'assistant', 'partial', 'streaming', ?, ?)
            """,
            arguments: [thread.id, Date(), Date()]
        )
    }
    store.loadThreads()
    #expect(store.threads.first?.remoteSessionID == "remote-1")
    let recovered = store.messagesByThread[thread.id]?.first { $0.id == "stale-msg" }
    #expect(recovered?.status == .cancelled)

    store.updateThread(thread.id, providerKind: .codex)
    #expect(store.threads.first?.providerKind == .codex)
    #expect(store.threads.first?.remoteSessionID == nil)

    // 对话级模型记忆与跨提供商切换隔离
    store.updateThread(thread.id, model: "gpt-6.2-sol")
    #expect(store.threads.first?.model == "gpt-6.2-sol")
    #expect(store.preferredModel(for: .codex) == "gpt-6.2-sol")

    // 重新打开数据库后确认 model 字段持久化
    let reloadedStore = ChatStore(database: db, settings: settings, providers: providers)
    #expect(reloadedStore.threads.first?.model == "gpt-6.2-sol")

    reloadedStore.updateThread(thread.id, providerKind: .agy)
    #expect(reloadedStore.threads.first?.providerKind == .agy)
    #expect(reloadedStore.threads.first?.model == "")

    reloadedStore.updateThread(thread.id, model: "gemini-4-neon-high")
    #expect(reloadedStore.preferredModel(for: .agy) == "gemini-4-neon-high")

    reloadedStore.updateThread(thread.id, providerKind: .codex)
    #expect(reloadedStore.threads.first?.model == "gpt-6.2-sol")

    reloadedStore.deleteThread(thread.id)
    #expect(reloadedStore.threads.isEmpty)
    let remainingMessages = try db.pool.read { rdb in
        try Int.fetchOne(rdb, sql: "SELECT COUNT(*) FROM chatMessage WHERE threadID = ?", arguments: [thread.id])
    }
    #expect(remainingMessages == 0)
}
