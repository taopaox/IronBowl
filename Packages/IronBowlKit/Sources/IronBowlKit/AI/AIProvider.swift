import Foundation
import Observation

public nonisolated enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case agy
    case codex

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .agy: "Antigravity（agy）"
        case .codex: "Codex"
        }
    }
    /// 命令行程序名，用于自动查找路径。
    public var binaryName: String { rawValue }
    public var effortOptions: [String] {
        switch self {
        case .agy: ["", "low", "medium", "high", "xhigh", "max"]
        case .codex: ["", "minimal", "low", "medium", "high"]
        }
    }
}

public nonisolated struct AIProviderConfig: Codable, Sendable, Identifiable, Hashable {
    public var kind: AIProviderKind
    public var executablePath: String = ""
    /// 空字符串 = 用 CLI 自己的默认模型。
    public var model: String = ""
    public var effort: String = "low"
    public var timeoutSeconds: Int = 90
    /// 追加到命令行末尾的参数，空格分隔。
    public var extraArgs: String = ""

    public var id: String { kind.rawValue }

    public init(kind: AIProviderKind) { self.kind = kind }
}

public nonisolated enum AIError: LocalizedError, Sendable {
    case missingExecutable(AIProviderKind)
    case badOutput(String)
    case cliFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let k): "没找到 \(k.binaryName)，请在设置里填写程序路径"
        case .badOutput(let s): "AI 输出无法解析：\(s.prefix(300))"
        case .cliFailed(let s): "AI 运行失败：\(s.prefix(400))"
        }
    }
}

public nonisolated struct AIRunResult: Sendable {
    /// 符合 schema 的 JSON。
    public let json: Data
    public let duration: TimeInterval
}

/// 调用本机 AI CLI，返回结构化 JSON。两个提供者用同一套提示词和 schema，都只读运行。
public enum AIRunner {
    @concurrent
    public nonisolated static func run(config: AIProviderConfig, prompt: String, schema: String) async throws -> AIRunResult {
        guard !config.executablePath.isEmpty else { throw AIError.missingExecutable(config.kind) }
        let workDir = FileManager.default.temporaryDirectory
            .appending(path: "ironbowl-ai-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let extra = config.extraArgs.split(whereSeparator: \.isWhitespace).map(String.init)
        let timeout = TimeInterval(max(10, config.timeoutSeconds))

        switch config.kind {
        case .agy:
            var args = ["-p", prompt, "--output-format", "json", "--json-schema", schema,
                        "--sandbox", "--disable-slash-commands"]
            if !config.model.isEmpty { args += ["--model", config.model] }
            if !config.effort.isEmpty { args += ["--effort", config.effort] }
            args += extra
            let r = try await Shell.run(config.executablePath, args, cwd: workDir, timeout: timeout)
            guard r.status == 0 else { throw AIError.cliFailed(r.stderr.isEmpty ? r.stdout : r.stderr) }
            return AIRunResult(json: try parseAgy(r.stdout), duration: r.duration)

        case .codex:
            let schemaURL = workDir.appending(path: "schema.json")
            let outURL = workDir.appending(path: "out.json")
            try schema.write(to: schemaURL, atomically: true, encoding: .utf8)
            var args = ["exec", "--skip-git-repo-check", "-s", "read-only",
                        "--output-schema", schemaURL.path, "-o", outURL.path, "-C", workDir.path]
            if !config.model.isEmpty { args += ["-m", config.model] }
            if !config.effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(config.effort)\""] }
            args += extra
            args.append(prompt)
            let r = try await Shell.run(config.executablePath, args, cwd: workDir, timeout: timeout)
            guard r.status == 0, let out = try? String(contentsOf: outURL, encoding: .utf8) else {
                let tail = (r.stderr + r.stdout).split(separator: "\n").suffix(4).joined(separator: "\n")
                throw AIError.cliFailed(tail)
            }
            return AIRunResult(json: try extractJSONObject(out), duration: r.duration)
        }
    }

    /// agy --output-format json：{"status":"SUCCESS","structured_output":{…},"response":"…"}
    nonisolated static func parseAgy(_ stdout: String) throws -> Data {
        let envelope = try extractJSONObject(stdout)
        guard let obj = try JSONSerialization.jsonObject(with: envelope) as? [String: Any] else {
            throw AIError.badOutput(stdout)
        }
        if let status = obj["status"] as? String, status != "SUCCESS" {
            throw AIError.cliFailed("agy 状态 \(status)：\(obj["response"] ?? "")")
        }
        if let structured = obj["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            return try JSONSerialization.data(withJSONObject: structured)
        }
        if let response = obj["response"] as? String {
            return try extractJSONObject(response)
        }
        throw AIError.badOutput(stdout)
    }

    /// 从一段文本里取出第一个完整的 JSON 对象（容忍前后有日志或 ``` 包裹）。
    public nonisolated static func extractJSONObject(_ text: String) throws -> Data {
        let chars = Array(text.utf8)
        guard let start = chars.firstIndex(of: UInt8(ascii: "{")) else { throw AIError.badOutput(text) }
        var depth = 0, inString = false, escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch c {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    let data = Data(chars[start...i])
                    guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw AIError.badOutput(text) }
                    return data
                }
            default: break
            }
        }
        throw AIError.badOutput(text)
    }

    /// `agy models` 列出可用模型（id, 名称）。
    @concurrent
    public nonisolated static func listModels(config: AIProviderConfig) async -> [(id: String, name: String)] {
        guard config.kind == .agy, !config.executablePath.isEmpty,
              let r = try? await Shell.run(config.executablePath, ["models"], timeout: 30), r.status == 0
        else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }
}

/// AI 提供者配置与默认选择，存在设置里。
@Observable
public final class AIProviderStore {
    static let configsKey = SettingKey<[AIProviderConfig]>("ai.providers", default: AIProviderKind.allCases.map(AIProviderConfig.init))
    static let defaultKey = SettingKey<AIProviderKind>("ai.default", default: .agy)

    @ObservationIgnored private let settings: SettingsStore

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var configs: [AIProviderConfig] {
        let saved = settings[Self.configsKey]
        // 新增的提供者种类自动补齐。
        return AIProviderKind.allCases.map { kind in saved.first { $0.kind == kind } ?? AIProviderConfig(kind: kind) }
    }

    public var defaultKind: AIProviderKind {
        get { settings[Self.defaultKey] }
        set { settings[Self.defaultKey] = newValue }
    }

    public func config(_ kind: AIProviderKind) -> AIProviderConfig {
        configs.first { $0.kind == kind } ?? AIProviderConfig(kind: kind)
    }

    public func update(_ config: AIProviderConfig) {
        var all = configs
        if let i = all.firstIndex(where: { $0.kind == config.kind }) { all[i] = config } else { all.append(config) }
        settings[Self.configsKey] = all
    }

    /// 路径为空的提供者，用登录 shell 自动查找一次。
    public func autodetectMissingPaths() async {
        for var c in configs where c.executablePath.isEmpty {
            if let path = await Shell.which(c.kind.binaryName) {
                c.executablePath = path
                update(c)
            }
        }
    }
}
