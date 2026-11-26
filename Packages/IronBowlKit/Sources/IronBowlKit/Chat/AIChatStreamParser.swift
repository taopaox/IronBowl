import Foundation

public nonisolated enum AIChatStreamEvent: Sendable, Equatable {
    case sessionStarted(sessionID: String, cwd: String?)
    case textDelta(String)
    case textSnapshot(itemID: String, text: String, isFinal: Bool)
    case activityUpsert(ChatActivityItem)
    case completed(durationSeconds: Double?, usage: ChatTokenUsage?, finalText: String?)
    case failed(String)
}

/// 解析 `agy --output-format stream-json` 与 `codex exec --json` 输出的 JSONL 事件流。
public nonisolated enum AIChatStreamParser {
    public nonisolated static func parseLine(_ line: String, provider: AIProviderKind) -> [AIChatStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        switch provider {
        case .agy:
            return parseAgy(json)
        case .codex:
            return parseCodex(json)
        }
    }

    // MARK: - Antigravity (agy)

    private nonisolated static func parseAgy(_ json: [String: Any]) -> [AIChatStreamEvent] {
        guard let event = json["event"] as? String else { return [] }
        switch event {
        case "init":
            guard let sessionID = json["conversation_id"] as? String, !sessionID.isEmpty else { return [] }
            let cwd = (json["init"] as? [String: Any])?["cwd"] as? String
            return [.sessionStarted(sessionID: sessionID, cwd: cwd)]

        case "step_update":
            guard let step = json["step_update"] as? [String: Any] else { return [] }
            return parseAgyStep(step)

        case "result":
            guard let result = json["result"] as? [String: Any] else { return [] }
            let status = (result["status"] as? String ?? "").uppercased()
            let response = result["response"] as? String
            let duration = result["duration_seconds"] as? Double
            let usage = parseAgyUsage(result["usage"] as? [String: Any])
            if !status.isEmpty, status != "SUCCESS" {
                let message = response ?? (result["error"] as? String) ?? "agy 状态 \(status)"
                return [.failed(message)]
            }
            return [.completed(durationSeconds: duration, usage: usage, finalText: response)]

        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? (json["message"] as? String)
                ?? "agy 执行出错"
            return [.failed(message)]

        default:
            return []
        }
    }

    private nonisolated static func parseAgyStep(_ step: [String: Any]) -> [AIChatStreamEvent] {
        let stepIndex = (step["step_index"] as? Int) ?? (step["step_index"] as? Double).map(Int.init) ?? 0
        let state = (step["state"] as? String ?? "").uppercased()
        let stepType = step["step_type"] as? String ?? ""
        let duration = step["duration_seconds"] as? Double

        switch stepType {
        case "agent_response":
            var events: [AIChatStreamEvent] = []
            if let thinkingText = (step["thinking_delta"] as? String) ?? (step["thinking"] as? String), !thinkingText.isEmpty {
                events.append(.activityUpsert(ChatActivityItem(
                    id: "agy-think-\(stepIndex)",
                    kind: .thinking,
                    title: "思考过程",
                    outputText: thinkingText,
                    status: state == "DONE" ? .completed : .running,
                    durationSeconds: duration,
                    finishedAt: state == "DONE" ? Date() : nil
                )))
            }
            if let delta = step["text_delta"] as? String, !delta.isEmpty {
                events.append(.textDelta(delta))
            } else if state == "DONE",
                      let usage = parseAgyUsage(step["usage"] as? [String: Any]),
                      usage.thinkingTokens > 0,
                      step["text_delta"] == nil {
                events.append(.activityUpsert(ChatActivityItem(
                    id: "agy-think-\(stepIndex)",
                    kind: .thinking,
                    title: "深度思考",
                    subtitle: "\(usage.thinkingTokens) tokens",
                    status: .completed,
                    durationSeconds: duration,
                    finishedAt: Date()
                )))
            }
            return events

        case "tool":
            let toolInfo = step["tool_info"] as? [String: Any] ?? [:]
            let toolName = (step["tool_name"] as? String) ?? (toolInfo["name"] as? String) ?? "工具"
            let params = toolInfo["parameters"] as? [String: Any] ?? [:]
            let rawOutput = toolInfo["output"] as? String
            let exitCode = rawOutput.flatMap(extractExitCode(from:))

            let kind = classifyAgyTool(toolName)
            let subtitle = agyToolSubtitle(toolName: toolName, kind: kind, params: params)
            let inputText = formatAgyToolInput(kind: kind, params: params)

            let status: ChatActivityStatus
            if state == "FAILED" || state == "ERROR" {
                status = .failed
            } else if state == "DONE" {
                status = (exitCode ?? 0) == 0 ? .completed : .failed
            } else {
                status = .running
            }

            let title = agyToolTitle(toolName: toolName, kind: kind)
            return [.activityUpsert(ChatActivityItem(
                id: "agy-step-\(stepIndex)",
                kind: kind,
                title: title,
                subtitle: subtitle,
                inputText: inputText,
                outputText: rawOutput,
                exitCode: exitCode,
                status: status,
                durationSeconds: duration,
                finishedAt: status == .running ? nil : Date()
            ))]

        default:
            return []
        }
    }

    private nonisolated static func parseAgyUsage(_ dict: [String: Any]?) -> ChatTokenUsage? {
        guard let dict else { return nil }
        let input = dict["input_tokens"] as? Int ?? 0
        let output = dict["output_tokens"] as? Int ?? 0
        let thinking = dict["thinking_tokens"] as? Int ?? 0
        let cached = dict["cache_read_tokens"] as? Int ?? 0
        let total = dict["total_tokens"] as? Int ?? (input + output)
        guard input + output + thinking + cached + total > 0 else { return nil }
        return ChatTokenUsage(
            inputTokens: input,
            outputTokens: output,
            thinkingTokens: thinking,
            cachedInputTokens: cached,
            totalTokens: total
        )
    }

    private nonisolated static func classifyAgyTool(_ name: String) -> ChatActivityKind {
        let lower = name.lowercased()
        if lower == "run_command" || lower == "shell" || lower == "bash" || lower.contains("command") {
            return .command
        }
        if ["write_to_file", "write_file", "edit_file", "replace_file_content", "multi_replace_file_content", "sed_file"].contains(lower) {
            return .fileChange
        }
        return .tool
    }

    private nonisolated static func agyToolTitle(toolName: String, kind: ChatActivityKind) -> String {
        switch kind {
        case .command: "执行命令"
        case .fileChange: "编辑文件 · \(toolName)"
        default: "调用 \(toolName)"
        }
    }

    private nonisolated static func agyToolSubtitle(toolName: String, kind: ChatActivityKind, params: [String: Any]) -> String? {
        if kind == .command {
            return (params["CommandLine"] as? String)
                ?? (params["command"] as? String)
                ?? (params["cmd"] as? String)
        }
        let keys = ["Path", "path", "TargetFile", "target_file", "DirectoryPath", "SearchPath", "Query", "query", "Url", "url"]
        for key in keys {
            if let value = params[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private nonisolated static func formatAgyToolInput(kind: ChatActivityKind, params: [String: Any]) -> String? {
        guard !params.isEmpty else { return nil }
        if kind == .command, let cmd = (params["CommandLine"] as? String) ?? (params["command"] as? String) {
            return cmd
        }
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private nonisolated static func extractExitCode(from output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Command exited with code ") {
                let raw = trimmed.dropFirst("Command exited with code ".count).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                if let code = Int(raw) { return code }
            }
        }
        return nil
    }

    // MARK: - Codex

    private nonisolated static func parseCodex(_ json: [String: Any]) -> [AIChatStreamEvent] {
        guard let type = json["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            guard let threadID = json["thread_id"] as? String, !threadID.isEmpty else { return [] }
            return [.sessionStarted(sessionID: threadID, cwd: nil)]

        case "item.started", "item.updated", "item.completed":
            guard let item = json["item"] as? [String: Any] else { return [] }
            return parseCodexItem(item, eventType: type)

        case "turn.completed":
            let usageDict = json["usage"] as? [String: Any]
            let usage = parseCodexUsage(usageDict)
            return [.completed(durationSeconds: nil, usage: usage, finalText: nil)]

        case "turn.failed", "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? (json["message"] as? String)
                ?? "Codex 执行失败"
            return [.failed(message)]

        default:
            return []
        }
    }

    private nonisolated static func parseCodexItem(_ item: [String: Any], eventType: String) -> [AIChatStreamEvent] {
        let itemID = item["id"] as? String ?? UUID().uuidString
        let itemType = item["type"] as? String ?? ""
        let itemStatus = (item["status"] as? String ?? "").lowercased()
        let isCompletedEvent = eventType == "item.completed"

        switch itemType {
        case "agent_message":
            let text = item["text"] as? String ?? ""
            return [.textSnapshot(itemID: itemID, text: text, isFinal: isCompletedEvent)]

        case "reasoning":
            let text = (item["text"] as? String)
                ?? (item["summary"] as? [String])?.joined(separator: "\n")
                ?? ""
            return [.activityUpsert(ChatActivityItem(
                id: "codex-\(itemID)",
                kind: .thinking,
                title: "思考过程",
                outputText: text.isEmpty ? nil : text,
                status: isCompletedEvent ? .completed : .running,
                finishedAt: isCompletedEvent ? Date() : nil
            ))]

        case "command_execution":
            let command = item["command"] as? String ?? ""
            let output = item["aggregated_output"] as? String
            let exitCode = item["exit_code"] as? Int
            let status: ChatActivityStatus
            if itemStatus == "failed" || (exitCode != nil && exitCode != 0) {
                status = .failed
            } else if isCompletedEvent || itemStatus == "completed" {
                status = .completed
            } else {
                status = .running
            }
            return [.activityUpsert(ChatActivityItem(
                id: "codex-\(itemID)",
                kind: .command,
                title: "执行命令",
                subtitle: command.isEmpty ? nil : command,
                inputText: command.isEmpty ? nil : command,
                outputText: output,
                exitCode: exitCode,
                status: status,
                finishedAt: status == .running ? nil : Date()
            ))]

        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let formatted = changes.compactMap { change -> String? in
                guard let path = change["path"] as? String else { return nil }
                let kind = change["kind"] as? String ?? "modify"
                return "[\(kind)] \(path)"
            }
            let firstPath = changes.first?["path"] as? String
            let subtitle: String?
            if changes.count > 1, let firstPath {
                subtitle = "\(firstPath) 等 \(changes.count) 个文件"
            } else {
                subtitle = firstPath
            }
            let status: ChatActivityStatus = itemStatus == "failed" ? .failed : (isCompletedEvent || itemStatus == "completed" ? .completed : .running)
            return [.activityUpsert(ChatActivityItem(
                id: "codex-\(itemID)",
                kind: .fileChange,
                title: "文件改动",
                subtitle: subtitle,
                outputText: formatted.isEmpty ? nil : formatted.joined(separator: "\n"),
                status: status,
                finishedAt: status == .running ? nil : Date()
            ))]

        case "mcp_tool_call":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "tool"
            let argsString: String?
            if let args = item["arguments"], JSONSerialization.isValidJSONObject(args),
               let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]) {
                argsString = String(data: data, encoding: .utf8)
            } else {
                argsString = item["arguments"] as? String
            }
            let outputString: String?
            if let errorObj = item["error"] as? [String: Any], let msg = errorObj["message"] as? String {
                outputString = msg
            } else if let result = item["result"] {
                if let str = result as? String {
                    outputString = str
                } else if JSONSerialization.isValidJSONObject(result),
                          let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    outputString = String(data: data, encoding: .utf8)
                } else {
                    outputString = String(describing: result)
                }
            } else {
                outputString = nil
            }
            let status: ChatActivityStatus = itemStatus == "failed" || item["error"] != nil
                ? .failed
                : (isCompletedEvent || itemStatus == "completed" ? .completed : .running)
            return [.activityUpsert(ChatActivityItem(
                id: "codex-\(itemID)",
                kind: .tool,
                title: "MCP · \(server)/\(tool)",
                subtitle: tool,
                inputText: argsString,
                outputText: outputString,
                status: status,
                finishedAt: status == .running ? nil : Date()
            ))]

        case "web_search":
            let query = item["query"] as? String ?? ""
            let status: ChatActivityStatus = isCompletedEvent || itemStatus == "completed" ? .completed : .running
            return [.activityUpsert(ChatActivityItem(
                id: "codex-\(itemID)",
                kind: .tool,
                title: "网页搜索",
                subtitle: query.isEmpty ? nil : query,
                inputText: query.isEmpty ? nil : query,
                status: status,
                finishedAt: status == .running ? nil : Date()
            ))]

        case "error":
            let msg = item["message"] as? String ?? "Codex 项目执行出错"
            return [.activityUpsert(ChatActivityItem(
                id: "codex-\(itemID)",
                kind: .error,
                title: "执行错误",
                outputText: msg,
                status: .failed,
                finishedAt: Date()
            ))]

        default:
            let status: ChatActivityStatus = isCompletedEvent || itemStatus == "completed" ? .completed : .running
            let rawText: String?
            if JSONSerialization.isValidJSONObject(item),
               let data = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted, .sortedKeys]) {
                rawText = String(data: data, encoding: .utf8)
            } else {
                rawText = nil
            }
            return [.activityUpsert(ChatActivityItem(
                id: "codex-\(itemID)",
                kind: .tool,
                title: itemType.isEmpty ? "事件" : itemType,
                outputText: rawText,
                status: status,
                finishedAt: status == .running ? nil : Date()
            ))]
        }
    }

    private nonisolated static func parseCodexUsage(_ dict: [String: Any]?) -> ChatTokenUsage? {
        guard let dict else { return nil }
        let input = dict["input_tokens"] as? Int ?? 0
        let cached = dict["cached_input_tokens"] as? Int ?? 0
        let output = dict["output_tokens"] as? Int ?? 0
        let reasoning = dict["reasoning_output_tokens"] as? Int ?? 0
        let total = dict["total_tokens"] as? Int ?? (input + output)
        guard input + output + cached + reasoning + total > 0 else { return nil }
        return ChatTokenUsage(
            inputTokens: input,
            outputTokens: output,
            thinkingTokens: reasoning,
            cachedInputTokens: cached,
            totalTokens: total
        )
    }
}
