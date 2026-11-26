import AppKit
import IronBowlKit
import Observation
import Sparkle
import SwiftUI

/// 双应用共享的 Sparkle 2 自动更新封装。
@MainActor
@Observable
final class AppUpdater: NSObject {
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    let isConfigured: Bool

    var isRunningFromDerivedData: Bool {
        Bundle.main.bundlePath.contains("/DerivedData/")
    }

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var autoCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var autoDownloadObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastCheckObservation: NSKeyValueObservation?

    override init() {
        let info = Bundle.main.infoDictionary
        let feedURLString = (info?["SUFeedURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (info?["SUPublicEDKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasValidFeedURL = URL(string: feedURLString)?.scheme?.lowercased() == "https"
        let configured = hasValidFeedURL && !publicKey.isEmpty
        self.isConfigured = configured

        super.init()

        guard configured else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.updaterController = controller

        let updater = controller.updater
        syncFromUpdater(updater)

        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        autoCheckObservation = updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        }
        autoDownloadObservation = updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
            }
        }
        lastCheckObservation = updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.lastUpdateCheckDate = updater.lastUpdateCheckDate
            }
        }
    }

    private func syncFromUpdater(_ updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }

    /// 显式激活应用（避免 `LSUIElement` 菜单栏应用更新窗口被遮挡）并触发检查更新。
    func checkForUpdates() {
        guard let updaterController, canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
        if !enabled && automaticallyDownloadsUpdates {
            updater.automaticallyDownloadsUpdates = false
            automaticallyDownloadsUpdates = false
        }
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = enabled
    }
}

extension AppUpdater: SPUUpdaterDelegate {}

extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// 共享的软件更新设置行组件。
struct AppUpdateSettingsRows: View {
    let updater: AppUpdater

    private var statusDescription: String {
        var base: String
        if !updater.isConfigured {
            base = "未配置更新源或公钥，暂无法检查更新"
        } else if let lastDate = updater.lastUpdateCheckDate {
            base = "上次检查：\(Self.dateFormatter.string(from: lastDate))"
        } else {
            base = "通过 Sparkle 自动检测 GitHub Release 新版本"
        }
        if updater.isRunningFromDerivedData {
            base += "（本地开发构建）"
        }
        return base
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = CN.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        DSRow("软件更新", description: statusDescription) {
            Button("检查更新…") {
                updater.checkForUpdates()
            }
            .buttonStyle(.dsSecondary)
            .disabled(!updater.canCheckForUpdates)
        }
        DSRow("自动检查更新", description: "定期在后台检测新版本并提示升级。") {
            DSToggle(isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }
            ))
            .disabled(!updater.isConfigured)
        }
        DSRow("自动下载更新", description: "发现新版本时在后台预先下载安装包。") {
            DSToggle(isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticallyDownloadsUpdates($0) }
            ))
            .disabled(!updater.isConfigured || !updater.automaticallyChecksForUpdates)
        }
    }
}
