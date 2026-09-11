import AppleRemoteAudioCore
import Foundation
import Security
import XPC

/// Narrow in-memory client for macOS's private Bluetooth packet diagnostic service.
/// Raw packet bytes stay on `stateQueue` and are never logged or written to disk.
public final class AppleRemotePacketLoggerClient: @unchecked Sendable {
    public enum Event: Equatable {
        case connecting
        case requiresAuthorization
        case authorizing
        case authorized
        case profileRequired
        case stopped
        case failed(Failure)
    }

    public enum Failure: Equatable {
        case authorizationCreate(OSStatus)
        case authorizationRuleLookup(OSStatus)
        case authorizationRuleTooWeak
        case authorizationRuleOwnedByAnotherClient
        case authorizationRuleRegistration(OSStatus)
        case authorizationRuleSealFailed
        case authorizationDenied(OSStatus)
        case authorizationExternalForm(OSStatus)
        case authorizationAlreadyAttempted
        case connectionInterrupted
        case connectionInvalid
        case connectionTimedOut
        case authorizationTimedOut
        case malformedMessage(count: Int, hasRequiresAuthorization: Bool, hasPacket: Bool)
        case malformedPacket
        case trafficLimitExceeded

        public var diagnosticCode: String {
            switch self {
            case .authorizationCreate(let status): return "authorization_create_\(status)"
            case .authorizationRuleLookup(let status): return "authorization_rule_lookup_\(status)"
            case .authorizationRuleTooWeak: return "authorization_rule_too_weak"
            case .authorizationRuleOwnedByAnotherClient: return "authorization_rule_owned_by_another_client"
            case .authorizationRuleRegistration(let status): return "authorization_rule_registration_\(status)"
            case .authorizationRuleSealFailed: return "authorization_rule_seal_failed"
            case .authorizationDenied(let status): return "authorization_denied_\(status)"
            case .authorizationExternalForm(let status): return "authorization_external_form_\(status)"
            case .authorizationAlreadyAttempted: return "authorization_already_attempted"
            case .connectionInterrupted: return "connection_interrupted"
            case .connectionInvalid: return "connection_invalid"
            case .connectionTimedOut: return "connection_timed_out"
            case .authorizationTimedOut: return "authorization_timed_out"
            case .malformedMessage(let count, let hasRequiresAuthorization, let hasPacket):
                return "malformed_message_count_\(count)_requires_\(hasRequiresAuthorization)_packet_\(hasPacket)"
            case .malformedPacket: return "malformed_packet"
            case .trafficLimitExceeded: return "traffic_limit_exceeded"
            }
        }
    }

    private enum State {
        case stopped
        case connecting
        case waitingForAuthorization
        case authorizing
        case streaming
    }

    private enum MessageOrigin {
        case connection
        case requestReply
    }

    private struct AuthorizationGrant {
        let reference: AuthorizationRef
        let createdRule: Bool
    }

    private enum AuthorizationResult {
        case granted(AuthorizationGrant)
        case failed(Failure)
    }

    private static let serviceName = "com.apple.bluetooth.BTPacketLogger"
    private static let authorizationRight = "com.apple.PacketLogger.HCI"
    private static let trustedTemporaryOwnerIdentifier =
        "com.hd838a.SayAll.AppleRemoteHCIService"
    private static let maximumRecordLength = 13 + 4 + Int(UInt16.max)
    private static let maximumBytesPerSecond = 8 * 1_024 * 1_024
    private static let maximumPacketsPerSecond = 20_000

    private let stateQueue: DispatchQueue
    private let authorizationQueue = DispatchQueue(
        label: "com.hd838a.RemoteMic.appleRemote.packetLogger.authorization",
        qos: .userInitiated
    )
    private let callbackQueue: DispatchQueue
    private let allowsPacketAsAuthorization: Bool
    private let sealAuthorizationRight: (@escaping (Bool) -> Void) -> Void
    private let onPacket: (Data) -> Void
    private let onEvent: (Event) -> Void

    private var state = State.stopped
    private var generation: UInt64 = 0
    private var connection: xpc_connection_t?
    private var authorization: AuthorizationRef?
    private var createdAuthorizationRule = false
    private var authorizationAttempted = false
    private var didEmitAuthorized = false
    private var trafficWindowStartedAt: UInt64 = 0
    private var trafficBytes = 0
    private var trafficPackets = 0

    public init(
        stateQueue: DispatchQueue,
        callbackQueue: DispatchQueue,
        allowsPacketAsAuthorization: Bool = false,
        sealAuthorizationRight: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
            completion(true)
        },
        onPacket: @escaping (Data) -> Void,
        onEvent: @escaping (Event) -> Void
    ) {
        self.stateQueue = stateQueue
        self.callbackQueue = callbackQueue
        self.allowsPacketAsAuthorization = allowsPacketAsAuthorization
        self.sealAuthorizationRight = sealAuthorizationRight
        self.onPacket = onPacket
        self.onEvent = onEvent
    }

    deinit {
        stopSynchronously(emitEvent: false)
    }

    public func start() {
        stateQueue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    public func requestAuthorization() {
        stateQueue.async { [weak self] in
            self?.requestAuthorizationOnQueue()
        }
    }

    public func stop() {
        stateQueue.async { [weak self] in
            self?.stopOnQueue(emitEvent: true)
        }
    }

    private func startOnQueue() {
        guard state == .stopped else { return }
        generation &+= 1
        let activeGeneration = generation
        authorizationAttempted = false
        didEmitAuthorized = false
        resetTrafficBudget()
        state = .connecting

        let newConnection = Self.serviceName.withCString { serviceName in
            xpc_connection_create_mach_service(
                serviceName,
                stateQueue,
                UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
            )
        }
        connection = newConnection
        xpc_connection_set_event_handler(newConnection) { [weak self] object in
            self?.handle(object, origin: .connection, generation: activeGeneration)
        }
        emit(.connecting)
        xpc_connection_activate(newConnection)
        send(xpc_dictionary_create_empty(), over: newConnection, generation: activeGeneration)

        stateQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.generation == activeGeneration, self.state == .connecting else { return }
            self.fail(.connectionTimedOut)
        }
    }

    private func requestAuthorizationOnQueue() {
        guard state == .waitingForAuthorization else { return }
        guard !authorizationAttempted else {
            fail(.authorizationAlreadyAttempted)
            return
        }
        authorizationAttempted = true
        state = .authorizing
        let requestGeneration = generation
        emit(.authorizing)

        authorizationQueue.async { [weak self] in
            let result = Self.performAuthorizationRequest()
            self?.stateQueue.async { [weak self] in
                self?.handleAuthorizationResult(result, generation: requestGeneration)
            }
        }

        stateQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.generation == requestGeneration, self.state == .authorizing else { return }
            self.fail(.authorizationTimedOut)
        }
    }

    private func handleAuthorizationResult(_ result: AuthorizationResult, generation resultGeneration: UInt64) {
        guard generation == resultGeneration, state == .authorizing else {
            if case .granted(let grant) = result {
                AuthorizationFree(grant.reference, [.destroyRights])
            }
            return
        }
        switch result {
        case .failed(let failure):
            fail(failure)
        case .granted(let grant):
            authorization = grant.reference
            createdAuthorizationRule = grant.createdRule
            sealAuthorizationRight { [weak self] sealed in
                self?.stateQueue.async { [weak self] in
                    guard let self,
                          self.generation == resultGeneration,
                          self.state == .authorizing else {
                        return
                    }
                    guard sealed else {
                        self.fail(.authorizationRuleSealFailed)
                        return
                    }
                    self.sendAuthorizationExternalForm(generation: resultGeneration)
                }
            }
        }
    }

    private func sendAuthorizationExternalForm(generation resultGeneration: UInt64) {
        guard let authorization else {
            fail(.connectionInvalid)
            return
        }
        var externalForm = AuthorizationExternalForm()
        let status = AuthorizationMakeExternalForm(authorization, &externalForm)
        guard status == errAuthorizationSuccess else {
            fail(.authorizationExternalForm(status))
            return
        }
        let message = xpc_dictionary_create_empty()
        withUnsafePointer(to: &externalForm) { pointer in
            xpc_dictionary_set_data(
                message,
                "Authentication",
                UnsafeRawPointer(pointer),
                MemoryLayout<AuthorizationExternalForm>.size
            )
        }
        _ = withUnsafeMutableBytes(of: &externalForm) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
        guard let connection else {
            fail(.connectionInvalid)
            return
        }
        send(message, over: connection, generation: resultGeneration)
    }

    private func send(
        _ message: xpc_object_t,
        over connection: xpc_connection_t,
        generation requestGeneration: UInt64
    ) {
        xpc_connection_send_message_with_reply(connection, message, stateQueue) { [weak self] reply in
            self?.handle(reply, origin: .requestReply, generation: requestGeneration)
        }
    }

    private func handle(
        _ object: xpc_object_t,
        origin: MessageOrigin,
        generation eventGeneration: UInt64
    ) {
        guard generation == eventGeneration, state != .stopped else { return }
        let type = xpc_get_type(object)
        if type == XPC_TYPE_ERROR {
            guard origin == .connection else { return }
            if xpc_equal(object, XPC_ERROR_CONNECTION_INTERRUPTED) {
                fail(.connectionInterrupted)
            } else {
                fail(.connectionInvalid)
            }
            return
        }
        guard type == XPC_TYPE_DICTIONARY else {
            fail(.malformedMessage(count: -1, hasRequiresAuthorization: false, hasPacket: false))
            return
        }
        let dictionaryCount = xpc_dictionary_get_count(object)
        let hasRequiresAuthorization = xpc_dictionary_get_value(object, "RequiresAuth") != nil
        let hasPacket = xpc_dictionary_get_value(object, "packet") != nil
        if origin == .requestReply, dictionaryCount == 0 {
            return
        }
        guard dictionaryCount == 1 else {
            fail(.malformedMessage(
                count: dictionaryCount,
                hasRequiresAuthorization: hasRequiresAuthorization,
                hasPacket: hasPacket
            ))
            return
        }

        if let requiresAuthorization = xpc_dictionary_get_value(object, "RequiresAuth") {
            guard xpc_get_type(requiresAuthorization) == XPC_TYPE_BOOL else {
                fail(.malformedMessage(
                    count: dictionaryCount,
                    hasRequiresAuthorization: true,
                    hasPacket: false
                ))
                return
            }
            if xpc_bool_get_value(requiresAuthorization) {
                if state == .waitingForAuthorization || state == .authorizing || state == .streaming {
                    return
                }
                state = .waitingForAuthorization
                emit(.requiresAuthorization)
            } else {
                markAuthorized()
            }
            return
        }

        var packetLength = 0
        guard let packetBytes = xpc_dictionary_get_data(object, "packet", &packetLength),
              packetLength > 0,
              packetLength <= Self.maximumRecordLength else {
            fail(.malformedPacket)
            return
        }
        guard consumeTrafficBudget(packetLength) else {
            fail(.trafficLimitExceeded)
            return
        }
        let packet = Data(bytes: packetBytes, count: packetLength)
        if AppleRemotePacketLoggerRecord.isProfileRequired(packet) {
            state = .stopped
            invalidateConnection()
            emit(.profileRequired)
            return
        }
        guard state == .authorizing
                || state == .streaming
                || (state == .connecting && allowsPacketAsAuthorization) else {
            if state == .connecting {
                // Some macOS builds deliver one early controller packet before
                // the authoritative RequiresAuth response. It is not proof of
                // authorization; discard it and keep waiting for the daemon's
                // explicit readiness state instead of tearing down the stream.
                return
            }
            fail(.malformedMessage(
                count: dictionaryCount,
                hasRequiresAuthorization: false,
                hasPacket: true
            ))
            return
        }
        markAuthorized()
        onPacket(packet)
    }

    private func markAuthorized() {
        state = .streaming
        guard !didEmitAuthorized else { return }
        didEmitAuthorized = true
        emit(.authorized)
    }

    private func fail(_ failure: Failure) {
        state = .stopped
        didEmitAuthorized = false
        invalidateConnection()
        emit(.failed(failure))
    }

    private func stopOnQueue(emitEvent: Bool) {
        generation &+= 1
        state = .stopped
        invalidateConnection()
        releaseAuthorization()
        resetTrafficBudget()
        if emitEvent { emit(.stopped) }
    }

    private func stopSynchronously(emitEvent: Bool) {
        stateQueue.sync {
            stopOnQueue(emitEvent: emitEvent)
        }
    }

    private func invalidateConnection() {
        if let connection {
            xpc_connection_cancel(connection)
            self.connection = nil
        }
    }

    private func releaseAuthorization() {
        guard let authorization else { return }
        if createdAuthorizationRule {
            Self.authorizationRight.withCString { rightName in
                _ = AuthorizationRightRemove(authorization, rightName)
            }
        }
        AuthorizationFree(authorization, [.destroyRights])
        self.authorization = nil
        createdAuthorizationRule = false
    }

    private func emit(_ event: Event) {
        callbackQueue.async { [onEvent] in onEvent(event) }
    }

    private func consumeTrafficBudget(_ byteCount: Int) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if trafficWindowStartedAt == 0 || now &- trafficWindowStartedAt >= 1_000_000_000 {
            trafficWindowStartedAt = now
            trafficBytes = 0
            trafficPackets = 0
        }
        guard byteCount <= Self.maximumBytesPerSecond,
              trafficBytes <= Self.maximumBytesPerSecond - byteCount,
              trafficPackets < Self.maximumPacketsPerSecond else { return false }
        trafficBytes += byteCount
        trafficPackets += 1
        return true
    }

    private func resetTrafficBudget() {
        trafficWindowStartedAt = 0
        trafficBytes = 0
        trafficPackets = 0
    }

    private static func performAuthorizationRequest() -> AuthorizationResult {
        var authorization: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authorization)
        guard createStatus == errAuthorizationSuccess, let authorization else {
            return .failed(.authorizationCreate(createStatus))
        }

        var createdRule = false
        var definition: CFDictionary?
        let lookupStatus = authorizationRight.withCString {
            AuthorizationRightGet($0, &definition)
        }
        if lookupStatus == errAuthorizationDenied {
            let rule: CFDictionary = [
                "class" as CFString: "allow" as CFString,
            ] as CFDictionary
            let registrationStatus = authorizationRight.withCString {
                AuthorizationRightSet(
                    authorization,
                    $0,
                    rule,
                    "允许无线麦接收 Apple Remote 蓝牙音频。" as CFString,
                    nil,
                    nil
                )
            }
            guard registrationStatus == errAuthorizationSuccess else {
                AuthorizationFree(authorization, [.destroyRights])
                return .failed(.authorizationRuleRegistration(registrationStatus))
            }
            createdRule = true
        } else if lookupStatus == errAuthorizationSuccess {
            guard let definition, authorizationRuleIsStrongEnough(definition) else {
                AuthorizationFree(authorization, [.destroyRights])
                return .failed(.authorizationRuleTooWeak)
            }
            guard authorizationRuleBelongsToCurrentApp(definition) else {
                AuthorizationFree(authorization, [.destroyRights])
                return .failed(.authorizationRuleOwnedByAnotherClient)
            }
        } else {
            AuthorizationFree(authorization, [.destroyRights])
            return .failed(.authorizationRuleLookup(lookupStatus))
        }

        let status = authorizationRight.withCString { rightName in
            var item = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(
                    authorization,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil
                )
            }
        }
        guard status == errAuthorizationSuccess else {
            if createdRule {
                authorizationRight.withCString { _ = AuthorizationRightRemove(authorization, $0) }
            }
            AuthorizationFree(authorization, [.destroyRights])
            return .failed(.authorizationDenied(status))
        }
        return .granted(.init(reference: authorization, createdRule: createdRule))
    }

    private static func authorizationRuleIsStrongEnough(_ definition: CFDictionary) -> Bool {
        let values = definition as NSDictionary
        guard values["class"] as? String == "user",
              values["group"] as? String == "admin",
              values["authenticate-user"] as? Bool == true,
              values["shared"] as? Bool == false,
              let timeout = values["timeout"] as? NSNumber,
              timeout.int64Value == 0 else {
            return false
        }
        return values["session-owner"] == nil && values["rule"] == nil
    }

    private static func authorizationRuleBelongsToCurrentApp(
        _ definition: CFDictionary
    ) -> Bool {
        let identifier = (definition as NSDictionary)["identifier"] as? String
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        return identifier == bundleIdentifier
            || identifier == trustedTemporaryOwnerIdentifier
    }
}
