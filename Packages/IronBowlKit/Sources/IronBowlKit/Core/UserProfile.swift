import AppKit
import Foundation
import Observation

public nonisolated enum UserProfileError: LocalizedError, Sendable {
    case invalidImageData

    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            "无法识别该图片格式，请选择 PNG / JPG / HEIC / WebP / ICNS 等图片。"
        }
    }
}

public nonisolated enum UserProfileKeys {
    public static let displayName = SettingKey<String>("user.displayName", default: "")
    public static let slogan = SettingKey<String>("user.slogan", default: "")
    public static let avatarFilename = SettingKey<String?>("user.avatarFilename", default: nil)
}

/// 个人资料管理：显示姓名、个人标语与自定义头像/Logo 的持久化与图片归一化存储。
@Observable
public final class UserProfileStore {
    private let settings: SettingsStore
    public let avatarsDirectory: URL
    private let systemNameProvider: () -> String

    public private(set) var avatarImage: NSImage?
    public private(set) var revision = 0

    public init(
        settings: SettingsStore,
        avatarsDirectory: URL? = nil,
        systemNameProvider: @escaping () -> String = { NSFullUserName() }
    ) {
        self.settings = settings
        let dir = avatarsDirectory ?? AppPaths.userAvatarsDirectory
        self.avatarsDirectory = dir
        self.systemNameProvider = systemNameProvider
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        reloadAvatar()
    }

    public var displayName: String {
        get { settings[UserProfileKeys.displayName] }
        set { settings[UserProfileKeys.displayName] = newValue }
    }

    public var slogan: String {
        get { settings[UserProfileKeys.slogan] }
        set { settings[UserProfileKeys.slogan] = newValue }
    }

    public var avatarFilename: String? {
        settings[UserProfileKeys.avatarFilename]
    }

    public var hasCustomAvatar: Bool {
        avatarImage != nil
    }

    public var fallbackDisplayName: String {
        let trimmed = systemNameProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "我" : trimmed
    }

    public var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackDisplayName : trimmed
    }

    public var effectiveSlogan: String? {
        let trimmed = slogan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func update(displayName: String, slogan: String) {
        settings[UserProfileKeys.displayName] = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings[UserProfileKeys.slogan] = slogan.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedPNGData(from rawData: Data, maxDimension: CGFloat = 256) -> Data? {
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

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    public static func loadValidatedImageData(from fileURL: URL) throws -> (data: Data, image: NSImage) {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        let rawData = try Data(contentsOf: fileURL)
        guard let pngData = normalizedPNGData(from: rawData),
              let image = NSImage(data: pngData) else {
            throw UserProfileError.invalidImageData
        }
        return (pngData, image)
    }

    public func saveAvatar(from fileURL: URL) throws {
        let (pngData, image) = try Self.loadValidatedImageData(from: fileURL)
        try saveNormalizedAvatarPNGData(pngData, image: image)
    }

    public func saveAvatarData(_ rawData: Data) throws {
        guard let pngData = Self.normalizedPNGData(from: rawData),
              let image = NSImage(data: pngData) else {
            throw UserProfileError.invalidImageData
        }
        try saveNormalizedAvatarPNGData(pngData, image: image)
    }

    public func clearAvatar() {
        let previous = settings[UserProfileKeys.avatarFilename]
        settings[UserProfileKeys.avatarFilename] = nil
        removeAvatarFileIfPresent(previous)
        avatarImage = nil
        revision &+= 1
    }

    public func reloadAvatar() {
        if let filename = settings[UserProfileKeys.avatarFilename], !filename.isEmpty {
            let fileURL = avatarsDirectory.appending(path: filename)
            avatarImage = NSImage(contentsOf: fileURL)
        } else {
            avatarImage = nil
        }
        revision &+= 1
    }

    private func saveNormalizedAvatarPNGData(_ pngData: Data, image: NSImage) throws {
        let filename = "\(UUID().uuidString).png"
        let target = avatarsDirectory.appending(path: filename)
        try FileManager.default.createDirectory(at: avatarsDirectory, withIntermediateDirectories: true)
        try pngData.write(to: target, options: .atomic)

        let previous = settings[UserProfileKeys.avatarFilename]
        settings[UserProfileKeys.avatarFilename] = filename
        if previous != filename {
            removeAvatarFileIfPresent(previous)
        }
        avatarImage = image
        revision &+= 1
    }

    private func removeAvatarFileIfPresent(_ filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        let fileURL = avatarsDirectory.appending(path: filename)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
