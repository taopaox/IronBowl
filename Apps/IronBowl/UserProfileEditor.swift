import AppKit
import IronBowlKit
import SwiftUI
import UniformTypeIdentifiers

/// 个人头像/Logo 视图：有自定义图片时按圆角裁切展示，未设置时展示默认应用图标 `AppLogo`。
struct UserProfileAvatarView: View {
    let image: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat? = nil

    var body: some View {
        let radius = cornerRadius ?? max(5, size * 0.24)
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(DS.border, lineWidth: 0.5)
                }
        } else {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

enum UserProfileAvatarPicker {
    static func pickLocalImageURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .tiff, .icns, .webP, .bmp]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// 左下角个人资料弹窗编辑器（姓名、个人标语、头像/Logo）。
struct UserProfileEditorSheet: View {
    private enum PendingAvatar {
        case unchanged
        case custom(Data, NSImage)
        case resetToDefault
    }

    let profile: UserProfileStore
    let onClose: () -> Void

    @State private var name: String
    @State private var slogan: String
    @State private var pendingAvatar: PendingAvatar = .unchanged
    @State private var error: String?

    init(profile: UserProfileStore, onClose: @escaping () -> Void) {
        self.profile = profile
        self.onClose = onClose
        _name = State(initialValue: profile.displayName)
        _slogan = State(initialValue: profile.slogan)
    }

    private var previewImage: NSImage? {
        switch pendingAvatar {
        case .unchanged: profile.avatarImage
        case let .custom(_, image): image
        case .resetToDefault: nil
        }
    }

    private var previewDisplayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? profile.fallbackDisplayName : trimmed
    }

    private var previewSlogan: String? {
        let trimmed = slogan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("个人资料")
                    .font(DS.pageTitle)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.dsGhost)
            }

            HStack(spacing: 10) {
                UserProfileAvatarView(image: previewImage, size: previewSlogan == nil ? DS.s(28) : DS.s(34))
                VStack(alignment: .leading, spacing: 2) {
                    Text(previewDisplayName)
                        .font(DS.font(14, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    if let previewSlogan {
                        Text(previewSlogan)
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(DS.well, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }

            VStack(alignment: .leading, spacing: 8) {
                Text("头像 / Logo")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)

                HStack(spacing: 8) {
                    Button("选择图片…") { pickAvatar() }
                        .buttonStyle(.dsSecondary)

                    Button("恢复默认图标") {
                        error = nil
                        pendingAvatar = .resetToDefault
                    }
                    .buttonStyle(.dsGhost)
                    .disabled(previewImage == nil)
                }

                Text("支持 PNG / JPG / HEIC / WebP 等本地图片")
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("显示姓名")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                TextField("", text: $name, prompt: Text("留空默认使用「\(profile.fallbackDisplayName)」"))
                    .textFieldStyle(.ds)
                    .onSubmit { save() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("个人标语")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                TextField("", text: $slogan, prompt: Text("显示在左下角姓名下方，留空不显示"))
                    .textFieldStyle(.ds)
                    .onSubmit { save() }
            }

            if let error {
                DSBanner(.danger, error)
            }

            HStack {
                Spacer()
                Button("取消") { onClose() }
                    .buttonStyle(.dsSecondary)
                Button("保存") { save() }
                    .buttonStyle(.dsPrimary)
            }
        }
        .padding(18)
        .frame(width: DS.s(400))
        .background(DS.card)
    }

    private func pickAvatar() {
        guard let url = UserProfileAvatarPicker.pickLocalImageURL() else { return }
        do {
            let loaded = try UserProfileStore.loadValidatedImageData(from: url)
            pendingAvatar = .custom(loaded.data, loaded.image)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        do {
            switch pendingAvatar {
            case .unchanged:
                break
            case let .custom(data, _):
                try profile.saveAvatarData(data)
            case .resetToDefault:
                profile.clearAvatar()
            }
            profile.update(displayName: name, slogan: slogan)
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
