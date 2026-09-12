import AppleRemoteHCIProtocol
import Darwin
import Foundation
import OSLog
import Security

private enum HCIServiceError: Error {
    case notRoot
    case stateCorrupt
    case authorizationCreate(OSStatus)
    case authorizationRightLookup(OSStatus)
    case authorizationRightWrite(OSStatus)
    case bluetoothReloadFailed(Int32)
}

private struct PersistedHCIState: Codable {
    var active: Bool
    var originalPlistPresent: Bool
    var originalPlistData: Data?
    var originalAuthorizationRightPresent: Bool?
    var originalAuthorizationRightData: Data?

    static let inactive = PersistedHCIState(
        active: false,
        originalPlistPresent: false,
        originalPlistData: nil,
        originalAuthorizationRightPresent: nil,
        originalAuthorizationRightData: nil
    )
}

private final class HCIConfigurationStore {
    private static let packetLoggerAuthorizationRight = "com.apple.PacketLogger.HCI"
    private let fileManager = FileManager.default
    private let preferencesURL = URL(
        fileURLWithPath: "/Library/Preferences/com.apple.MobileBluetooth.debug.plist"
    )
    private let stateDirectoryURL = URL(
        fileURLWithPath: "/Library/Application Support/RemoteMic/AppleRemoteHCI",
        isDirectory: true
    )
    private lazy var stateURL = stateDirectoryURL.appendingPathComponent("state.plist")

    func recoverAtStartup() throws {
        guard try readState().active else { return }
        try restore()
    }

    func enable() throws {
        guard geteuid() == 0 else { throw HCIServiceError.notRoot }
        let existingState = try readState()
        if existingState.active {
            try restore()
        }

        let originalData = try? Data(contentsOf: preferencesURL)
        let originalAuthorizationRight = try readAuthorizationRight()
        try writeState(PersistedHCIState(
            active: true,
            originalPlistPresent: originalData != nil,
            originalPlistData: originalData,
            originalAuthorizationRightPresent: originalAuthorizationRight != nil,
            originalAuthorizationRightData: originalAuthorizationRight
        ))

        do {
            try writeTemporaryPacketLoggerAuthorizationRight()
            try writeRawPreferences(
                AppleRemoteHCITraceConfiguration.enabledPreferencesData(
                    from: originalData
                )
            )
            try reloadBluetoothDaemon()
        } catch {
            try? restore()
            throw error
        }
    }

    func restore() throws {
        guard geteuid() == 0 else { throw HCIServiceError.notRoot }
        let state = try readState()
        guard state.active else { return }

        let currentData = try? Data(contentsOf: preferencesURL)
        switch try AppleRemoteHCITraceConfiguration.restoreAction(
            originalPlistPresent: state.originalPlistPresent,
            originalPlistData: state.originalPlistData,
            currentPlistData: currentData
        ) {
        case .none:
            break
        case .write(let data):
            try writeRawPreferences(data)
        case .moveCurrentPreferencesToTrash:
            try movePreferencesToSystemTrash()
        }
        try restoreAuthorizationRight(from: state)
        try reloadBluetoothDaemon()
        try writeState(.inactive)
    }

    func sealAuthorizationRight() throws {
        guard geteuid() == 0 else { throw HCIServiceError.notRoot }
        let state = try readState()
        guard state.active else { return }
        try restoreAuthorizationRight(from: state)
    }

    private func readState() throws -> PersistedHCIState {
        guard fileManager.fileExists(atPath: stateURL.path) else { return .inactive }
        do {
            return try PropertyListDecoder().decode(
                PersistedHCIState.self,
                from: Data(contentsOf: stateURL)
            )
        } catch {
            throw HCIServiceError.stateCorrupt
        }
    }

    private func writeState(_ state: PersistedHCIState) throws {
        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        try PropertyListEncoder().encode(state).write(to: stateURL, options: .atomic)
        try fileManager.setAttributes([
            .ownerAccountID: NSNumber(value: 0),
            .groupOwnerAccountID: NSNumber(value: 0),
            .posixPermissions: NSNumber(value: 0o600),
        ], ofItemAtPath: stateURL.path)
    }

    private func readAuthorizationRight() throws -> Data? {
        var definition: CFDictionary?
        let status = Self.packetLoggerAuthorizationRight.withCString {
            AuthorizationRightGet($0, &definition)
        }
        if status == errAuthorizationDenied { return nil }
        guard status == errAuthorizationSuccess, let definition else {
            throw HCIServiceError.authorizationRightLookup(status)
        }
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: definition,
                format: .binary,
                options: 0
            )
        } catch {
            throw HCIServiceError.stateCorrupt
        }
    }

    private func restoreAuthorizationRight(from state: PersistedHCIState) throws {
        guard let originalPresent = state.originalAuthorizationRightPresent else {
            return
        }
        if originalPresent {
            guard let data = state.originalAuthorizationRightData,
                  let definition = try PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                  ) as? [String: Any] else {
                throw HCIServiceError.stateCorrupt
            }
            try writeAuthorizationRight(definition as CFDictionary, description: nil)
            return
        }
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw HCIServiceError.authorizationCreate(createStatus)
        }
        defer { AuthorizationFree(authorization, [.destroyRights]) }
        let removeStatus = Self.packetLoggerAuthorizationRight.withCString {
            AuthorizationRightRemove(authorization, $0)
        }
        guard removeStatus == errAuthorizationSuccess || removeStatus == errAuthorizationDenied else {
            throw HCIServiceError.authorizationRightWrite(removeStatus)
        }
    }

    private func writeAuthorizationRight(
        _ definition: CFDictionary,
        description: CFString?
    ) throws {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            throw HCIServiceError.authorizationCreate(createStatus)
        }
        defer { AuthorizationFree(authorization, [.destroyRights]) }
        let status = Self.packetLoggerAuthorizationRight.withCString {
            AuthorizationRightSet(
                authorization,
                $0,
                definition,
                description,
                nil,
                nil
            )
        }
        guard status == errAuthorizationSuccess else {
            throw HCIServiceError.authorizationRightWrite(status)
        }
    }

    private func writeTemporaryPacketLoggerAuthorizationRight() throws {
        let requirement = "identifier \"\(AppleRemoteHCIConstants.expectedClientIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(AppleRemoteHCIConstants.expectedTeamIdentifier)\""
        let definition: CFDictionary = [
            "class" as CFString: "user" as CFString,
            "group" as CFString: "admin" as CFString,
            "authenticate-user" as CFString: kCFBooleanTrue as CFBoolean,
            "allow-root" as CFString: kCFBooleanTrue as CFBoolean,
            "shared" as CFString: kCFBooleanFalse as CFBoolean,
            "timeout" as CFString: 0 as CFNumber,
            "identifier" as CFString: AppleRemoteHCIConstants.expectedClientIdentifier as CFString,
            "requirement" as CFString: requirement as CFString,
        ] as CFDictionary
        try writeAuthorizationRight(
            definition,
            description: "允许无线麦接收 Apple Remote 蓝牙音频。" as CFString
        )
    }

    private func writeRawPreferences(_ data: Data) throws {
        try data.write(to: preferencesURL, options: .atomic)
        try fileManager.setAttributes([
            .ownerAccountID: NSNumber(value: 0),
            .groupOwnerAccountID: NSNumber(value: 0),
            .posixPermissions: NSNumber(value: 0o644),
        ], ofItemAtPath: preferencesURL.path)
    }

    private func movePreferencesToSystemTrash() throws {
        guard fileManager.fileExists(atPath: preferencesURL.path) else { return }
        let trashURL = URL(fileURLWithPath: "/var/root/.Trash", isDirectory: true)
        try fileManager.createDirectory(
            at: trashURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let token = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var destination = trashURL.appendingPathComponent(
            "com.apple.MobileBluetooth.debug.sayall-\(token).plist"
        )
        var counter = 0
        while fileManager.fileExists(atPath: destination.path) {
            counter += 1
            destination = trashURL.appendingPathComponent(
                "com.apple.MobileBluetooth.debug.sayall-\(token)-\(counter).plist"
            )
        }
        try fileManager.moveItem(at: preferencesURL, to: destination)
    }

    private func reloadBluetoothDaemon() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-30", "bluetoothd"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HCIServiceError.bluetoothReloadFailed(process.terminationStatus)
        }
    }
}

private final class HCIServiceCoordinator {
    private let lock = NSLock()
    private let store = HCIConfigurationStore()
    private var leaseState = AppleRemoteHCILeaseState()

    func recoverAtStartup() {
        do {
            try store.recoverAtStartup()
            serviceLog("recovery_completed result=restored_or_clean")
        } catch {
            serviceLog(
                "recovery_failed result=configuration_restore_failed " +
                    hciErrorDiagnostic(error)
            )
        }
    }

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try leaseState.acquire { try store.enable() }
            serviceLog("lease_acquired active_leases=\(leaseState.activeLeaseCount)")
            return true
        } catch {
            serviceLog(
                "lease_failed result=configuration_enable_failed " +
                    hciErrorDiagnostic(error)
            )
            return false
        }
    }

    func release() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            try leaseState.release { try store.restore() }
            serviceLog("lease_released active_leases=\(leaseState.activeLeaseCount)")
            return true
        } catch {
            serviceLog(
                "release_failed result=configuration_restore_failed " +
                    hciErrorDiagnostic(error)
            )
            return false
        }
    }

    func sealAuthorizationRight() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard leaseState.activeLeaseCount > 0 else { return false }
        do {
            try store.sealAuthorizationRight()
            serviceLog("authorization_right phase=sealed result=restored")
            return true
        } catch {
            serviceLog(
                "authorization_right phase=failed reason=restore_failed " +
                    hciErrorDiagnostic(error)
            )
            return false
        }
    }

}

private func hciErrorDiagnostic(_ error: Error) -> String {
    switch error {
    case HCIServiceError.notRoot:
        return "error=not_root"
    case HCIServiceError.stateCorrupt:
        return "error=state_corrupt"
    case let HCIServiceError.authorizationCreate(status):
        return "error=authorization_create status=\(status)"
    case let HCIServiceError.authorizationRightLookup(status):
        return "error=authorization_right_lookup status=\(status)"
    case let HCIServiceError.authorizationRightWrite(status):
        return "error=authorization_right_write status=\(status)"
    case let HCIServiceError.bluetoothReloadFailed(status):
        return "error=bluetooth_reload_failed status=\(status)"
    default:
        return "error=unknown"
    }
}

private final class HCIRequestHandler: NSObject, AppleRemoteHCIServiceProtocol {
    private let coordinator: HCIServiceCoordinator
    private let lock = NSLock()
    private var hasLease = false

    init(coordinator: HCIServiceCoordinator) {
        self.coordinator = coordinator
    }

    func prepareConfiguration(reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if hasLease {
            reply(true, "ready")
            return
        }
        let acquired = coordinator.acquire()
        guard acquired else {
            reply(false, "configuration_enable_failed")
            return
        }
        hasLease = true
        reply(true, "ready")
    }

    func releaseConfiguration(reply: @escaping (Bool, String) -> Void) {
        let released = releaseLeaseIfNeeded()
        reply(released, released ? "released" : "configuration_restore_failed")
    }

    func sealAuthorizationRight(reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        let canSeal = hasLease
        lock.unlock()
        guard canSeal else {
            reply(false, "configuration_not_prepared")
            return
        }
        let sealed = coordinator.sealAuthorizationRight()
        reply(sealed, sealed ? "sealed" : "authorization_restore_failed")
    }

    func releaseLeaseIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hasLease else { return true }
        let released = coordinator.release()
        if released { hasLease = false }
        return released
    }
}

private final class HCIService: NSObject, NSXPCListenerDelegate {
    private let coordinator = HCIServiceCoordinator()

    override init() {
        super.init()
        coordinator.recoverAtStartup()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let trustFailure = clientTrustFailure(connection) else {
            let handler = HCIRequestHandler(coordinator: coordinator)
            connection.exportedInterface = NSXPCInterface(
                with: AppleRemoteHCIServiceProtocol.self
            )
            connection.exportedObject = handler
            connection.invalidationHandler = { [weak handler] in
                _ = handler?.releaseLeaseIfNeeded()
            }
            connection.interruptionHandler = { [weak handler] in
                _ = handler?.releaseLeaseIfNeeded()
            }
            connection.resume()
            serviceLog("connection_accepted result=trusted_client")
            return true
        }
        serviceLog("connection_rejected reason=\(trustFailure)")
        return false
    }

    private func clientTrustFailure(_ connection: NSXPCConnection) -> String? {
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            return "guest_code_lookup_\(guestStatus)"
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(
            connection.processIdentifier,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else {
            return "client_path_lookup_failed"
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: String(cString: pathBuffer)) as CFURL,
            [],
            &staticCode
        )
        guard staticStatus == errSecSuccess, let staticCode else {
            return "static_code_create_\(staticStatus)"
        }
        var information: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard signingStatus == errSecSuccess,
              let values = information as? [String: Any]
        else {
            return "signing_information_\(signingStatus)"
        }
        let identifier = values[kSecCodeInfoIdentifier as String] as? String
        guard identifier == AppleRemoteHCIConstants.expectedClientIdentifier else {
            return "identifier_mismatch"
        }
        let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String
        guard let teamIdentifier else {
            return "adhoc_signature"
        }
        guard teamIdentifier == AppleRemoteHCIConstants.expectedTeamIdentifier else {
            return "team_mismatch"
        }
        let requirementText = """
        identifier "\(AppleRemoteHCIConstants.expectedClientIdentifier)" and \
        anchor apple generic and \
        certificate leaf[subject.OU] = "\(AppleRemoteHCIConstants.expectedTeamIdentifier)"
        """
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            return "requirement_create_\(requirementStatus)"
        }
        let validityStatus = SecCodeCheckValidity(code, [], requirement)
        guard validityStatus == errSecSuccess else {
            return "requirement_validation_\(validityStatus)"
        }
        return nil
    }
}

private let serviceLogger = Logger(
    subsystem: "com.hd838a.SayAll.AppleRemoteHCIService",
    category: "lifecycle"
)

private func serviceLog(_ message: String) {
    print("APPLE_REMOTE_HCI_SERVICE \(message)")
    serviceLogger.info("APPLE_REMOTE_HCI_SERVICE \(message, privacy: .public)")
    fflush(stdout)
}

if CommandLine.arguments.contains("--restore") {
    do {
        try HCIConfigurationStore().recoverAtStartup()
        serviceLog("restore_command result=completed")
        exit(0)
    } catch {
        serviceLog("restore_command result=failed")
        exit(1)
    }
}

serviceLog("startup version=\(AppleRemoteHCIConstants.serviceVersion)")
private let service = HCIService()
private let listener = NSXPCListener(
    machServiceName: AppleRemoteHCIConstants.machServiceName
)
listener.delegate = service
listener.resume()
RunLoop.main.run()
