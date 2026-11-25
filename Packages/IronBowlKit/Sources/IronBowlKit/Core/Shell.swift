import Foundation

public nonisolated enum ShellError: LocalizedError, Sendable {
    case notFound(String)
    case timedOut(TimeInterval)
    case failed(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): "找不到程序：\(p)"
        case .timedOut(let t): "运行超时（\(Int(t)) 秒）"
        case .failed(let s, let e): "退出码 \(s)：\(e.prefix(400))"
        }
    }
}

public nonisolated struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let duration: TimeInterval
}

/// 运行外部命令。所有方法都在后台线程执行，不阻塞界面。
public enum Shell {
    /// 运行命令。`environment` 为 nil 时使用登录 shell 的 PATH（这样 nvm、Homebrew 装的命令也能找到）。
    @concurrent
    public nonisolated static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String]? = nil
    ) async throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShellError.notFound(executable)
        }
        var env = environment ?? ProcessInfo.processInfo.environment
        if environment == nil, let path = await loginShellPATH() {
            env["PATH"] = path
        }
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice

        let out = Collector(), err = Collector()
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let finished = Flag()
            process.terminationHandler = { p in
                guard finished.set() else { return }
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                guard finished.set() else { return }
                cont.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, finished.set() else { return }
                process.terminate()
                cont.resume(throwing: ShellError.timedOut(timeout))
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        err.append(errPipe.fileHandleForReading.readDataToEndOfFile())

        return ShellResult(status: status, stdout: out.string, stderr: err.string, duration: Date().timeIntervalSince(start))
    }

    /// 用登录 shell 查找命令的绝对路径（`zsh -lc 'command -v name'`）。
    @concurrent
    public nonisolated static func which(_ name: String) async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let safe = name.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        guard !safe.isEmpty,
              let r = try? await run(shell, ["-lc", "command -v \(safe)"], timeout: 10,
                                     environment: ProcessInfo.processInfo.environment),
              r.status == 0 else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    nonisolated private static let pathCache = PathCache()

    /// 登录 shell 的 PATH，只取一次。
    nonisolated static func loginShellPATH() async -> String? {
        if let cached = pathCache.value { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let r = try? await run(shell, ["-lc", "printf %s \"$PATH\""], timeout: 10,
                                     environment: ProcessInfo.processInfo.environment),
              r.status == 0 else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        pathCache.value = path
        return path
    }
}

private nonisolated final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private nonisolated final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// 第一次调用返回 true，之后都返回 false。
    func set() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

private nonisolated final class PathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
