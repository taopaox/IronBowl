import Darwin
import Foundation
import IronBowlKit
import Observation

/// 研发工具箱设置键。
public enum DevToolsKeys {
    public static let watchedPorts = SettingKey<[Int]>("devtools.watchedPorts", default: [3000, 5173, 8000, 8080, 8888])
}

/// 本地 TCP 监听端口条目。
public nonisolated struct ListeningPortItem: Identifiable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let processName: String
    public let port: Int
    public let bindAddress: String
    public let userName: String
    public let commandLine: String

    public var id: String { "\(pid):\(port):\(bindAddress)" }

    public init(
        pid: Int32,
        processName: String,
        port: Int,
        bindAddress: String,
        userName: String = "",
        commandLine: String = ""
    ) {
        self.pid = pid
        self.processName = processName
        self.port = port
        self.bindAddress = bindAddress
        self.userName = userName
        self.commandLine = commandLine
    }
}

public nonisolated enum PortActionError: LocalizedError, Sendable, Equatable {
    case protectedProcess(Int32)
    case killFailed(errno: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .protectedProcess(let pid):
            "出于安全保护，拒绝终止系统或饭碗自身进程（PID \(pid)）"
        case .killFailed(let code, let message):
            "终止进程失败（errno \(code)）：\(message)"
        }
    }
}

/// 本地监听端口扫描与安全终止工具。
public nonisolated enum PortScanner {
    @concurrent
    public static func scanListeningPorts() async -> [ListeningPortItem] {
        guard let r = try? await Shell.run(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnLu"],
            timeout: 15
        ), r.status == 0 || !r.stdout.isEmpty else {
            return []
        }

        let preliminary = parseLsofOutput(r.stdout)
        let pids = Array(Set(preliminary.map(\.pid))).sorted()
        var psCommands: [Int32: String] = [:]
        if !pids.isEmpty {
            let pidArg = pids.map(String.init).joined(separator: ",")
            if let psResult = try? await Shell.run("/bin/ps", ["-p", pidArg, "-o", "pid=,args="], timeout: 10),
               psResult.status == 0 {
                psCommands = parsePsOutput(psResult.stdout)
            }
        }
        return parseLsofOutput(r.stdout, psCommands: psCommands)
    }

    public static func parseLsofOutput(_ text: String, psCommands: [Int32: String] = [:]) -> [ListeningPortItem] {
        var currentPID: Int32?
        var currentCmd = ""
        var currentUser = ""
        var seen = Set<String>()
        var items: [ListeningPortItem] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
                currentCmd = ""
                currentUser = ""
            case "c":
                currentCmd = value
            case "L", "u":
                if currentUser.isEmpty { currentUser = value }
            case "n":
                guard let pid = currentPID,
                      let colonIdx = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colonIdx)...]) else {
                    continue
                }
                let addr = String(value[..<colonIdx])
                let key = "\(pid):\(port):\(addr)"
                guard seen.insert(key).inserted else { continue }
                let cmd = psCommands[pid] ?? ""
                items.append(ListeningPortItem(
                    pid: pid,
                    processName: currentCmd.isEmpty ? "PID \(pid)" : currentCmd,
                    port: port,
                    bindAddress: addr,
                    userName: currentUser,
                    commandLine: cmd
                ))
            default:
                break
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.pid < rhs.pid
        }
    }

    public static func parsePsOutput(_ text: String) -> [Int32: String] {
        var dict: [Int32: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(where: \.isWhitespace),
                  let pid = Int32(trimmed[..<spaceIdx]) else { continue }
            let args = String(trimmed[spaceIdx...]).trimmingCharacters(in: .whitespaces)
            if !args.isEmpty {
                dict[pid] = args
            }
        }
        return dict
    }

    public static func terminateProcess(pid: Int32, force: Bool = false) -> Result<Void, PortActionError> {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard pid > 1, pid != selfPID else {
            return .failure(.protectedProcess(pid))
        }
        let sig: Int32 = force ? SIGKILL : SIGTERM
        if Darwin.kill(pid, sig) == 0 {
            return .success(())
        }
        let code = errno
        let msg = String(cString: strerror(code))
        return .failure(.killFailed(errno: code, message: msg))
    }
}
