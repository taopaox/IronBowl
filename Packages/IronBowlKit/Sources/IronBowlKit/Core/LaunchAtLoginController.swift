import AppKit
import Foundation
import Observation
import ServiceManagement

/// 开机自启注册状态（对应 `SMAppService.Status`）。
public nonisolated enum LaunchAtLoginStatus: String, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    public nonisolated init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}

/// 抽象系统登录项服务，便于测试替身注入。
public protocol LaunchAtLoginServiceProtocol {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// 基于 `SMAppService.mainApp` 的系统开机自启实现。
public struct SystemLaunchAtLoginService: LaunchAtLoginServiceProtocol {
    public init() {}

    public var status: LaunchAtLoginStatus {
        LaunchAtLoginStatus(SMAppService.mainApp.status)
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// 共享的开机自启控制器：管理登录项状态、错误提示与回前台自动刷新。
@Observable
public final class LaunchAtLoginController {
    public private(set) var status: LaunchAtLoginStatus
    public private(set) var errorMessage: String?

    public var isEnabled: Bool { status == .enabled }
    public var requiresApproval: Bool { status == .requiresApproval }

    @ObservationIgnored private let service: any LaunchAtLoginServiceProtocol
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var activeObserver: (any NSObjectProtocol)?

    public init(
        service: any LaunchAtLoginServiceProtocol = SystemLaunchAtLoginService(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.service = service
        self.notificationCenter = notificationCenter
        self.status = service.status
        self.activeObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let activeObserver {
            notificationCenter.removeObserver(activeObserver)
        }
    }

    /// 重新读取系统登录项状态；恢复正常状态后自动清理错误提示。
    public func refresh() {
        let latest = service.status
        status = latest
        if latest == .enabled || latest == .notRegistered {
            errorMessage = nil
        }
    }

    /// 开启或关闭开机自动启动，并对常见幂等/权限/签名错误提供友好反馈。
    public func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        let current = service.status
        do {
            if enabled {
                if current != .enabled {
                    try service.register()
                }
            } else {
                if current != .notRegistered {
                    try service.unregister()
                }
            }
        } catch {
            errorMessage = formatError(error, enabling: enabled)
        }
        status = service.status
        if (enabled && status == .enabled) || (!enabled && status == .notRegistered) || status == .requiresApproval {
            errorMessage = nil
        }
    }

    /// 跳转至「系统设置 → 通用 → 登录项与扩展」。
    public func openSystemSettings() {
        service.openSystemSettings()
    }

    private func formatError(_ error: Error, enabling: Bool) -> String? {
        let nsError = error as NSError
        let code = nsError.code
        let isSMDomain = nsError.domain == SMAppServiceErrorDomain
        if enabling {
            if isSMDomain && code == Int(kSMErrorAlreadyRegistered) {
                return nil
            }
            if (isSMDomain && code == Int(kSMErrorLaunchDeniedByUser))
                || (nsError.domain == NSPOSIXErrorDomain && code == Int(EPERM))
            {
                return "系统尚未允许开机自启，请在「系统设置 → 通用 → 登录项与扩展」中开启。"
            }
            if isSMDomain && code == Int(kSMErrorInvalidSignature) {
                return "当前应用签名无法注册开机自启，建议将正式版移至「应用程序」目录后重试。"
            }
            return "设置开机自启失败：\(error.localizedDescription)"
        } else {
            if isSMDomain && code == Int(kSMErrorJobNotFound) {
                return nil
            }
            return "取消开机自启失败：\(error.localizedDescription)"
        }
    }
}
