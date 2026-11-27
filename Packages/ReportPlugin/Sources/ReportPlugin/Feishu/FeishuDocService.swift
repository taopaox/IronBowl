import Foundation
import IronBowlKit

/// 飞书 CLI 用户授权状态。
public nonisolated struct FeishuAuthStatus: Sendable, Equatable {
    public let isAvailable: Bool
    public let status: String
    public let userName: String
    public let tokenStatus: String
    public let hint: String

    public init(isAvailable: Bool, status: String, userName: String, tokenStatus: String, hint: String) {
        self.isAvailable = isAvailable
        self.status = status
        self.userName = userName
        self.tokenStatus = tokenStatus
        self.hint = hint
    }
}

/// 飞书设备流授权响应。
public nonisolated struct FeishuDeviceLoginInfo: Sendable, Equatable {
    public let verificationURL: String
    public let userCode: String
    public let deviceCode: String
    public let expiresIn: Int

    public init(verificationURL: String, userCode: String, deviceCode: String, expiresIn: Int) {
        self.verificationURL = verificationURL
        self.userCode = userCode
        self.deviceCode = deviceCode
        self.expiresIn = expiresIn
    }
}

/// 读取到的飞书文档内容。
public nonisolated struct FeishuFetchedDoc: Sendable, Equatable {
    public let docURL: String
    public let title: String
    public let markdown: String

    public init(docURL: String, title: String, markdown: String) {
        self.docURL = docURL
        self.title = title
        self.markdown = markdown
    }
}

/// 覆盖写入并回读确认的结果。
public nonisolated struct FeishuDocWriteResult: Sendable, Equatable {
    public let docURL: String
    public let verifiedTitle: String
    public let verifiedCharCount: Int
    public let preview: String

    public init(docURL: String, verifiedTitle: String, verifiedCharCount: Int, preview: String) {
        self.docURL = docURL
        self.verifiedTitle = verifiedTitle
        self.verifiedCharCount = verifiedCharCount
        self.preview = preview
    }
}

/// 飞书 CLI 操作错误。
public nonisolated enum FeishuCLIError: LocalizedError, Sendable, Equatable {
    case cliNotFound
    case invalidDocURL
    case emptyContent
    case authExpired(String)
    case commandFailed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "未在本机找到 `lark-cli`，请先安装飞书 CLI 或在「设置 → 月报」指定可执行文件路径。"
        case .invalidDocURL:
            "请输入有效的飞书文档链接或文档 Token。"
        case .emptyContent:
            "当前月报/周报正文为空，无法写入飞书文档。"
        case .authExpired(let detail):
            detail.isEmpty ? "飞书用户授权已过期或尚未登录，请发起设备登录授权后重试。" : "飞书用户授权已过期：\(detail)"
        case .commandFailed(let detail):
            detail.isEmpty ? "飞书 CLI 执行失败" : detail
        case .invalidOutput(let sample):
            "无法解析飞书 CLI 返回结果：\(sample.prefix(160))"
        }
    }
}

/// 基于本机 `lark-cli` 的飞书文档读写与授权服务。
public nonisolated enum FeishuDocService {
    /// 解析 `lark-cli` 可执行路径：优先使用用户配置路径，否则依次查找登录 shell PATH、nvm、Homebrew 与 `/usr/local/bin`。
    @concurrent
    public static func resolveCLIPath(configuredPath: String) async -> String? {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        if let path = await Shell.which("lark-cli"), FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        var candidates: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for version in versions.sorted(by: >) {
                candidates.append("\(nvmDir)/\(version)/bin/lark-cli")
            }
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/lark-cli",
            "/usr/local/bin/lark-cli",
            "\(home)/.local/bin/lark-cli",
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 检查当前飞书 CLI 用户态授权。
    @concurrent
    public static func checkAuthStatus(cliPath: String) async throws -> FeishuAuthStatus {
        let r = try await Shell.run(cliPath, ["auth", "status", "--json"], timeout: 15)
        let combined = [r.stdout, r.stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        return try parseAuthStatus(combined)
    }

    /// 发起飞书设备流授权，返回待用户浏览器确认的链接与设备码。
    @concurrent
    public static func startDeviceLogin(cliPath: String) async throws -> FeishuDeviceLoginInfo {
        let r = try await Shell.run(
            cliPath,
            ["auth", "login", "--no-wait", "--json", "--domain", "docs,wiki,drive,okr"],
            timeout: 20
        )
        let combined = [r.stdout, r.stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        return try parseDeviceLogin(combined)
    }

    /// 轮询完成飞书设备流授权并回查授权状态。
    @concurrent
    public static func completeDeviceLogin(cliPath: String, deviceCode: String) async throws -> FeishuAuthStatus {
        let cleanCode = deviceCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCode.isEmpty else {
            throw FeishuCLIError.commandFailed("缺少 device_code，请重新发起授权。")
        }
        let r = try await Shell.run(
            cliPath,
            ["auth", "login", "--device-code", cleanCode, "--json"],
            timeout: 90
        )
        let combined = [r.stdout, r.stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        if r.status != 0 {
            if let err = extractCLIError(from: combined) {
                throw err
            }
            throw FeishuCLIError.commandFailed(combined)
        }
        return try await checkAuthStatus(cliPath: cliPath)
    }

    /// 以用户身份读取飞书云文档或知识库文档的 Markdown 正文。
    @concurrent
    public static func fetchDocumentMarkdown(cliPath: String, docURL: String) async throws -> FeishuFetchedDoc {
        let cleanURL = docURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { throw FeishuCLIError.invalidDocURL }

        let r = try await Shell.run(
            cliPath,
            ["docs", "+fetch", "--as", "user", "--doc", cleanURL, "--doc-format", "markdown", "--format", "json"],
            timeout: 30
        )
        let combined = [r.stdout, r.stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        if r.status != 0 {
            if let err = extractCLIError(from: combined) { throw err }
            throw FeishuCLIError.commandFailed(combined)
        }
        return try parseFetchedDoc(combined, docURL: cleanURL)
    }

    /// 尝试列出知识库节点下的直接子文档并逐一读取 Markdown（非 Wiki 节点或无子文档时返回空数组）。
    @concurrent
    public static func fetchChildDocuments(cliPath: String, parentDocURL: String) async throws -> [FeishuFetchedDoc] {
        let cleanURL = parentDocURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return [] }

        let nodeRes = try await Shell.run(
            cliPath,
            ["wiki", "+node-get", "--as", "user", "--node-token", cleanURL, "--format", "json"],
            timeout: 20
        )
        let nodeText = [nodeRes.stdout, nodeRes.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        if nodeRes.status != 0 {
            if let err = extractCLIError(from: nodeText), case .authExpired = err {
                throw err
            }
            return []
        }

        guard let nodeInfo = parseWikiNodeInfo(nodeText) else {
            return []
        }

        let listRes = try await Shell.run(
            cliPath,
            [
                "wiki", "+node-list", "--as", "user",
                "--space-id", nodeInfo.spaceID,
                "--parent-node-token", nodeInfo.nodeToken,
                "--page-all", "--format", "json",
            ],
            timeout: 30
        )
        let listText = [listRes.stdout, listRes.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        guard listRes.status == 0 else {
            if let err = extractCLIError(from: listText), case .authExpired = err {
                throw err
            }
            return []
        }

        let children = parseWikiChildNodes(listText)
        guard !children.isEmpty else { return [] }

        var fetchedChildren: [FeishuFetchedDoc] = []
        for child in children {
            let target = child.url ?? buildDocReference(from: child, baseDocURL: cleanURL)
            if let doc = try? await fetchDocumentMarkdown(cliPath: cliPath, docURL: target) {
                let resolvedTitle = doc.title.isEmpty ? child.title : doc.title
                fetchedChildren.append(FeishuFetchedDoc(docURL: doc.docURL, title: resolvedTitle, markdown: doc.markdown))
            }
        }
        return fetchedChildren
    }

    /// 使用 Markdown 覆盖写入目标飞书文档，写入后立即回读验证。
    @concurrent
    public static func overwriteDocument(
        cliPath: String,
        docURL: String,
        markdown: String
    ) async throws -> FeishuDocWriteResult {
        let cleanURL = docURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { throw FeishuCLIError.invalidDocURL }
        let cleanContent = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanContent.isEmpty else { throw FeishuCLIError.emptyContent }

        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "ironbowl-feishu-\(UUID().uuidString).md")
        try cleanContent.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let r = try await Shell.run(
            cliPath,
            [
                "docs", "+update",
                "--as", "user",
                "--doc", cleanURL,
                "--command", "overwrite",
                "--doc-format", "markdown",
                "--content", "@\(tempURL.path)",
                "--revision-id", "-1",
                "--format", "json",
            ],
            timeout: 45
        )
        let combined = [r.stdout, r.stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        if r.status != 0 {
            if let err = extractCLIError(from: combined) { throw err }
            throw FeishuCLIError.commandFailed(combined)
        }
        if let err = extractCLIError(from: combined) {
            throw err
        }

        let verified = try await fetchDocumentMarkdown(cliPath: cliPath, docURL: cleanURL)
        let preview = verified.markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: " / ")

        return FeishuDocWriteResult(
            docURL: cleanURL,
            verifiedTitle: verified.title,
            verifiedCharCount: verified.markdown.count,
            preview: preview
        )
    }

    // MARK: - 纯解析辅助（便于单测）

    public static func parseAuthStatus(_ raw: String) throws -> FeishuAuthStatus {
        guard let obj = extractJSONDictionary(from: raw) else {
            throw FeishuCLIError.invalidOutput(raw)
        }
        if let err = extractCLIError(from: obj) {
            throw err
        }
        let identities = (obj["identities"] as? [String: Any]) ?? [:]
        let user = (identities["user"] as? [String: Any]) ?? obj
        let available = (user["available"] as? Bool) ?? false
        let status = (user["status"] as? String) ?? (available ? "ready" : "missing")
        let userName = (user["userName"] as? String) ?? (user["name"] as? String) ?? ""
        let tokenStatus = (user["tokenStatus"] as? String) ?? ""
        let hint = (user["hint"] as? String) ?? (user["message"] as? String) ?? ""
        return FeishuAuthStatus(
            isAvailable: available,
            status: status,
            userName: userName,
            tokenStatus: tokenStatus,
            hint: hint
        )
    }

    public static func parseDeviceLogin(_ raw: String) throws -> FeishuDeviceLoginInfo {
        if let obj = extractJSONDictionary(from: raw) {
            if let err = extractCLIError(from: obj) {
                throw err
            }
            let payload = (obj["data"] as? [String: Any]) ?? obj
            let url = (payload["verification_url"] as? String)
                ?? (payload["verification_uri_complete"] as? String)
                ?? (payload["verification_uri"] as? String)
                ?? ""
            let deviceCode = (payload["device_code"] as? String) ?? ""
            var userCode = (payload["user_code"] as? String) ?? ""
            if userCode.isEmpty,
               let comps = URLComponents(string: url),
               let queryCode = comps.queryItems?.first(where: { $0.name == "user_code" })?.value {
                userCode = queryCode
            }
            let expiresIn = (payload["expires_in"] as? Int) ?? 600
            if !url.isEmpty, !deviceCode.isEmpty {
                return FeishuDeviceLoginInfo(
                    verificationURL: url,
                    userCode: userCode,
                    deviceCode: deviceCode,
                    expiresIn: expiresIn
                )
            }
        }
        throw FeishuCLIError.invalidOutput(raw)
    }

    public static func parseFetchedDoc(_ raw: String, docURL: String) throws -> FeishuFetchedDoc {
        guard let obj = extractJSONDictionary(from: raw) else {
            throw FeishuCLIError.invalidOutput(raw)
        }
        if let err = extractCLIError(from: obj) {
            throw err
        }
        let dataObj = (obj["data"] as? [String: Any]) ?? obj
        let docMeta = (dataObj["document"] as? [String: Any]) ?? [:]
        let title = ((dataObj["title"] as? String) ?? (docMeta["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = ((dataObj["content"] as? String) ?? (dataObj["markdown"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FeishuFetchedDoc(docURL: docURL, title: title, markdown: markdown)
    }

    struct WikiNodeRef: Sendable {
        let spaceID: String
        let nodeToken: String
        let objToken: String
        let objType: String
        let title: String
        let url: String?
    }

    static func parseWikiNodeInfo(_ raw: String) -> WikiNodeRef? {
        guard let obj = extractJSONDictionary(from: raw),
              (obj["ok"] as? Bool) != false else { return nil }
        let dataObj = (obj["data"] as? [String: Any]) ?? obj
        let node = (dataObj["node"] as? [String: Any]) ?? dataObj
        let spaceID = stringOrInt(node["space_id"]) ?? ""
        let nodeToken = (node["node_token"] as? String) ?? ""
        guard !spaceID.isEmpty, !nodeToken.isEmpty else { return nil }
        return WikiNodeRef(
            spaceID: spaceID,
            nodeToken: nodeToken,
            objToken: (node["obj_token"] as? String) ?? "",
            objType: (node["obj_type"] as? String) ?? "",
            title: (node["title"] as? String) ?? "",
            url: node["url"] as? String
        )
    }

    static func parseWikiChildNodes(_ raw: String) -> [WikiNodeRef] {
        guard let obj = extractJSONDictionary(from: raw),
              (obj["ok"] as? Bool) != false else { return [] }
        let dataObj = (obj["data"] as? [String: Any]) ?? obj
        let rawList = (dataObj["items"] as? [[String: Any]])
            ?? (dataObj["nodes"] as? [[String: Any]])
            ?? []
        return rawList.compactMap { node in
            let objType = ((node["obj_type"] as? String) ?? "").lowercased()
            guard objType.isEmpty || objType == "docx" || objType == "doc" else { return nil }
            let nodeToken = (node["node_token"] as? String) ?? ""
            let objToken = (node["obj_token"] as? String) ?? ""
            guard !nodeToken.isEmpty || !objToken.isEmpty else { return nil }
            return WikiNodeRef(
                spaceID: stringOrInt(node["space_id"]) ?? "",
                nodeToken: nodeToken,
                objToken: objToken,
                objType: objType,
                title: ((node["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                url: node["url"] as? String
            )
        }
    }

    private static func buildDocReference(from node: WikiNodeRef, baseDocURL: String) -> String {
        if let base = URL(string: baseDocURL), let host = base.host, let scheme = base.scheme {
            if !node.nodeToken.isEmpty {
                return "\(scheme)://\(host)/wiki/\(node.nodeToken)"
            }
            if !node.objToken.isEmpty {
                return "\(scheme)://\(host)/docx/\(node.objToken)"
            }
        }
        return node.objToken.isEmpty ? node.nodeToken : node.objToken
    }

    private static func extractCLIError(from raw: String) -> FeishuCLIError? {
        guard let obj = extractJSONDictionary(from: raw) else { return nil }
        return extractCLIError(from: obj)
    }

    private static func extractCLIError(from obj: [String: Any]) -> FeishuCLIError? {
        let ok = obj["ok"] as? Bool
        guard ok == false || obj["error"] != nil else { return nil }

        var parts: [String] = []
        var markers = ""
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? ""
            let hint = (err["hint"] as? String) ?? ""
            let type = (err["type"] as? String) ?? ""
            let subtype = (err["subtype"] as? String) ?? ""
            markers = "\(type) \(subtype) \(msg) \(hint)".lowercased()
            if !msg.isEmpty { parts.append(msg) }
            if !hint.isEmpty { parts.append(hint) }
        } else if let errStr = obj["error"] as? String, !errStr.isEmpty {
            markers = errStr.lowercased()
            parts.append(errStr)
        }

        let joined = parts.joined(separator: "；")
        if markers.contains("auth")
            || markers.contains("token")
            || markers.contains("expired")
            || markers.contains("login")
            || markers.contains("user identity")
            || markers.contains("unauthorized")
            || markers.contains("未登录")
            || markers.contains("授权") {
            return .authExpired(joined)
        }
        return .commandFailed(joined)
    }

    private static func extractJSONDictionary(from raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return obj
        }
        // CLI 偶发夹杂警告行时，尝试截取首尾大括号之间的 JSON。
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringOrInt(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let i = v as? Int { return "\(i)" }
        return nil
    }
}
