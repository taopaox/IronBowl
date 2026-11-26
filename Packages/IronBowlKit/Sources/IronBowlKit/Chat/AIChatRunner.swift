import Foundation

/// 多轮交互式 AI CLI 流式执行器（支持 `agy` 与 `codex` 在工作目录内读写与命令执行）。
public enum AIChatRunner {
    public nonisolated static func buildArguments(
        config: AIProviderConfig,
        prompt: String,
        workspacePath: String,
        permissionMode: ChatPermissionMode,
        resumeSessionID: String?
    ) -> [String] {
        let extra = config.extraArgs.split(whereSeparator: \.isWhitespace).map(String.init)
        let session = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validSession = (session?.isEmpty == false) ? session : nil

        switch config.kind {
        case .agy:
            var args: [String] = []
            if let validSession {
                args += ["--resume", validSession]
            }
            args += ["-p", prompt, "--output-format", "stream-json"]
            switch permissionMode {
            case .agent:
                args.append("--dangerously-skip-permissions")
            case .readOnly:
                args.append("--sandbox")
            }
            if !config.model.isEmpty { args += ["--model", config.model] }
            if !config.effort.isEmpty { args += ["--effort", config.effort] }
            args += extra
            return args

        case .codex:
            let sandboxMode = permissionMode == .agent ? "workspace-write" : "read-only"
            var args: [String] = []
            if let validSession {
                args += [
                    "exec", "resume", "--skip-git-repo-check", "--json",
                    "-c", "sandbox_mode=\"\(sandboxMode)\"",
                    "-c", "approval_policy=\"never\"",
                ]
                if !config.model.isEmpty { args += ["-m", config.model] }
                if !config.effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(config.effort)\""] }
                args += extra
                args.append(validSession)
                args.append(prompt)
            } else {
                args += [
                    "exec", "--skip-git-repo-check",
                    "-s", sandboxMode,
                    "-c", "approval_policy=\"never\"",
                    "--json",
                    "-C", workspacePath,
                ]
                if !config.model.isEmpty { args += ["-m", config.model] }
                if !config.effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(config.effort)\""] }
                args += extra
                args.append(prompt)
            }
            return args
        }
    }

    @concurrent
    public nonisolated static func stream(
        config: AIProviderConfig,
        prompt: String,
        workspaceURL: URL,
        permissionMode: ChatPermissionMode,
        resumeSessionID: String?,
        onHandle: (@Sendable (ShellProcessHandle) -> Void)? = nil,
        onEvent: @escaping @Sendable (AIChatStreamEvent?, String) -> Void
    ) async throws -> ShellStreamResult {
        guard !config.executablePath.isEmpty else {
            throw AIError.missingExecutable(config.kind)
        }

        let resolvedWorkspace: URL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            resolvedWorkspace = workspaceURL
        } else {
            resolvedWorkspace = FileManager.default.homeDirectoryForCurrentUser
        }

        let args = buildArguments(
            config: config,
            prompt: prompt,
            workspacePath: resolvedWorkspace.path,
            permissionMode: permissionMode,
            resumeSessionID: resumeSessionID
        )
        let timeout = TimeInterval(max(600, config.timeoutSeconds))
        let kind = config.kind

        return try await Shell.streamLines(
            config.executablePath,
            args,
            cwd: resolvedWorkspace,
            timeout: timeout,
            onHandle: onHandle,
            onStdoutLine: { line in
                let parsed = AIChatStreamParser.parseLine(line, provider: kind)
                if parsed.isEmpty {
                    onEvent(nil, line)
                } else {
                    for (index, event) in parsed.enumerated() {
                        onEvent(event, index == 0 ? line : "")
                    }
                }
            },
            onStderrLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onEvent(nil, "[stderr] " + trimmed)
                }
            }
        )
    }
}
