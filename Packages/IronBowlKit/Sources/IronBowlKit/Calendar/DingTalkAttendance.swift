import AppKit
import Foundation

public nonisolated enum DingTalkAttendanceError: LocalizedError, Sendable, Equatable {
    /// 没装 dws，或配置的路径已失效。
    case missingExecutable
    /// dws 是 npm 装的 node 脚本，但登录 shell 里找不到 node。
    case nodeMissing
    /// 没登录，或登录已过期。
    case notLoggedIn
    /// 账号没有考勤读取权限。
    case noPermission(String)
    /// 网络不通或钉钉接口超时。
    case network(String)
    case timedOut
    case cliFailed(String)
    case badOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable: "没找到钉钉 CLI（dws），需要先安装"
        case .nodeMissing: "dws 依赖 Node.js，但没找到 node，请确认 nvm / Homebrew 的 node 在登录 shell 的 PATH 里"
        case .notLoggedIn: "dws 还没登录或登录已过期，需要重新登录"
        case .noPermission(let s): "钉钉账号没有考勤查询权限：\(s.prefix(200))"
        case .network(let s): "连不上钉钉，稍后会自动重试：\(s.prefix(200))"
        case .timedOut: "dws 运行超时，稍后会自动重试"
        case .cliFailed(let s): "dws 运行失败：\(s.prefix(300))"
        case .badOutput(let s): "dws 输出无法解析：\(s.prefix(300))"
        }
    }

    /// 需要用户动手解决（安装、登录、权限）的问题；自动同步遇到时放慢重试，并提醒一次。
    public var needsUserAction: Bool {
        switch self {
        case .missingExecutable, .nodeMissing, .notLoggedIn, .noPermission: true
        case .network, .timedOut, .cliFailed, .badOutput: false
        }
    }

    /// 用于「同一天同类问题只提醒一次」。
    public var kind: String {
        switch self {
        case .missingExecutable: "missing"
        case .nodeMissing: "node"
        case .notLoggedIn: "login"
        case .noPermission: "permission"
        case .network: "network"
        case .timedOut: "timeout"
        case .cliFailed: "failed"
        case .badOutput: "output"
        }
    }
}

/// 通过钉钉官方 CLI（dws，DingTalk Workspace CLI）只读查询本人的考勤打卡。
public enum DingTalkAttendance {
    public nonisolated static let binaryName = "dws"
    public nonisolated static let installCommand = "npm install -g dingtalk-workspace-cli"
    public nonisolated static let loginCommand = "dws auth login"

    /// 用登录 shell 查找 dws 路径。
    @concurrent
    public nonisolated static func locateExecutable() async -> String? {
        await Shell.which(binaryName)
    }

    /// `dws auth status --format json` → 当前登录账号的 userId。
    @concurrent
    public nonisolated static func currentUserID(executable: String) async throws -> String {
        let r = try await runDws(executable, ["auth", "status", "--format", "json"], timeout: 30)
        if let id = try? parseUserID(r.stdout) { return id }
        if (try? DingTalkAttendance.jsonObject(r.stdout))?["authenticated"] as? Bool == false {
            throw DingTalkAttendanceError.notLoggedIn
        }
        throw classifyFailure(status: r.status, stdout: r.stdout, stderr: r.stderr)
    }

    /// `dws attendance +check-result` 查某天（yyyy-MM-dd）的上班打卡时间，没打卡返回 nil。
    @concurrent
    public nonisolated static func fetchClockIn(executable: String, userID: String, day: String) async throws -> Date? {
        let r = try await runDws(executable, [
            "attendance", "+check-result",
            "--users", userID, "--start", day, "--end", day,
            "--format", "json",
        ], timeout: 45)
        guard r.status == 0 else { throw classifyFailure(status: r.status, stdout: r.stdout, stderr: r.stderr) }
        return try parseOnDutyClockIn(r.stdout)
    }

    /// 运行 dws，把找不到程序、超时这类 Shell 错误换成考勤错误。
    @concurrent
    nonisolated static func runDws(_ executable: String, _ args: [String], timeout: TimeInterval) async throws -> ShellResult {
        do {
            return try await Shell.run(executable, args, timeout: timeout)
        } catch ShellError.notFound {
            throw DingTalkAttendanceError.missingExecutable
        } catch ShellError.timedOut {
            throw DingTalkAttendanceError.timedOut
        } catch {
            throw DingTalkAttendanceError.cliFailed(error.localizedDescription)
        }
    }

    // MARK: 引导安装与登录

    /// 打开「终端」执行：没装就先 npm 安装，然后 `dws auth login`（扫码 / 浏览器授权需要交互，只能在终端里完成）。
    public static func openSetupInTerminal() {
        let script = """
        #!/bin/zsh -il
        echo "== 饭碗：配置钉钉 CLI（dws）=="
        if ! command -v dws >/dev/null 2>&1; then
          echo "没找到 dws，开始安装：\(installCommand)"
          \(installCommand) || { echo "安装失败，请检查 Node.js / npm 是否可用"; exit 1; }
        fi
        echo "开始登录钉钉，请按提示扫码或在浏览器里授权……"
        \(loginCommand) && echo "登录完成，可以回到饭碗点「立即同步」了。"
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "ironbowl-dws-setup.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(installCommand) && \(loginCommand)", forType: .string)
        }
    }

    // MARK: 解析

    nonisolated static func jsonObject(_ text: String) throws -> [String: Any] {
        guard let data = try? AIRunner.extractJSONObject(text),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DingTalkAttendanceError.badOutput(text) }
        return obj
    }

    /// `{"authenticated":true,"user_id":"…",…}`；未登录时为 `{"authenticated":false,"message":"未登录"}`。
    nonisolated static func parseUserID(_ stdout: String) throws -> String {
        let obj = try jsonObject(stdout)
        if obj["authenticated"] as? Bool == false { throw DingTalkAttendanceError.notLoggedIn }
        guard let id = obj["user_id"] as? String ?? obj["userId"] as? String, !id.isEmpty else {
            throw DingTalkAttendanceError.notLoggedIn
        }
        return id
    }

    /// `{"ok":true,"data":{"records":[{"checkType":"OnDuty","userCheckTime":毫秒,…}]}}`
    /// 取 OnDuty 记录里最早的实际打卡时间；缺卡（没有 userCheckTime 或 NotSigned）不算。
    nonisolated static func parseOnDutyClockIn(_ stdout: String) throws -> Date? {
        let obj = try jsonObject(stdout)
        if obj["ok"] as? Bool == false { throw classifyFailure(status: 1, stdout: stdout, stderr: "") }
        let records = (obj["data"] as? [String: Any])?["records"] as? [[String: Any]] ?? []
        let times: [Date] = records.compactMap { rec in
            guard rec["checkType"] as? String == "OnDuty",
                  rec["timeResult"] as? String != "NotSigned",
                  let ms = (rec["userCheckTime"] as? NSNumber)?.doubleValue, ms > 0
            else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return times.min()
    }

    /// 把 dws 的失败输出归类。dws 失败时输出 `{"ok":false,"error":{"type"/"category":…,"message":…}}`（stdout 或 stderr），
    /// 退出码非 0；npm 版的 node 脚本找不到 node 时退出码 127、输出 `env: node: No such file or directory`。
    nonisolated static func classifyFailure(status: Int32, stdout: String, stderr: String) -> DingTalkAttendanceError {
        let raw = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
        if status == 127 || raw.contains("env: node") {
            return raw.contains("node") ? .nodeMissing : .missingExecutable
        }
        var category = "", message = raw
        if let error = ((try? jsonObject(stdout)) ?? (try? jsonObject(stderr)))?["error"] as? [String: Any] {
            category = (error["category"] as? String ?? error["type"] as? String ?? "").lowercased()
            message = error["message"] as? String ?? raw
        }
        let lower = message.lowercased()
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }
        if category == "auth" || has("access token", "refresh token", "未登录", "not logged in", "unauthorized", "auth login", "token expired", "登录已过期") {
            return .notLoggedIn
        }
        if has("permission", "forbidden", "无权限", "没有权限", "权限不足", "not authorized") {
            return .noPermission(message)
        }
        if has("dial tcp", "no such host", "connection refused", "network is unreachable", "timeout", "timed out", "tls handshake", "i/o timeout") {
            return .network(message)
        }
        return .cliFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
