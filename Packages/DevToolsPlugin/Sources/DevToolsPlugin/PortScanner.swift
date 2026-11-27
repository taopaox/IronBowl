import Darwin
import Foundation
import IronBowlKit
import Observation

/// 研发工具箱设置键。
public enum DevToolsKeys {
    public static let watchedPorts = SettingKey<[Int]>("devtools.watchedPorts", default: [3000, 5173, 8000, 8080, 8888])
    public static let devDirectories = SettingKey<[String]>("devtools.devDirectories", default: [])
}

/// 本地 TCP 监听端口条目。
public nonisolated struct ListeningPortItem: Identifiable, Sendable, Equatable, Hashable {
    public let pid: Int32
    public let processName: String
    public let port: Int
    public let bindAddress: String
    public let userName: String
    public let commandLine: String
    public let workingDirectory: String

    public var id: String { "\(pid):\(port):\(bindAddress)" }

    public init(
        pid: Int32,
        processName: String,
        port: Int,
        bindAddress: String,
        userName: String = "",
        commandLine: String = "",
        workingDirectory: String = ""
    ) {
        self.pid = pid
        self.processName = processName
        self.port = port
        self.bindAddress = bindAddress
        self.userName = userName
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
    }
}

/// 开发目录配置来源。
public nonisolated enum DevDirectorySource: String, Sendable, Equatable, Hashable {
    case gitRoot
    case workspaceExtra
    case custom

    public var displayLabel: String {
        switch self {
        case .gitRoot: "仓库根目录"
        case .workspaceExtra: "额外仓库"
        case .custom: "自定义目录"
        }
    }
}

/// 生效的开发目录监控条目。
public nonisolated struct DevDirectoryEntry: Identifiable, Sendable, Equatable, Hashable {
    public let path: String
    public let source: DevDirectorySource

    public var id: String { path }
    public var displayName: String { (path as NSString).lastPathComponent }

    public init(path: String, source: DevDirectorySource) {
        self.path = path
        self.source = source
    }
}

/// 端口归属开发目录的匹配依据。
public nonisolated enum PortMatchBasis: String, Sendable, Equatable, Hashable {
    case workingDirectory
    case commandLine

    public var displayLabel: String {
        switch self {
        case .workingDirectory: "工作目录"
        case .commandLine: "启动命令"
        }
    }
}

/// 端口命中开发目录后的匹配详情。
public nonisolated struct PortDirectoryMatch: Sendable, Equatable, Hashable {
    public let rootDirectory: String
    public let matchedDirectory: String
    public let projectLabel: String
    public let basis: PortMatchBasis

    public init(
        rootDirectory: String,
        matchedDirectory: String,
        projectLabel: String,
        basis: PortMatchBasis
    ) {
        self.rootDirectory = rootDirectory
        self.matchedDirectory = matchedDirectory
        self.projectLabel = projectLabel
        self.basis = basis
    }
}

/// 端口检查分组筛选范围。
public nonisolated enum PortGroupScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all = "全部分组"
    case devDirectory = "我的开发目录"
    case other = "其他端口"

    public var id: String { rawValue }
}

/// 附带开发目录归属信息的端口条目。
public nonisolated struct GroupedListeningPort: Identifiable, Sendable, Equatable, Hashable {
    public let item: ListeningPortItem
    public let directoryMatch: PortDirectoryMatch?

    public var id: String { item.id }
    public var isInDevDirectory: Bool { directoryMatch != nil }

    public init(item: ListeningPortItem, directoryMatch: PortDirectoryMatch?) {
        self.item = item
        self.directoryMatch = directoryMatch
    }
}

/// 按「我的开发目录」与「其他端口」拆分后的端口检查结果。
public nonisolated struct PortPartition: Sendable, Equatable {
    public let devDirectoryItems: [GroupedListeningPort]
    public let otherItems: [GroupedListeningPort]

    public var totalCount: Int { devDirectoryItems.count + otherItems.count }

    public init(devDirectoryItems: [GroupedListeningPort], otherItems: [GroupedListeningPort]) {
        self.devDirectoryItems = devDirectoryItems
        self.otherItems = otherItems
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
        var workingDirs: [Int32: String] = [:]
        if !pids.isEmpty {
            let pidArg = pids.map(String.init).joined(separator: ",")
            async let psTask = Shell.run("/bin/ps", ["-ww", "-p", pidArg, "-o", "pid=,args="], timeout: 10)
            async let cwdTask = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-p", pidArg, "-d", "cwd", "-F", "pn"], timeout: 10)

            if let psResult = try? await psTask, psResult.status == 0 || !psResult.stdout.isEmpty {
                psCommands = parsePsOutput(psResult.stdout)
            }
            if let cwdResult = try? await cwdTask, cwdResult.status == 0 || !cwdResult.stdout.isEmpty {
                let rawCwds = parseLsofCwdOutput(cwdResult.stdout)
                workingDirs = rawCwds.mapValues { PortDirectoryMatcher.normalizePath($0, resolveSymlinks: true) }
            }
        }
        return parseLsofOutput(r.stdout, psCommands: psCommands, workingDirectories: workingDirs)
    }

    public static func parseLsofOutput(
        _ text: String,
        psCommands: [Int32: String] = [:],
        workingDirectories: [Int32: String] = [:]
    ) -> [ListeningPortItem] {
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
                let cwd = workingDirectories[pid] ?? ""
                items.append(ListeningPortItem(
                    pid: pid,
                    processName: currentCmd.isEmpty ? "PID \(pid)" : currentCmd,
                    port: port,
                    bindAddress: addr,
                    userName: currentUser,
                    commandLine: cmd,
                    workingDirectory: cwd
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

    public static func parseLsofCwdOutput(_ text: String) -> [Int32: String] {
        var currentPID: Int32?
        var currentFD = ""
        var dict: [Int32: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
                currentFD = ""
            case "f":
                currentFD = value
            case "n":
                guard let pid = currentPID,
                      currentFD.isEmpty || currentFD == "cwd",
                      !value.isEmpty else {
                    continue
                }
                if dict[pid] == nil {
                    dict[pid] = value
                }
            default:
                break
            }
        }
        return dict
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

/// 纯函数：将监听端口按工作目录或启动命令归入「我的开发目录」与「其他端口」。
public nonisolated enum PortDirectoryMatcher {
    private static let artifactDirSegments: Set<String> = [
        "node_modules", ".venv", "venv", "target", "dist", "build", ".build", ".next", ".nuxt", "__pycache__"
    ]
    private static let leadingBoundaries: Set<Character> = [" ", "\t", "\"", "'", "=", ":", ",", "("]
    private static let trailingBoundaries: Set<Character> = ["/", " ", "\t", "\"", "'", ";", ",", ")"]
    private static let tokenTerminators: Set<Character> = [" ", "\t", "\n", "\r", "\"", "'", ";", ",", ")"]

    public static func normalizePath(_ raw: String, resolveSymlinks: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var normalized = (expanded as NSString).standardizingPath
        if resolveSymlinks, FileManager.default.fileExists(atPath: normalized) {
            normalized = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().path
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// 拦截 `/` 与用户主目录等过宽路径，避免系统/三方桌面进程误入开发目录分组。
    public static func isUsableRootDirectory(_ normalizedPath: String) -> Bool {
        guard !normalizedPath.isEmpty, normalizedPath != "/" else { return false }
        let home = normalizePath(NSHomeDirectory())
        let resolvedHome = normalizePath(NSHomeDirectory(), resolveSymlinks: true)
        return normalizedPath != home && normalizedPath != resolvedHome
    }

    public static func match(item: ListeningPortItem, devDirectories: [String]) -> PortDirectoryMatch? {
        var seen = Set<String>()
        let roots = devDirectories
            .map { normalizePath($0) }
            .filter { isUsableRootDirectory($0) && seen.insert($0).inserted }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs < rhs
            }

        guard !roots.isEmpty else { return nil }

        let cwd = normalizePath(item.workingDirectory)
        if !cwd.isEmpty {
            for root in roots where isSameOrDescendant(cwd, of: root) {
                return PortDirectoryMatch(
                    rootDirectory: root,
                    matchedDirectory: cwd,
                    projectLabel: projectLabel(for: cwd, under: root),
                    basis: .workingDirectory
                )
            }
        }

        if !item.commandLine.isEmpty {
            for root in roots {
                if let matchedDir = findCommandDirectory(in: item.commandLine, under: root) {
                    return PortDirectoryMatch(
                        rootDirectory: root,
                        matchedDirectory: matchedDir,
                        projectLabel: projectLabel(for: matchedDir, under: root),
                        basis: .commandLine
                    )
                }
            }
        }

        return nil
    }

    public static func partition(_ items: [ListeningPortItem], devDirectories: [String]) -> PortPartition {
        var devItems: [GroupedListeningPort] = []
        var otherItems: [GroupedListeningPort] = []

        for item in items {
            if let dirMatch = match(item: item, devDirectories: devDirectories) {
                devItems.append(GroupedListeningPort(item: item, directoryMatch: dirMatch))
            } else {
                otherItems.append(GroupedListeningPort(item: item, directoryMatch: nil))
            }
        }

        devItems.sort { lhs, rhs in
            let lLabel = lhs.directoryMatch?.projectLabel ?? ""
            let rLabel = rhs.directoryMatch?.projectLabel ?? ""
            let cmp = lLabel.localizedStandardCompare(rLabel)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            if lhs.item.port != rhs.item.port { return lhs.item.port < rhs.item.port }
            return lhs.item.pid < rhs.item.pid
        }

        otherItems.sort { lhs, rhs in
            if lhs.item.port != rhs.item.port { return lhs.item.port < rhs.item.port }
            return lhs.item.pid < rhs.item.pid
        }

        return PortPartition(devDirectoryItems: devItems, otherItems: otherItems)
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func projectLabel(for directory: String, under root: String) -> String {
        if directory == root {
            let name = (root as NSString).lastPathComponent
            return name.isEmpty ? root : name
        }
        return String(directory.dropFirst(root.count + 1))
    }

    private static func findCommandDirectory(in commandLine: String, under root: String) -> String? {
        var searchStart = commandLine.startIndex
        while let range = commandLine.range(of: root, range: searchStart..<commandLine.endIndex) {
            let validLeading: Bool = {
                guard range.lowerBound > commandLine.startIndex else { return true }
                let prev = commandLine[commandLine.index(before: range.lowerBound)]
                return leadingBoundaries.contains(prev)
            }()
            let validTrailing: Bool = {
                guard range.upperBound < commandLine.endIndex else { return true }
                let next = commandLine[range.upperBound]
                return trailingBoundaries.contains(next)
            }()

            if validLeading && validTrailing {
                var endIdx = range.upperBound
                while endIdx < commandLine.endIndex, !tokenTerminators.contains(commandLine[endIdx]) {
                    endIdx = commandLine.index(after: endIdx)
                }
                let token = String(commandLine[range.lowerBound..<endIdx])
                return refineCommandPath(token, under: root)
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func refineCommandPath(_ token: String, under root: String) -> String {
        let normalized = normalizePath(token)
        guard isSameOrDescendant(normalized, of: root) else { return root }
        guard normalized != root else { return root }

        let relative = String(normalized.dropFirst(root.count + 1))
        var segments = relative.split(separator: "/").map(String.init)
        if let artifactIdx = segments.firstIndex(where: { artifactDirSegments.contains($0) }) {
            segments = Array(segments.prefix(artifactIdx))
        } else if let last = segments.last, last.contains("."), !last.hasPrefix(".") {
            segments.removeLast()
        }

        if segments.isEmpty { return root }
        return root + "/" + segments.joined(separator: "/")
    }
}
