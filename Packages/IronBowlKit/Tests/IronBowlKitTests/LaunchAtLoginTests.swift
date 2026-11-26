import AppKit
import Foundation
import IronBowlKit
import ServiceManagement
import Testing

@MainActor
private final class MockLaunchAtLoginService: LaunchAtLoginServiceProtocol {
    var status: LaunchAtLoginStatus
    var registerHandler: ((MockLaunchAtLoginService) throws -> Void)?
    var unregisterHandler: ((MockLaunchAtLoginService) throws -> Void)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSystemSettingsCalls = 0

    init(status: LaunchAtLoginStatus = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let registerHandler {
            try registerHandler(self)
        } else {
            status = .enabled
        }
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterHandler {
            try unregisterHandler(self)
        } else {
            status = .notRegistered
        }
    }

    func openSystemSettings() {
        openSystemSettingsCalls += 1
    }
}

@Test @MainActor
func launchAtLoginReflectsInitialStatus() {
    let enabledService = MockLaunchAtLoginService(status: .enabled)
    let enabledController = LaunchAtLoginController(service: enabledService, notificationCenter: NotificationCenter())
    #expect(enabledController.status == .enabled)
    #expect(enabledController.isEnabled)
    #expect(!enabledController.requiresApproval)
    #expect(enabledController.errorMessage == nil)

    let approvalService = MockLaunchAtLoginService(status: .requiresApproval)
    let approvalController = LaunchAtLoginController(service: approvalService, notificationCenter: NotificationCenter())
    #expect(approvalController.status == .requiresApproval)
    #expect(!approvalController.isEnabled)
    #expect(approvalController.requiresApproval)
}

@Test @MainActor
func launchAtLoginToggleRegistersUnregistersAndSkipsRedundantCalls() {
    let service = MockLaunchAtLoginService(status: .notRegistered)
    let controller = LaunchAtLoginController(service: service, notificationCenter: NotificationCenter())

    controller.setEnabled(false)
    #expect(service.unregisterCalls == 0)
    #expect(!controller.isEnabled)

    controller.setEnabled(true)
    #expect(service.registerCalls == 1)
    #expect(controller.isEnabled)
    #expect(controller.errorMessage == nil)

    controller.setEnabled(true)
    #expect(service.registerCalls == 1)

    controller.setEnabled(false)
    #expect(service.unregisterCalls == 1)
    #expect(!controller.isEnabled)
    #expect(controller.errorMessage == nil)
}

@Test @MainActor
func launchAtLoginHandlesRequiresApprovalAndOpensSystemSettings() {
    let service = MockLaunchAtLoginService(status: .notRegistered)
    service.registerHandler = { svc in
        svc.status = .requiresApproval
        throw NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorLaunchDeniedByUser))
    }
    let controller = LaunchAtLoginController(service: service, notificationCenter: NotificationCenter())

    controller.setEnabled(true)
    #expect(controller.status == .requiresApproval)
    #expect(!controller.isEnabled)
    #expect(controller.requiresApproval)
    #expect(controller.errorMessage == nil)

    controller.openSystemSettings()
    #expect(service.openSystemSettingsCalls == 1)
}

@Test @MainActor
func launchAtLoginIgnoresIdempotentErrors() {
    let registerService = MockLaunchAtLoginService(status: .notRegistered)
    registerService.registerHandler = { svc in
        svc.status = .enabled
        throw NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorAlreadyRegistered))
    }
    let registerController = LaunchAtLoginController(service: registerService, notificationCenter: NotificationCenter())
    registerController.setEnabled(true)
    #expect(registerController.isEnabled)
    #expect(registerController.errorMessage == nil)

    let unregisterService = MockLaunchAtLoginService(status: .enabled)
    unregisterService.unregisterHandler = { svc in
        svc.status = .notRegistered
        throw NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorJobNotFound))
    }
    let unregisterController = LaunchAtLoginController(service: unregisterService, notificationCenter: NotificationCenter())
    unregisterController.setEnabled(false)
    #expect(!unregisterController.isEnabled)
    #expect(unregisterController.errorMessage == nil)
}

@Test @MainActor
func launchAtLoginFormatsSignatureAndGenericErrors() {
    let sigService = MockLaunchAtLoginService(status: .notRegistered)
    sigService.registerHandler = { _ in
        throw NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorInvalidSignature))
    }
    let sigController = LaunchAtLoginController(service: sigService, notificationCenter: NotificationCenter())
    sigController.setEnabled(true)
    #expect(!sigController.isEnabled)
    #expect(sigController.errorMessage?.contains("签名") == true)

    let genericService = MockLaunchAtLoginService(status: .notRegistered)
    genericService.registerHandler = { _ in
        throw NSError(domain: "TestError", code: 42, userInfo: [NSLocalizedDescriptionKey: "测试失败"])
    }
    let genericController = LaunchAtLoginController(service: genericService, notificationCenter: NotificationCenter())
    genericController.setEnabled(true)
    #expect(genericController.errorMessage == "设置开机自启失败：测试失败")
}

@Test @MainActor
func launchAtLoginRefreshesOnDidBecomeActiveNotification() {
    let center = NotificationCenter()
    let service = MockLaunchAtLoginService(status: .notRegistered)
    service.registerHandler = { _ in
        throw NSError(domain: SMAppServiceErrorDomain, code: Int(kSMErrorInvalidSignature))
    }
    let controller = LaunchAtLoginController(service: service, notificationCenter: center)

    controller.setEnabled(true)
    #expect(controller.errorMessage != nil)

    service.status = .enabled
    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

    #expect(controller.status == .enabled)
    #expect(controller.isEnabled)
    #expect(controller.errorMessage == nil)
}
