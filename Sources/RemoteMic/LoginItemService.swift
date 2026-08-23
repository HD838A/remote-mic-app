import Combine
import Foundation
import ServiceManagement

enum LoginItemRegistrationStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
}

protocol LoginItemControlling: AnyObject {
    var status: LoginItemRegistrationStatus { get }

    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

private final class SystemLoginItemController: LoginItemControlling {
    private let service = SMAppService.mainApp

    var status: LoginItemRegistrationStatus {
        switch service.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notRegistered, .notFound:
            .notRegistered
        @unknown default:
            .notRegistered
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

final class LoginItemService: ObservableObject {
    @Published private(set) var status: LoginItemRegistrationStatus
    @Published private(set) var didFailToUpdate = false

    private let controller: LoginItemControlling

    init(controller: LoginItemControlling = SystemLoginItemController()) {
        self.controller = controller
        status = controller.status
    }

    var isEnabled: Bool {
        switch status {
        case .enabled, .requiresApproval:
            true
        case .notRegistered:
            false
        }
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    func refresh(clearFailure: Bool = true) {
        status = controller.status
        if clearFailure {
            didFailToUpdate = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        didFailToUpdate = false

        do {
            if enabled {
                try controller.register()
            } else {
                try controller.unregister()
            }
        } catch {
            AppLogger.shared.write("LOGIN ITEM update_failed requested_enabled=\(enabled)")
            refresh(clearFailure: false)
            didFailToUpdate = enabled != isEnabled
            return
        }

        refresh(clearFailure: false)
        didFailToUpdate = enabled != isEnabled
        if didFailToUpdate {
            AppLogger.shared.write("LOGIN ITEM status_mismatch requested_enabled=\(enabled)")
        }
    }

    func openLoginItemsSettings() {
        controller.openLoginItemsSettings()
    }
}
