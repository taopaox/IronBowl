import Foundation
import IronBowlKit

/// Tita 接口调试日志：`~/Library/Application Support/IronBowl/logs/tita.log`（永不记录 Cookie 明文）。
public nonisolated enum TitaLog {
    public static var url: URL { AppPaths.logsDirectory.appending(path: "tita.log") }
    private static let lock = NSLock()

    static func write(method: String, path: String, status: Int, body: Data) {
        let time = ISO8601DateFormatter().string(from: Date())
        var text = "[\(time)] \(method) \(path) -> \(status)\n"
        text += String(decoding: body.prefix(4000), as: UTF8.self) + "\n\n"
        append(text)
    }

    static func writeError(method: String, path: String, attempt: Int, maxAttempts: Int, error: Error) {
        let time = ISO8601DateFormatter().string(from: Date())
        let nsErr = error as NSError
        var detail = "domain=\(nsErr.domain) code=\(nsErr.code)"
        if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError,
           let sslCode = underlying.userInfo["_kCFNetworkCFStreamSSLErrorOriginalValue"] {
            detail += " ssl=\(sslCode)"
        }
        detail += " \(error.localizedDescription)"
        let text = "[\(time)] \(method) \(path) -> ERROR (\(attempt)/\(maxAttempts)) \(detail)\n\n"
        append(text)
    }

    private static func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
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

/// 保持同源重定向时携带手动传入的 Cookie 请求头。
private final class TitaRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let allowedHostSuffix: String

    init(allowedHost: String?) {
        self.allowedHostSuffix = allowedHost ?? "tita.net"
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var redirected = request
        if let targetHost = request.url?.host?.lowercased(),
           (targetHost == allowedHostSuffix.lowercased() || targetHost.hasSuffix(".tita.net")),
           let originalCookie = task.originalRequest?.value(forHTTPHeaderField: "Cookie"),
           !originalCookie.isEmpty {
            redirected.setValue(originalCookie, forHTTPHeaderField: "Cookie")
        }
        completionHandler(redirected)
    }
}

/// 直连 Tita（`www.tita.net`）周报/月报 HTTP 客户端，基于用户浏览器或内置网页登录提取的 Cookie 鉴权。
public actor TitaClient {
    private let baseURL: URL
    private let cookie: String
    private var tenantID: String
    private var userID: String
    private let session: URLSession
    private let delegate: TitaRedirectDelegate

    public init(
        baseURL: String = "https://www.tita.net",
        cookie: String,
        tenantID: String = "",
        userID: String = ""
    ) throws {
        var trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedBase.hasSuffix("/") { trimmedBase.removeLast() }
        let cleanCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCookie.isEmpty else {
            throw TitaError.notConfigured
        }
        guard !trimmedBase.isEmpty, let url = URL(string: trimmedBase) else {
            throw TitaError.badResponse("无效的 Tita 地址：\(baseURL)")
        }
        self.baseURL = url
        self.cookie = cleanCookie
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20

        let redirectDelegate = TitaRedirectDelegate(allowedHost: url.host)
        self.delegate = redirectDelegate
        self.session = URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }

    /// 结束并释放内部 `URLSession`（用于切换账号/凭证或销毁临时客户端）。
    public nonisolated func invalidate() {
        session.finishTasksAndInvalidate()
    }

    // MARK: - 会话验证与身份探测

    /// 验证 Cookie 是否有效，并自动补全 `tenantId`、`userId` 与姓名。
    public func verifySession() async throws -> TitaAccountInfo {
        var discoveredName = ""
        let (homeData, homeResp) = try await rawRequest(url: baseURL, method: "GET", acceptHTML: true)
        if let finalURL = homeResp.url?.absoluteString.lowercased(), finalURL.contains("/login") {
            throw TitaError.sessionExpired
        }
        if homeResp.statusCode == 401 {
            throw TitaError.sessionExpired
        }
        let html = String(decoding: homeData, as: UTF8.self)
        if html.contains("/login/#/login") && !html.contains("BSGlobal") {
            throw TitaError.sessionExpired
        }

        if let parsed = TitaBSGlobalParser.parse(html: html, finalURL: homeResp.url) {
            if tenantID.isEmpty { tenantID = parsed.tenantID }
            if userID.isEmpty { userID = parsed.userID }
            discoveredName = parsed.userName
        }

        guard !tenantID.isEmpty, !userID.isEmpty else {
            throw TitaError.missingIdentity
        }

        let today = TitaPeriodCode.todayStatusDate()
        let statusEndpoint = "summary/status?summaryDate=\(today)&summaryType=26&subUserId=\(userID)"
        let obj = try await apiRequest(method: "GET", endpoint: statusEndpoint)
        if let dataObj = obj["Data"] as? [String: Any],
           let userObj = dataObj["user"] as? [String: Any],
           let name = userObj["name"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            discoveredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return TitaAccountInfo(tenantID: tenantID, userID: userID, userName: discoveredName)
    }

    // MARK: - 模板、状态与详情查询

    public func fetchTemplates(summaryType: TitaSummaryType) async throws -> [TitaTemplateSummary] {
        let obj = try await apiRequest(
            method: "GET",
            endpoint: "summary/selectTemplates?summaryType=\(summaryType.rawValue)"
        )
        let list = (obj["Data"] as? [[String: Any]]) ?? []
        return Self.parseTemplates(list)
    }

    public func fetchStatus(
        summaryType: TitaSummaryType,
        statusDate: String,
        summaryDate: String
    ) async throws -> TitaPeriodStatus {
        try ensureIdentity()
        let encodedDate = statusDate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? statusDate
        let endpoint = "summary/status?summaryDate=\(encodedDate)&summaryType=\(summaryType.rawValue)&subUserId=\(userID)"
        let obj = try await apiRequest(method: "GET", endpoint: endpoint)
        guard let dataObj = obj["Data"] as? [String: Any] else {
            return TitaPeriodStatus(
                summaryDate: summaryDate,
                summaryType: summaryType,
                state: .none,
                dailyID: "",
                templateID: nil
            )
        }
        return Self.parseStatus(dataObj, summaryType: summaryType, summaryDate: summaryDate)
    }

    public func fetchDetail(summaryType: TitaSummaryType, summaryDate: String) async throws -> TitaReportDetail? {
        let encodedDate = summaryDate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? summaryDate
        let endpoint = "summary/detail?summaryType=\(summaryType.rawValue)&summaryDate=\(encodedDate)"
        let body: [String: Any] = [
            "IsCopy": false,
            "CopyFeedId": "",
            "summaryType": summaryType.rawValue,
            "summaryDate": summaryDate,
        ]
        let obj = try await apiRequest(method: "POST", endpoint: endpoint, jsonBody: body)
        guard let dataObj = obj["Data"] as? [String: Any] else {
            return nil
        }
        return try Self.parseDetail(dataObj, fallbackType: summaryType, fallbackDate: summaryDate)
    }

    public func createSummary(
        summaryType: TitaSummaryType,
        summaryDate: String,
        templateID: Int
    ) async throws -> TitaReportDetail {
        let resolvedID = try await resolveTemplateID(preferred: templateID, summaryType: summaryType)
        do {
            return try await performCreateSummary(summaryType: summaryType, summaryDate: summaryDate, templateID: resolvedID)
        } catch let error as TitaError {
            guard case .apiError(_, let message) = error,
                  message.contains("模板"),
                  let templates = try? await fetchTemplates(summaryType: summaryType),
                  let fallbackID = templates.first?.templateID,
                  fallbackID != resolvedID else {
                throw error
            }
            return try await performCreateSummary(summaryType: summaryType, summaryDate: summaryDate, templateID: fallbackID)
        }
    }

    private func performCreateSummary(
        summaryType: TitaSummaryType,
        summaryDate: String,
        templateID: Int
    ) async throws -> TitaReportDetail {
        let endpoint = "summary/create/\(summaryDate)/\(summaryType.rawValue)/\(templateID)"
        let obj = try await apiRequest(
            method: "POST",
            endpoint: endpoint,
            jsonBody: ["IsCopy": false, "CopyFeedId": ""]
        )
        guard let dataObj = obj["Data"] as? [String: Any] else {
            throw TitaError.badResponse("创建总结草稿失败，未返回 Data")
        }
        return try Self.parseDetail(dataObj, fallbackType: summaryType, fallbackDate: summaryDate)
    }

    private func resolveTemplateID(preferred: Int, summaryType: TitaSummaryType) async throws -> Int {
        if preferred > 0 {
            return preferred
        }
        if let templates = try? await fetchTemplates(summaryType: summaryType),
           let first = templates.first {
            return first.templateID
        }
        return summaryType == .weekly ? 1006 : 1007
    }

    // MARK: - 写入草稿与正式提交

    public func updateMood(feedID: String, moduleID: Int, mood: TitaMood) async throws {
        _ = try await apiRequest(
            method: "POST",
            endpoint: "summary/mood/update/\(feedID)/\(moduleID)/\(mood.rawValue)",
            jsonBody: [:]
        )
    }

    public func updateRichText(
        feedID: String,
        moduleID: Int,
        content: TitaRichTextConverter.ConvertedContent
    ) async throws {
        let body: [String: Any] = [
            "FeedId": feedID,
            "ModuleId": moduleID,
            "Text": content.plainText,
            "RichText": content.richText,
            "AiteUsers": [Any](),
            "TextType": "1",
        ]
        _ = try await apiRequest(method: "POST", endpoint: "summary/richtext/update", jsonBody: body)
    }

    /// 保存为 Tita 草稿（不提交）：若周期内尚未建表则先初始化草稿，再逐模块写入富文本与心情。
    public func saveDraft(
        summaryType: TitaSummaryType,
        summaryDate: String,
        templateID: Int,
        moduleTexts: [String],
        mood: TitaMood?
    ) async throws -> TitaReportDetail {
        let detail = try await prepareAndSaveModules(
            summaryType: summaryType,
            summaryDate: summaryDate,
            templateID: templateID,
            moduleTexts: moduleTexts,
            mood: mood
        ).detail
        return (try? await fetchDetail(summaryType: summaryType, summaryDate: summaryDate)) ?? detail
    }

    /// 正式提交 / 更新 Tita 周报或月报，并在提交后回查状态。
    public func submitReport(
        summaryType: TitaSummaryType,
        summaryDate: String,
        statusDate: String,
        templateID: Int,
        moduleTexts: [String],
        mood: TitaMood?
    ) async throws -> TitaPeriodStatus {
        let prepared = try await prepareAndSaveModules(
            summaryType: summaryType,
            summaryDate: summaryDate,
            templateID: templateID,
            moduleTexts: moduleTexts,
            mood: mood
        )

        // 提交前重新拉取一次详情，确保 OKR / 附件 / @ta查看 等其他模块的 objectData 最新且不被覆盖。
        let latestDetail = (try? await fetchDetail(summaryType: summaryType, summaryDate: summaryDate)) ?? prepared.detail

        _ = try? await apiRequest(
            method: "POST",
            endpoint: "summary/checkchange/\(latestDetail.dailyID)",
            jsonBody: [:]
        )

        let submitBody = try TitaSubmitPayloadBuilder.buildSubmitBody(
            detail: latestDetail,
            updatedRichTexts: prepared.convertedByModuleID
        )
        _ = try await apiRequest(
            method: "POST",
            endpoint: "summary/submit/\(latestDetail.dailyID)/1",
            jsonBody: submitBody
        )

        let status = try await fetchStatus(summaryType: summaryType, statusDate: statusDate, summaryDate: summaryDate)
        return status
    }

    // MARK: - 历史列表分页查询

    /// 分页拉取 Tita 个人历史周报 / 月报列表（`summary/search` 已直接包含完整 `dailyContent[]`）。
    public func searchSummaries(
        summaryType: TitaSummaryType,
        pageNum: Int,
        pageSize: Int = 10
    ) async throws -> TitaSearchPage {
        let body: [String: Any] = [
            "pageNum": pageNum,
            "pageSize": pageSize,
            "relation": 1,
            "startTime": "",
            "endTime": "",
            "searchDepartmentIds": [""],
            "searchUserIds": [""],
            "searchGroupIds": [""],
            "summaryType": summaryType.rawValue,
        ]
        let obj = try await apiRequest(method: "POST", endpoint: "summary/search", jsonBody: body)
        guard let dataObj = obj["Data"] as? [String: Any] else {
            return TitaSearchPage(feeds: [], isEnd: true, lastID: nil)
        }

        let isEnd = (dataObj["isEnd"] as? Bool) ?? true
        let lastID = dataObj["lastId"] as? String
        let rawFeeds = (dataObj["feeds"] as? [[String: Any]]) ?? []

        let feeds: [TitaSearchFeedItem] = rawFeeds.compactMap { item in
            let feedID = ((item["feedId"] as? String) ?? (item["dailyId"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dailyDate = ((item["dailyDate"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feedID.isEmpty || !dailyDate.isEmpty else { return nil }

            let typeInt = Self.int(item["reportType"] ?? item["summaryType"]) ?? summaryType.rawValue
            let reportType = TitaSummaryType(rawValue: typeInt) ?? summaryType
            let name = ((item["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let submitState = TitaSubmitState(rawInt: Self.int(item["submitState"]))
            let submitDate = item["submitDate"] as? String
            let createDate = item["createDate"] as? String
            let newSummary = (item["newSummary"] as? Bool) ?? true

            let rawSections = (item["dailyContent"] as? [[String: Any]]) ?? []
            let sections: [TitaSearchFeedSection] = rawSections.map { sec in
                TitaSearchFeedSection(
                    contentType: Self.int(sec["contentType"]) ?? 0,
                    title: ((sec["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    richContent: (sec["richContent"] as? String) ?? "",
                    content: (sec["content"] as? String) ?? ""
                )
            }

            let legacyContentHTML = (item["contentRichText"] as? String) ?? ""
            let legacyWorkPlanHTML = (item["workPlanRichText"] as? String) ?? ""

            return TitaSearchFeedItem(
                feedID: feedID,
                dailyDate: dailyDate,
                reportType: reportType,
                name: name,
                submitState: submitState,
                submitDate: submitDate,
                createDate: createDate,
                newSummary: newSummary,
                sections: sections,
                legacyContentHTML: legacyContentHTML,
                legacyWorkPlanHTML: legacyWorkPlanHTML
            )
        }

        return TitaSearchPage(feeds: feeds, isEnd: isEnd, lastID: lastID)
    }

    /// 自动翻页拉取全部历史周报或月报并按 `feedId` 去重。
    public func fetchAllSummaries(
        summaryType: TitaSummaryType,
        pageSize: Int = 10,
        maxPages: Int = 100
    ) async throws -> [TitaSearchFeedItem] {
        var seen = Set<String>()
        var all: [TitaSearchFeedItem] = []

        for pageNum in 1...maxPages {
            let page = try await searchSummaries(summaryType: summaryType, pageNum: pageNum, pageSize: pageSize)
            if page.feeds.isEmpty { break }
            for item in page.feeds {
                let key = item.feedID.isEmpty ? "\(item.reportType.rawValue)-\(item.dailyDate)" : item.feedID
                if seen.insert(key).inserted {
                    all.append(item)
                }
            }
            if page.isEnd { break }
        }
        return all
    }

    // MARK: - 内部实现

    private func prepareAndSaveModules(
        summaryType: TitaSummaryType,
        summaryDate: String,
        templateID: Int,
        moduleTexts: [String],
        mood: TitaMood?
    ) async throws -> (detail: TitaReportDetail, convertedByModuleID: [Int: TitaRichTextConverter.ConvertedContent]) {
        let detail: TitaReportDetail
        if let existing = try await fetchDetail(summaryType: summaryType, summaryDate: summaryDate) {
            detail = existing
        } else {
            detail = try await createSummary(summaryType: summaryType, summaryDate: summaryDate, templateID: templateID)
        }

        if let mood, let moodModule = detail.moodModule {
            try await updateMood(feedID: detail.dailyID, moduleID: moodModule.moduleId, mood: mood)
        }

        let richtexts = detail.richtextModules
        var convertedMap: [Int: TitaRichTextConverter.ConvertedContent] = [:]
        for (index, module) in richtexts.enumerated() {
            let markdown = index < moduleTexts.count ? moduleTexts[index] : ""
            let converted = TitaRichTextConverter.convert(markdown: markdown)
            convertedMap[module.moduleId] = converted
            try await updateRichText(feedID: detail.dailyID, moduleID: module.moduleId, content: converted)
        }
        return (detail, convertedMap)
    }

    private func ensureIdentity() throws {
        guard !tenantID.isEmpty, !userID.isEmpty else {
            throw TitaError.missingIdentity
        }
    }

    private func apiRequest(
        method: String,
        endpoint: String,
        jsonBody: [String: Any]? = nil
    ) async throws -> [String: Any] {
        try ensureIdentity()
        let urlString = "\(baseURL.absoluteString)/api/v1/\(tenantID)/\(userID)/\(endpoint)"
        guard let url = URL(string: urlString) else {
            throw TitaError.badResponse("无效的接口路径：\(endpoint)")
        }

        let bodyData: Data?
        if let jsonBody {
            bodyData = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        } else {
            bodyData = nil
        }

        let (data, response) = try await rawRequest(url: url, method: method, body: bodyData, acceptHTML: false)
        if response.statusCode == 401 {
            throw TitaError.sessionExpired
        }
        if let finalURL = response.url?.absoluteString.lowercased(), finalURL.contains("/login") {
            throw TitaError.sessionExpired
        }
        guard (200..<300).contains(response.statusCode) else {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            throw TitaError.httpError(response.statusCode, preview)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw TitaError.badResponse(String(decoding: data, as: UTF8.self))
        }

        let code = Self.int(obj["Code"]) ?? -1
        if code != 1 {
            let msg = ((obj["Message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 401 || msg.contains("登录") || msg.localizedCaseInsensitiveContains("unauthorized") {
                throw TitaError.sessionExpired
            }
            throw TitaError.apiError(code: code, message: msg)
        }
        return obj
    }

    private func rawRequest(
        url: URL,
        method: String,
        body: Data? = nil,
        acceptHTML: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        req.setValue("\(baseURL.absoluteString)/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if acceptHTML {
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        } else {
            req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }

        let pathForLog = url.path + (url.query.map { "?\($0)" } ?? "")
        let maxAttempts = 3
        let retryDelays: [Duration] = [.milliseconds(300), .milliseconds(800)]

        for attempt in 1...maxAttempts {
            do {
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? -1
                TitaLog.write(method: method, path: pathForLog, status: status, body: acceptHTML ? Data("[HTML length=\(data.count)]".utf8) : data)
                guard let http else {
                    throw TitaError.badResponse("非 HTTP 响应")
                }
                return (data, http)
            } catch {
                TitaLog.writeError(method: method, path: pathForLog, attempt: attempt, maxAttempts: maxAttempts, error: error)
                if attempt < maxAttempts, Self.shouldRetryTransportError(error, method: method, path: pathForLog) {
                    try await Task.sleep(for: retryDelays[attempt - 1])
                    continue
                }
                throw Self.mapTransportError(error)
            }
        }
        throw TitaError.badResponse("请求未执行")
    }

    nonisolated static func shouldRetryTransportError(_ error: Error, method: String, path: String) -> Bool {
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cancelled:
            return false
        case .secureConnectionFailed, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            // TLS 握手或 TCP 建连阶段失败时尚未发送任何 HTTP 请求体，GET/POST 均可安全重试。
            return true
        case .timedOut, .networkConnectionLost:
            if method.uppercased() == "GET" { return true }
            let lowerPath = path.lowercased()
            return lowerPath.contains("summary/detail")
                || lowerPath.contains("summary/search")
                || lowerPath.contains("summary/checkchange")
                || lowerPath.contains("summary/richtext/update")
                || lowerPath.contains("summary/mood/update")
        default:
            return false
        }
    }

    nonisolated static func mapTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError, urlError.code == .secureConnectionFailed else {
            return error
        }
        return TitaError.networkError("与 Tita 建立 TLS 安全连接失败（已自动重试）。若本机开启了代理/TUN，建议将 tita.net 加入直连规则后重试。")
    }

    nonisolated static func parseTemplates(_ list: [[String: Any]]) -> [TitaTemplateSummary] {
        list.compactMap { item in
            guard let id = positiveInt(item["id"] ?? item["templateId"]) else { return nil }
            let name = ((item["name"] as? String) ?? (item["templateName"] as? String) ?? "模板 \(id)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let modules = ((item["summaryTemplateModules"] as? [[String: Any]]) ?? [])
                .filter { ($0["moduleType"] as? String) == "richtext" && (int($0["moduleObjType"]) ?? 0) == 0 }
                .sorted { (int($0["sortIndex"]) ?? 0) < (int($1["sortIndex"]) ?? 0) }
                .compactMap { ($0["moduleName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return TitaTemplateSummary(templateID: id, name: name, richtextModuleNames: modules)
        }
    }

    nonisolated static func parseStatus(
        _ dataObj: [String: Any],
        summaryType: TitaSummaryType,
        summaryDate: String
    ) -> TitaPeriodStatus {
        TitaPeriodStatus(
            summaryDate: summaryDate,
            summaryType: summaryType,
            state: TitaSubmitState(rawInt: int(dataObj["summaryStatus"] ?? dataObj["summaryStatu"])),
            dailyID: (dataObj["summaryId"] as? String) ?? "",
            templateID: positiveInt(dataObj["tempId"]),
            submitDate: dataObj["submitDate"] as? String,
            delayDate: dataObj["delayDate"] as? String
        )
    }

    nonisolated static func parseDetail(
        _ dataObj: [String: Any],
        fallbackType: TitaSummaryType,
        fallbackDate: String
    ) throws -> TitaReportDetail {
        let dailyID = (dataObj["dailyId"] as? String) ?? ""
        guard !dailyID.isEmpty else {
            throw TitaError.badResponse("详情缺少 dailyId")
        }
        let summaryType = int(dataObj["summaryType"]).flatMap(TitaSummaryType.init(rawValue:)) ?? fallbackType
        let summaryDate = (dataObj["dailyDate"] as? String) ?? fallbackDate
        let submitState = TitaSubmitState(rawInt: int(dataObj["submitState"]))
        let templateID = positiveInt(dataObj["summaryTemplateId"]) ?? (summaryType == .weekly ? 1006 : 1007)
        let delayDate = dataObj["delayDate"] as? String

        let rawDetails = (dataObj["details"] as? [[String: Any]]) ?? []
        let modules: [TitaReportModule] = rawDetails.compactMap { item in
            guard let moduleId = int(item["moduleId"]) else { return nil }
            let moduleName = ((item["moduleName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let moduleType = (item["moduleType"] as? String) ?? ""
            let moduleObjType = int(item["moduleObjType"]) ?? 0
            let sortIndex = int(item["sortIndex"]) ?? 0
            let isDelete = (item["isDelete"] as? Bool) ?? false

            let objData = item["objectData"]
            let rawObjectDataJSON: String
            var plainText = ""
            var richTextHTML = ""

            if let dict = objData as? [String: Any] {
                plainText = (dict["text"] as? String) ?? ""
                richTextHTML = (dict["richText"] as? String) ?? ""
                if plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !richTextHTML.isEmpty {
                    plainText = TitaRichTextConverter.plainTextFromHTML(richTextHTML)
                }
                if let d = try? JSONSerialization.data(withJSONObject: dict, options: []) {
                    rawObjectDataJSON = String(decoding: d, as: UTF8.self)
                } else {
                    rawObjectDataJSON = "{}"
                }
            } else if let str = objData as? String {
                rawObjectDataJSON = str
            } else if let num = int(objData) {
                rawObjectDataJSON = "\(num)"
            } else {
                rawObjectDataJSON = ""
            }

            return TitaReportModule(
                moduleId: moduleId,
                moduleName: moduleName,
                moduleType: moduleType,
                moduleObjType: moduleObjType,
                sortIndex: sortIndex,
                isDelete: isDelete,
                plainText: plainText,
                richTextHTML: richTextHTML,
                rawObjectDataJSON: rawObjectDataJSON
            )
        }

        return TitaReportDetail(
            dailyID: dailyID,
            summaryDate: summaryDate,
            summaryType: summaryType,
            submitState: submitState,
            templateID: templateID,
            delayDate: delayDate,
            modules: modules
        )
    }

    nonisolated private static func positiveInt(_ v: Any?) -> Int? {
        guard let value = int(v), value > 0 else { return nil }
        return value
    }

    nonisolated private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let d = v as? Double { return Int(d) }
        return nil
    }
}
