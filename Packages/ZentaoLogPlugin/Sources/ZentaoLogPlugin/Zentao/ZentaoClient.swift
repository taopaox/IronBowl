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
    public let objectType: String
    public let objectTitle: String?
    public let projectID: Int?

    public init(
        taskID: Int,
        date: String,
        consumed: Double,
        left: Double,
        work: String,
        account: String,
        objectType: String = "task",
        objectTitle: String? = nil,
        projectID: Int? = nil
    ) {
        self.taskID = taskID
        self.date = date
        self.consumed = consumed
        self.left = left
        self.work = work
        self.account = account
        self.objectType = objectType
        self.objectTitle = objectTitle
        self.projectID = projectID
    }
}

public nonisolated enum ZentaoError: LocalizedError, Sendable {
    case notConfigured
    case loginFailed(String)
    case badResponse(String)
    case submitFailed(taskID: Int, reason: String)
    case submitNotVerified(taskID: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "还没填写禅道地址、账号和密码"
        case .loginFailed(let r): "禅道登录失败：\(r)"
        case .badResponse(let s): "禅道返回了看不懂的内容：\(s.prefix(200))"
        case .submitFailed(let id, let reason): "任务 #\(id) 提交失败：\(reason)"
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
    private var supportsEffortModule: Bool?

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
        config.httpShouldSetCookies = true
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
            supportsEffortModule = Self.detectEffortModule(obj ?? [:])
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
        Self.parseTasks(try await getJSON("my-task-assignedTo-id_desc-0-500-1.json"))
    }

    /// 我近期完成过的任务（避免任务完成后从指派列表消失而查不到已写工时）。
    public func finishedTasks() async throws -> [ZentaoTask] {
        Self.parseTasks(try await getJSON("my-task-finishedBy-id_desc-0-100-1.json"))
    }

    private static func parseTasks(_ obj: [String: Any]) -> [ZentaoTask] {
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
        try await ensureLogin()
        if supportsEffortModule != false {
            let obj = try await getJSON("effort-createForObject-task-\(taskID).json")
            if let efforts = Self.parseEfforts(obj, fallbackTaskID: taskID) {
                supportsEffortModule = true
                return efforts.sorted { $0.date < $1.date }
            }
            if supportsEffortModule == nil {
                supportsEffortModule = false
            }
        }
        let obj = try await getJSON("task-recordEstimate-\(taskID).json")
        let raw: [[String: Any]]
        if let arr = obj["estimates"] as? [[String: Any]] {
            raw = arr
        } else if let dict = obj["estimates"] as? [String: [String: Any]] {
            raw = dict.sorted { (Int($0.key) ?? Int.max, $0.key) < (Int($1.key) ?? Int.max, $1.key) }.map(\.value)
        } else if let efforts = Self.parseEfforts(obj, fallbackTaskID: taskID) {
            return efforts.sorted { $0.date < $1.date }
        } else {
            raw = []
        }
        return raw.map { e in
            ZentaoEstimate(
                taskID: taskID,
                date: String(((e["date"] as? String) ?? "").prefix(10)),
                consumed: Self.double(e["consumed"]) ?? 0,
                left: Self.double(e["left"]) ?? 0,
                work: ((e["work"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                account: (e["account"] as? String) ?? ""
            )
        }
    }

    /// 我在某天对这些任务记过的工时。
    public func myEstimates(on date: String, taskIDs: [Int]) async throws -> [ZentaoEstimate] {
        let grouped = try await myEstimates(since: date, taskIDs: taskIDs)
        return (grouped[date] ?? []).filter { $0.date == date }
    }

    /// 并发拉取从 `minDate`（yyyy-MM-dd）起各任务的工时记录，按日期分组返回。
    public func myEstimates(since minDate: String, taskIDs: [Int]) async throws -> [String: [ZentaoEstimate]] {
        try await ensureLogin()
        if supportsEffortModule != false {
            if let efforts = try await myEfforts(since: minDate) {
                supportsEffortModule = true
                return Dictionary(grouping: efforts, by: \.date)
            }
            if supportsEffortModule == nil {
                supportsEffortModule = false
            }
        }
        let unique = Array(Set(taskIDs))
        guard !unique.isEmpty else { return [:] }
        var grouped: [String: [ZentaoEstimate]] = [:]
        let batchSize = 6
        for start in stride(from: 0, to: unique.count, by: batchSize) {
            let batch = unique[start..<min(start + batchSize, unique.count)]
            let batchResults = await withTaskGroup(of: [ZentaoEstimate].self) { group in
                for id in batch {
                    group.addTask {
                        (try? await self.estimates(taskID: id)) ?? []
                    }
                }
                var collected: [ZentaoEstimate] = []
                for await list in group {
                    collected.append(contentsOf: list)
                }
                return collected
            }
            for e in batchResults where e.date >= minDate && (e.account.isEmpty || e.account == account) {
                grouped[e.date, default: []].append(e)
            }
        }
        return grouped
    }

    private func myEfforts(since minDate: String) async throws -> [ZentaoEstimate]? {
        var collected: [ZentaoEstimate] = []
        let maxPages = 5
        for page in 1...maxPages {
            let obj = try await getJSON("my-effort-all-date_desc-0-100-\(page).json")
            guard let list = Self.parseEfforts(obj) else {
                return page == 1 ? nil : collected
            }
            for e in list where e.date >= minDate && (e.account.isEmpty || e.account == account) {
                collected.append(e)
            }
            let pager = obj["pager"] as? [String: Any]
            let pageTotal = Self.int(pager?["pageTotal"]) ?? 1
            let oldestDate = list.map(\.date).filter { !$0.isEmpty }.min()
            if list.isEmpty || oldestDate == nil || oldestDate! < minDate || page >= min(pageTotal, maxPages) {
                break
            }
        }
        return collected
    }

    /// 给任务记一条工时，提交后回查确认。
    public func recordEstimate(taskID: Int, date: String, consumed: Double, left: Double, work: String) async throws {
        try await ensureLogin()
        let before = try await estimates(taskID: taskID).count
        let trimmedWork = work.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        var form: [String: String] = [
            "id[1]": "1",
            "dates[1]": date,
            "consumed[1]": Self.format(consumed),
            "left[1]": Self.format(left),
            "work[1]": work,
        ]
        if supportsEffortModule == true {
            path = "effort-createForObject-task-\(taskID).json"
            form["objectType[1]"] = "task"
            form["objectID[1]"] = String(taskID)
        } else {
            path = "task-recordEstimate-\(taskID).json"
        }
        let postData = try await postForm(path, form: form)
        if let reason = Self.failureReason(postData) {
            throw ZentaoError.submitFailed(taskID: taskID, reason: reason)
        }
        let after = try await estimates(taskID: taskID)
        let found = after.count > before
            || after.contains {
                $0.date == date
                    && abs($0.consumed - consumed) < 0.01
                    && $0.work.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedWork
            }
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

    private func postForm(_ path: String, form: [String: String], retry: Bool = true) async throws -> Data {
        try await ensureLogin()
        let (data, http) = try await request(path, form: form)
        if Self.looksLoggedOut(data) {
            guard retry else { throw ZentaoError.loginFailed("会话已失效") }
            loggedIn = false
            return try await postForm(path, form: form, retry: false)
        }
        guard (200..<400).contains(http.statusCode) else {
            throw ZentaoError.badResponse("HTTP \(http.statusCode)")
        }
        return data
    }

    static func failureReason(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let result = (obj["result"] as? String)?.lowercased()
        let status = (obj["status"] as? String)?.lowercased()
        let isFailure = result == "fail" || status == "fail" || status == "error"
        guard isFailure else { return nil }
        if let msg = extractMessage(obj["message"]), !msg.isEmpty { return msg }
        if let reason = obj["reason"] as? String, !reason.isEmpty { return reason }
        return "禅道返回失败（\(result ?? status ?? "fail")）"
    }

    private static func extractMessage(_ value: Any?) -> String? {
        if let s = value as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = value as? [Any] {
            let parts = arr.compactMap { extractMessage($0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "；")
        }
        if let dict = value as? [String: Any] {
            let parts = dict.sorted { $0.key < $1.key }.compactMap { k, v -> String? in
                guard let text = extractMessage(v), !text.isEmpty else { return nil }
                return "\(k)：\(text)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: "；")
        }
        return nil
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

    static func detectEffortModule(_ loginResponse: [String: Any]) -> Bool? {
        guard let user = loginResponse["user"] as? [String: Any],
              let outerRights = user["rights"] as? [String: Any],
              let rights = outerRights["rights"] as? [String: Any] else {
            return nil
        }
        if let effort = rights["effort"] as? [String: Any], !effort.isEmpty {
            return true
        }
        if let my = rights["my"] as? [String: Any], my["effort"] as? Bool == true {
            return true
        }
        return false
    }

    static func parseEfforts(_ obj: [String: Any], fallbackTaskID: Int? = nil) -> [ZentaoEstimate]? {
        let raw: [[String: Any]]
        if let arr = obj["efforts"] as? [[String: Any]] {
            raw = arr
        } else if let dict = obj["efforts"] as? [String: [String: Any]] {
            raw = dict.sorted { (Int($0.key) ?? Int.max, $0.key) < (Int($1.key) ?? Int.max, $1.key) }.map(\.value)
        } else {
            return nil
        }
        return raw.compactMap { e in
            if Self.int(e["deleted"]) == 1 { return nil }
            let rawType = ((e["objectType"] as? String) ?? "task")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let objectType = rawType.isEmpty ? "task" : rawType
            let taskID = objectType == "task"
                ? (Self.int(e["objectID"]) ?? Self.int(e["task"]) ?? fallbackTaskID ?? 0)
                : 0
            let rawTitle = ((e["objectTitle"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ZentaoEstimate(
                taskID: taskID,
                date: String(((e["date"] as? String) ?? "").prefix(10)),
                consumed: Self.double(e["consumed"]) ?? 0,
                left: Self.double(e["left"]) ?? 0,
                work: ((e["work"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                account: (e["account"] as? String) ?? "",
                objectType: objectType,
                objectTitle: rawTitle.isEmpty ? nil : rawTitle,
                projectID: Self.int(e["project"])
            )
        }
    }

    static func looksLoggedOut(_ data: Data) -> Bool {
        if let inner = try? payload(data),
           let locate = inner["locate"] as? String,
           locate.contains("user-login") {
            return true
        }
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
