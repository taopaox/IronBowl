import AppKit
import CryptoKit
import Foundation
import IronBowlKit
import Observation

public enum AILogoError: LocalizedError {
    case invalidImageData
    case invalidURL
    case downloadFailed
    case faviconNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidImageData: "无法识别该图片格式，请选择 PNG / JPG / WebP / ICNS 等图片。"
        case .invalidURL: "图片或网站地址无效，请检查后重试。"
        case .downloadFailed: "下载图标失败，请检查网络连接或换一个地址。"
        case .faviconNotFound: "未能从该网站自动抓取到有效图标，请尝试上传本地图片或填写图标链接。"
        }
    }
}

@Observable
public final class AILogoStore {
    public let baseDirectory: URL
    private let cacheDirectory: URL

    @ObservationIgnored private var memoryCache: [String: NSImage] = [:]
    @ObservationIgnored private var inFlightRemoteKeys: Set<String> = []
    /// 远程图标异步落盘后递增，驱动 SwiftUI 视图刷新。
    public private(set) var revision = 0

    public init(baseDirectory: URL? = nil) {
        let dir = baseDirectory ?? AppPaths.supportDirectory.appending(path: "ai-logos", directoryHint: .isDirectory)
        self.baseDirectory = dir
        self.cacheDirectory = dir.appending(path: "cache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func image(for source: AILogoSource) -> (image: NSImage, isTemplate: Bool)? {
        _ = revision
        switch source {
        case let .bundled(name, isTemplate):
            let key = "bundled:\(name)"
            if let cached = memoryCache[key] {
                return (cached, isTemplate)
            }
            guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Logos"),
                  let image = NSImage(contentsOf: url) else {
                return nil
            }
            memoryCache[key] = image
            return (image, isTemplate)

        case let .localFile(filename):
            let key = "local:\(filename)"
            if let cached = memoryCache[key] {
                return (cached, false)
            }
            let fileURL = baseDirectory.appending(path: filename)
            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            memoryCache[key] = image
            return (image, false)

        case let .remoteURL(rawURL):
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = "remote:\(trimmed)"
            if let cached = memoryCache[key] {
                return (cached, false)
            }
            let diskURL = cacheFileURL(for: trimmed)
            if let image = NSImage(contentsOf: diskURL) {
                memoryCache[key] = image
                return (image, false)
            }
            prefetchRemote(urlString: trimmed, cacheKey: key, diskURL: diskURL)
            return nil

        case .symbol:
            return nil
        }
    }

    public func saveLocalImage(from fileURL: URL) throws -> AILogoSource {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL)
        return try saveImageData(data)
    }

    public func saveImageData(_ data: Data) throws -> AILogoSource {
        guard let pngData = normalizedPNGData(from: data) else {
            throw AILogoError.invalidImageData
        }
        let filename = "\(UUID().uuidString).png"
        let target = baseDirectory.appending(path: filename)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try pngData.write(to: target, options: .atomic)
        if let image = NSImage(data: pngData) {
            memoryCache["local:\(filename)"] = image
        }
        revision &+= 1
        return .localFile(filename: filename)
    }

    public func downloadRemoteLogo(from imageURLString: String) async throws -> AILogoSource {
        guard let url = WebURL.normalize(imageURLString) else {
            throw AILogoError.invalidURL
        }
        guard let data = await Self.fetchData(from: url) else {
            throw AILogoError.downloadFailed
        }
        return try saveImageData(data)
    }

    public func fetchWebsiteFavicon(for siteURLString: String) async throws -> AILogoSource {
        guard let siteURL = WebURL.normalize(siteURLString), let host = siteURL.host else {
            throw AILogoError.invalidURL
        }

        var candidates: [URL] = []
        if let htmlData = await Self.fetchData(from: siteURL),
           let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) {
            candidates.append(contentsOf: Self.extractIconURLs(fromHTML: html, baseURL: siteURL))
        }

        var rootComponents = URLComponents()
        rootComponents.scheme = siteURL.scheme ?? "https"
        rootComponents.host = host
        rootComponents.port = siteURL.port
        if let root = rootComponents.url {
            candidates.append(root.appending(path: "apple-touch-icon.png"))
            candidates.append(root.appending(path: "apple-touch-icon-precomposed.png"))
            candidates.append(root.appending(path: "favicon.png"))
            candidates.append(root.appending(path: "favicon.ico"))
        }
        if let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let gStatic = URL(string: "https://www.google.com/s2/favicons?domain=\(encodedHost)&sz=128") {
            candidates.append(gStatic)
        }

        var seen = Set<String>()
        for url in candidates {
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            guard let data = await Self.fetchData(from: url),
                  let image = NSImage(data: data),
                  image.size.width >= 16, image.size.height >= 16 else {
                continue
            }
            if let saved = try? saveImageData(data) {
                return saved
            }
        }
        throw AILogoError.faviconNotFound
    }

    public func deleteLocalFileIfUnused(_ filename: String, apps: [AIWebApp]) {
        let stillReferenced = apps.contains {
            if case let .localFile(other) = $0.logo { return other == filename }
            return false
        }
        guard !stillReferenced else { return }
        memoryCache.removeValue(forKey: "local:\(filename)")
        let fileURL = baseDirectory.appending(path: filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 内部方法

    private func prefetchRemote(urlString: String, cacheKey: String, diskURL: URL) {
        guard !inFlightRemoteKeys.contains(cacheKey),
              let url = WebURL.normalize(urlString) else { return }
        inFlightRemoteKeys.insert(cacheKey)
        Task { [weak self] in
            defer { self?.inFlightRemoteKeys.remove(cacheKey) }
            guard let data = await Self.fetchData(from: url),
                  let self,
                  let pngData = self.normalizedPNGData(from: data),
                  let image = NSImage(data: pngData) else { return }
            try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
            try? pngData.write(to: diskURL, options: .atomic)
            self.memoryCache[cacheKey] = image
            self.revision &+= 1
        }
    }

    private func cacheFileURL(for urlString: String) -> URL {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appending(path: "\(hex).png")
    }

    private func normalizedPNGData(from rawData: Data, maxDimension: CGFloat = 256) -> Data? {
        guard let image = NSImage(data: rawData) else { return nil }
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(srcSize.width, srcSize.height))
        let targetW = max(1, Int((srcSize.width * scale).rounded()))
        let targetH = max(1, Int((srcSize.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: targetW, height: targetH)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    private nonisolated static func fetchData(from url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        return data
    }

    private nonisolated static func extractIconURLs(fromHTML html: String, baseURL: URL) -> [URL] {
        guard let linkRegex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var prioritized: [(priority: Int, url: URL)] = []

        for match in linkRegex.matches(in: html, range: range) {
            guard let swiftRange = Range(match.range, in: html) else { continue }
            let tag = String(html[swiftRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.contains("icon") else { continue }
            guard let href = attribute("href", in: tag),
                  !href.isEmpty,
                  !href.lowercased().hasPrefix("data:"),
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            let priority: Int
            if rel.contains("apple-touch-icon") {
                priority = 0
            } else if href.lowercased().contains(".png") {
                priority = 1
            } else if href.lowercased().contains(".svg") {
                priority = 3
            } else {
                priority = 2
            }
            prioritized.append((priority, resolved))
        }

        return prioritized.sorted { $0.priority < $1.priority }.map(\.url)
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for group in 1...3 {
            let r = match.range(at: group)
            if r.location != NSNotFound, let sr = Range(r, in: tag) {
                return String(tag[sr])
            }
        }
        return nil
    }
}
