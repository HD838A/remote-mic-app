import AppleRemoteHCIProtocol
import Foundation
import Security

final class AppleRemoteHCIConfigurationClient {
    enum Result: Equatable {
        case ready
        case failed(String)
    }

    private var connection: NSXPCConnection?
    private var prepared = false

    deinit {
        stop()
    }

    func prepare(completion: @escaping (Result) -> Void) {
        guard connection == nil else {
            completion(.failed(
                prepared
                    ? "configuration_already_prepared"
                    : "configuration_in_progress"
            ))
            return
        }
        let connection = NSXPCConnection(
            machServiceName: AppleRemoteHCIConstants.machServiceName,
            options: .privileged
        )
        AppLogger.shared.write(
            "APPLE REMOTE HCI XPC phase=connecting service=present " +
                Self.clientSignatureDiagnostic()
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: AppleRemoteHCIServiceProtocol.self
        )
        connection.invalidationHandler = { [weak self] in
            AppLogger.shared.write("APPLE REMOTE HCI XPC phase=invalidated")
            self?.connection = nil
            self?.prepared = false
        }
        connection.interruptionHandler = { [weak self] in
            AppLogger.shared.write("APPLE REMOTE HCI XPC phase=interrupted")
            self?.connection = nil
            self?.prepared = false
        }
        connection.resume()
        self.connection = connection

        let latch = CompletionLatch()
        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            guard latch.claim() else { return }
            AppLogger.shared.write(
                "APPLE REMOTE HCI XPC phase=failed result=remote_proxy_error " +
                    AppLogger.errorFields(error)
            )
            completion(.failed(
                "hci_helper_unreachable_\((error as NSError).code)"
            ))
        }
        guard let helper = remote as? AppleRemoteHCIServiceProtocol else {
            if latch.claim() {
                completion(.failed("hci_helper_interface_unavailable"))
            }
            return
        }
        helper.prepareConfiguration { [weak self] succeeded, status in
            guard latch.claim() else { return }
            self?.prepared = succeeded
            completion(succeeded ? .ready : .failed(status))
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
            guard latch.claim() else { return }
            completion(.failed("hci_helper_timed_out"))
        }
    }

    private static func clientSignatureDiagnostic() -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess, let staticCode else {
            return "client_signature=unavailable"
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any]
        else {
            return "client_signature=unavailable"
        }
        let identifier = values[kSecCodeInfoIdentifier as String] as? String
        let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
        let isAdHoc = teamIdentifier == nil
        return "client_identifier_matches=\(identifier == AppleRemoteHCIConstants.expectedClientIdentifier) " +
            "client_team_matches=\(teamIdentifier == AppleRemoteHCIConstants.expectedTeamIdentifier) " +
            "client_signature_adhoc=\(isAdHoc)"
    }

    func stop() {
        guard let connection else { return }
        if prepared,
           let helper = connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? AppleRemoteHCIServiceProtocol {
            helper.releaseConfiguration { _, _ in }
        }
        prepared = false
        self.connection = nil
        connection.invalidate()
    }

    func sealAuthorizationRight(completion: @escaping (Bool) -> Void) {
        guard let connection else {
            completion(false)
            return
        }
        let latch = CompletionLatch()
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in
            guard latch.claim() else { return }
            completion(false)
        }
        guard let helper = remote as? AppleRemoteHCIServiceProtocol else {
            completion(false)
            return
        }
        helper.sealAuthorizationRight { succeeded, _ in
            guard latch.claim() else { return }
            completion(succeeded)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
            guard latch.claim() else { return }
            completion(false)
        }
    }

    private final class CompletionLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}
