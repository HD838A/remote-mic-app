import Testing
@testable import RemoteMic

@Suite("Login item service")
struct LoginItemServiceTests {
    @Test func itIsDisabledByDefaultWhenTheSystemHasNoRegistration() {
        let controller = LoginItemControllerSpy(status: .notRegistered)
        let service = LoginItemService(controller: controller)

        #expect(!service.isEnabled)
        #expect(!service.requiresApproval)
        #expect(!service.didFailToUpdate)
    }

    @Test func enablingRegistersTheMainAppAndRefreshesItsSystemStatus() {
        let controller = LoginItemControllerSpy(status: .notRegistered)
        controller.statusAfterRegister = .enabled
        let service = LoginItemService(controller: controller)

        service.setEnabled(true)

        #expect(controller.registerCallCount == 1)
        #expect(service.isEnabled)
        #expect(!service.didFailToUpdate)
    }

    @Test func approvalRequiredRemainsEnabledAndOpensTheSystemLoginItemsPage() {
        let controller = LoginItemControllerSpy(status: .notRegistered)
        controller.statusAfterRegister = .requiresApproval
        let service = LoginItemService(controller: controller)

        service.setEnabled(true)
        service.openLoginItemsSettings()

        #expect(service.isEnabled)
        #expect(service.requiresApproval)
        #expect(controller.openSettingsCallCount == 1)
    }

    @Test func disablingUnregistersTheExistingLoginItem() {
        let controller = LoginItemControllerSpy(status: .enabled)
        controller.statusAfterUnregister = .notRegistered
        let service = LoginItemService(controller: controller)

        service.setEnabled(false)

        #expect(controller.unregisterCallCount == 1)
        #expect(!service.isEnabled)
        #expect(!service.didFailToUpdate)
    }

    @Test func failedRegistrationKeepsTheToggleOffAndReportsTheFailure() {
        let controller = LoginItemControllerSpy(status: .notRegistered)
        controller.registerError = LoginItemControllerSpy.Error.registerFailed
        let service = LoginItemService(controller: controller)

        service.setEnabled(true)

        #expect(!service.isEnabled)
        #expect(service.didFailToUpdate)
    }
}

private final class LoginItemControllerSpy: LoginItemControlling {
    enum Error: Swift.Error {
        case registerFailed
    }

    var status: LoginItemRegistrationStatus
    var statusAfterRegister: LoginItemRegistrationStatus?
    var statusAfterUnregister: LoginItemRegistrationStatus?
    var registerError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(status: LoginItemRegistrationStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        if let statusAfterRegister {
            status = statusAfterRegister
        }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
    }

    func openLoginItemsSettings() {
        openSettingsCallCount += 1
    }
}
