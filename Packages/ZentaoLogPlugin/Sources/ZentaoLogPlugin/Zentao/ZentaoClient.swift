import Foundation
import IronBowlKit

public nonisolated struct ZentaoTask: Sendable, Identifiable, Hashable, Codable {
    public let id: Int
    public let name: String
    public let projectID: Int
    public let projectName: String
    public let status: String
    public let left: Double
    public let consumed: Double

    public var isOpen: Bool { !["closed", "cancel"].contains(status) }
    public var statusText: String {
        ["wait": "未开始", "doing": "进行中", "done": "已完成", "pause": "已暂停", "cancel": "已取消", "closed": "已关闭"][status] ?? status
    }
}

/// 禅道里某任务的一条工时记录。
public nonisolated struct ZentaoEstimate: Sendable, Hashable {
    public let taskID: Int
    public let date: String
    public let consumed: Double
    public let left: Double
    public let work: String
    public let account: String
}

public nonisolated enum ZentaoError: LocalizedError, Sendable {
    case notConfigured
    case loginFailed(String)
    case badResponse(String)
    case submitNotVerified(taskID: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "还没填写禅道地址、账号和密码"
        case .loginFailed(let r): "禅道登录失败：\(r)"
        case .badResponse(let s): "禅道返回了看不懂的内容：\(s.prefix(200))"
        case .submitNotVerified(let id): "任务 #\(id) 提交后没在禅道里查到这条工时，请到禅道确认"
        }
    }
}

/// 禅道企业版 biz4.x（对应开源 12.x）PATH_INFO 模式的 `.json` 接口。
/// 先 `api-getSessionID` 拿会话，再 `user-login` 登录，之后带 cookie 调网页接口。
/// 每次请求的原始响应写到 logs/zentao.log（不写密码），方便核对接口。
public actor ZentaoClient {
    private let baseURL: URL
    private let account: String
    private let password: String
    private let session: URLSession
    private var sessionName = "zentaosid"
    private var sessionID: String?
    private var loggedIn = false

    public init(baseURL: String, account: String, password: String) throws {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, !account.isEmpty, !password.isEmpty, let url = URL(string: trimmed) else {
            throw ZentaoError.notConfigured
        }
        self.baseURL = url
        self.account = account
        self.password = password
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    // MARK: 登录

    public func login() async throws {
        let (sidData, _) = try await request("api-getSessionID.json")
        let sid = try Self.payload(sidData)
        guard let name = sid["sessionName"] as? String, let id = sid["sessionID"] as? String else {
            throw ZentaoError.badResponse(String(decoding: sidData, as: UTF8.self))
        }
        sessionName = name
        sessionID = id

        let (data, _) = try await request("user-login.json", form: ["account": account, "password": password, "keepLogin[]": "on"],
                                          redactForm: true)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = obj?["status"] as? String
        if status == "success" || obj?["user"] != nil {
            loggedIn = true
            return
        }
        let reason = (obj?["reason"] as? String) ?? (obj?["message"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
        throw ZentaoError.loginFailed(reason)
    }

    private func ensureLogin() async throws {
        if !loggedIn { try await login() }
    }

    // MARK: 任务

    /// 指派给我的任务（含已关闭，界面上再过滤）。
    public func myTasks() async throws -> [ZentaoTask] {
        let obj = try await getJSON("my-task-assignedTo-id_desc-0-500-1.json")
        let raw: [[String: Any]]
        if let arr = obj["tasks"] as? [[String: Any]] {
            raw = arr
        } else if let dict = obj["tasks"] as? [String: [String: Any]] {
            raw = Array(dict.values)
        } else {
            raw = []
        }
        return raw.compactMap { t in
            guard let id = Self.int(t["id"]), let name = t["name"] as? String else { return nil }
            let projectID = Self.int(t["project"]) ?? Self.int(t["projectID"]) ?? 0
            return ZentaoTask(
                id: id,
                name: name,
                projectID: projectID,
                projectName: (t["projectName"] as? String) ?? "项目 #\(projectID)",
                status: (t["status"] as? String) ?? "",
                left: Self.double(t["left"]) ?? 0,
                consumed: Self.double(t["consumed"]) ?? 0
            )
        }
    }

    /// 某任务已有的工时记录。
    public func estimates(taskID: Int) async throws -> [ZentaoEstimate] {
        let obj = try await getJSON("task-recordEstimate-\(taskID).json")
        let raw: [[String: Any]]
        if let arr = obj["estimates"] as? [[String: Any]] {
            raw = arr
        } else if let dict = obj["estimates"] as? [String: [String: Any]] {
            raw = Array(dict.values)
        } else {
            raw = []
        }
        return raw.map { e in
            ZentaoEstimate(
                taskID: taskID,
                date: String(((e["date"] as? String) ?? "").prefix(10)),
                consumed: Self.double(e["consumed"]) ?? 0,
                left: Self.double(e["left"]) ?? 0,
                work: (e["work"] as? String) ?? "",
                account: (e["account"] as? String) ?? ""
            )
        }
    }

    /// 我在某天对这些任务记过的工时。
    public func myEstimates(on date: String, taskIDs: [Int]) async throws -> [ZentaoEstimate] {
        var result: [ZentaoEstimate] = []
        for id in Set(taskIDs) {
            let list = try await estimates(taskID: id)
            result += list.filter { $0.date == date && ($0.account.isEmpty || $0.account == account) }
        }
        return result
    }

    /// 给任务记一条工时，提交后回查确认。
    public func recordEstimate(taskID: Int, date: String, consumed: Double, left: Double, work: String) async throws {
        try await ensureLogin()
        let before = try await estimates(taskID: taskID).count
        let form: [String: String] = [
            "id[1]": "1",
            "dates[1]": date,
            "consumed[1]": Self.format(consumed),
            "left[1]": Self.format(left),
            "work[1]": work,
        ]
        _ = try await request("task-recordEstimate-\(taskID).json", form: form)
        let after = try await estimates(taskID: taskID)
        let found = after.count > before
            || after.contains { $0.date == date && abs($0.consumed - consumed) < 0.01 && $0.work == work }
        if !found { throw ZentaoError.submitNotVerified(taskID: taskID) }
    }

    // MARK: 底层

    private func getJSON(_ path: String, retry: Bool = true) async throws -> [String: Any] {
        try await ensureLogin()
        let (data, _) = try await request(path)
        if Self.looksLoggedOut(data) {
            guard retry else { throw ZentaoError.loginFailed("会话已失效") }
            loggedIn = false
            return try await getJSON(path, retry: false)
        }
        return try Self.payload(data)
    }

    private func request(_ path: String, form: [String: String]? = nil, redactForm: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if let sessionID { components.queryItems = [URLQueryItem(name: sessionName, value: sessionID)] }
        var req = URLRequest(url: components.url!)
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("IronBowl/0.1", forHTTPHeaderField: "User-Agent")
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.encodeForm(form).data(using: .utf8)
        }
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        ZentaoLog.write(method: form == nil ? "GET" : "POST", path: path,
                        form: redactForm ? form?.mapValues { _ in "***" }.merging(["account": account]) { $1 } : form,
                        status: http?.statusCode ?? -1, body: data)
        guard let http else { throw ZentaoError.badResponse("无响应") }
        return (data, http)
    }

    /// 禅道的 json 包装：{"status":"success","data":"<json 字符串>"}。
    static func payload(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZentaoError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if let s = obj["data"] as? String, let d = s.data(using: .utf8),
           let inner = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return inner
        }
        if let inner = obj["data"] as? [String: Any] { return inner }
        return obj
    }

    static func looksLoggedOut(_ data: Data) -> Bool {
        let s = String(decoding: data.prefix(2000), as: UTF8.self)
        return s.contains("user-login") && !s.contains("\"status\":\"success\"")
    }

    static func encodeForm(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// 禅道接口调试日志：~/Library/Application Support/IronBowl/logs/zentao.log
public nonisolated enum ZentaoLog {
    public static var url: URL { AppPaths.logsDirectory.appending(path: "zentao.log") }
    private static let lock = NSLock()

    static func write(method: String, path: String, form: [String: String]?, status: Int, body: Data) {
        let time = ISO8601DateFormatter().string(from: Date())
        var text = "[\(time)] \(method) \(path) -> \(status)\n"
        if let form { text += "form: \(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))\n" }
        text += String(decoding: body.prefix(4000), as: UTF8.self) + "\n\n"
        lock.lock()
        defer { lock.unlock() }
        // 超过 2MB 就清空重写，避免无限增长。
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
