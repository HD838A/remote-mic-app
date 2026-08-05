import CryptoKit
import Foundation
import Network

struct PhoneRemoteWireMessage: Codable {
    static let buttonEventsCapability = "buttonEventsV1"

    let type: String
    var deviceName: String?
    var command: String?
    var samples: String?
    var detail: String?
    var publicKey: String?
    var identityPublicKey: String?
    var identitySignature: String?
    var buttonTitles: [String: String]?
    var appVersion: String?
    var payload: String?
    var capabilities: [String]?
    var buttonPhase: String?
}

enum PhoneRemoteIdentityVerification: Equatable {
    case unavailable
    case verified(String)
    case invalid
}

enum PhoneRemoteIdentityVerifier {
    static func verify(
        identityPublicKey encodedIdentityKey: String?,
        identitySignature encodedSignature: String?,
        sessionPublicKey: Data
    ) -> PhoneRemoteIdentityVerification {
        if encodedIdentityKey == nil, encodedSignature == nil {
            return .unavailable
        }
        guard let encodedIdentityKey,
              let encodedSignature,
              let identityKeyData = Data(base64Encoded: encodedIdentityKey),
              let signatureData = Data(base64Encoded: encodedSignature),
              let identityKey = try? P256.Signing.PublicKey(rawRepresentation: identityKeyData),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              identityKey.isValidSignature(signature, for: proof(for: sessionPublicKey))
        else {
            return .invalid
        }
        let fingerprint = SHA256.hash(data: identityKeyData)
            .map { String(format: "%02x", $0) }
            .joined()
        return .verified(fingerprint)
    }

    static func proof(for sessionPublicKey: Data) -> Data {
        var proof = Data("RemoteMic nearby identity v1\0".utf8)
        proof.append(sessionPublicKey)
        return proof
    }
}

final class PhoneRemoteServer {
    typealias ApprovalHandler = (String, String, String?, @escaping (Bool) -> Void) -> Void

    static func shouldReplaceExistingClient(
        existingIsApproved: Bool,
        newIsApproved: Bool
    ) -> Bool {
        newIsApproved || !existingIsApproved
    }

    private let queue = DispatchQueue(label: "RemoteMic.phoneRemote", qos: .userInitiated)
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var buttonTitles: [String: String] = [:]

    var onApprovalRequested: ApprovalHandler?
    var onApprovalCancelled: (() -> Void)?
    var isIdentityTrusted: ((String) -> Bool)?
    var onCommand: ((RemoteButton, @escaping (Bool) -> Void) -> Void)?
    var onButtonEvent: ((RemoteButton, RemoteButtonPhase, @escaping (Bool) -> Void) -> Void)?
    var onButtonEventsReset: (() -> Void)?
    var onVoiceStart: ((@escaping (Bool) -> Void) -> Void)?
    var onVoiceStop: (() -> Void)?
    var onAudio: (([Int16]) -> Void)?

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            let activeClients = Array(clients.values)
            clients.removeAll()
            activeClients.forEach { $0.cancel() }
        }
    }

    func updateButtonTitles(_ titles: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            buttonTitles = titles
            clients.values.forEach { $0.updateButtonTitles(titles) }
        }
    }

    private func startOnQueue() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: Self.macName,
                type: "_remotemic._tcp"
            )
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    AppLogger.shared.write("PHONE REMOTE listener_ready name=\(Self.macName)")
                case let .failed(error):
                    AppLogger.shared.write("PHONE REMOTE listener_failed error=\(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            AppLogger.shared.write("PHONE REMOTE listener_create_failed error=\(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let pendingClients = clients.values.filter {
            Self.shouldReplaceExistingClient(
                existingIsApproved: $0.hasApprovedSession,
                newIsApproved: false
            )
        }
        pendingClients.forEach { $0.cancel() }
        let client = Client(
            connection: connection,
            queue: queue,
            macName: Self.macName,
            appVersion: Self.appVersion,
            buttonTitles: buttonTitles
        )
        let identifier = ObjectIdentifier(client)
        clients[identifier] = client
        client.onApproved = { [weak self, weak client] in
            guard let self, let client else { return }
            let supersededClients = clients.values.filter {
                $0 !== client && Self.shouldReplaceExistingClient(
                    existingIsApproved: $0.hasApprovedSession,
                    newIsApproved: true
                )
            }
            supersededClients.forEach { $0.cancel() }
        }
        client.isIdentityTrusted = { [weak self] fingerprint in
            self?.isIdentityTrusted?(fingerprint) ?? false
        }
        client.onApprovalRequested = { [weak self, weak client] deviceName, pairingCode, fingerprint in
            guard let self, let client else { return }
            guard let approval = self.onApprovalRequested else {
                client.resolveApproval(false)
                return
            }
            approval(deviceName, pairingCode, fingerprint) { [weak client] allowed in
                self.queue.async {
                    client?.resolveApproval(allowed)
                }
            }
        }
        client.onCommand = { [weak self] button, completion in
            guard let handler = self?.onCommand else {
                completion(false)
                return
            }
            handler(button, completion)
        }
        client.onButtonEvent = { [weak self] button, phase, completion in
            guard let handler = self?.onButtonEvent else {
                completion(false)
                return
            }
            handler(button, phase, completion)
        }
        client.onVoiceStart = { [weak self] completion in
            guard let handler = self?.onVoiceStart else {
                completion(false)
                return
            }
            handler(completion)
        }
        client.onVoiceStop = { [weak self] in
            self?.onVoiceStop?()
        }
        client.onAudio = { [weak self] samples in
            self?.onAudio?(samples)
        }
        client.onClosed = { [weak self, weak client] in
            if client?.hasApprovedSession == true {
                self?.onButtonEventsReset?()
            }
            if client?.hasPendingApproval == true {
                self?.onApprovalCancelled?()
            }
            self?.clients.removeValue(forKey: identifier)
        }
        client.start()
    }

    private static var macName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

private final class Client {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let macName: String
    private let appVersion: String?
    private var receiveBuffer = Data()
    private var isApproved = false
    private var isVoiceActive = false
    private var isVoiceStarting = false
    private var requestedApproval = false
    private var sessionKey: SymmetricKey?
    private var identityFingerprint: String?
    private var waitsForPairingReady = false
    private var pendingDisplayName: String?
    private var pendingPairingCode: String?
    private var buttonTitles: [String: String]

    var isIdentityTrusted: ((String) -> Bool)?
    var onApprovalRequested: ((String, String, String?) -> Void)?
    var onCommand: ((RemoteButton, @escaping (Bool) -> Void) -> Void)?
    var onButtonEvent: ((RemoteButton, RemoteButtonPhase, @escaping (Bool) -> Void) -> Void)?
    var onVoiceStart: ((@escaping (Bool) -> Void) -> Void)?
    var onVoiceStop: (() -> Void)?
    var onAudio: (([Int16]) -> Void)?
    var onApproved: (() -> Void)?
    var onClosed: (() -> Void)?

    var hasApprovedSession: Bool { isApproved }
    var hasPendingApproval: Bool { requestedApproval && !isApproved }

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        macName: String,
        appVersion: String?,
        buttonTitles: [String: String]
    ) {
        self.connection = connection
        self.queue = queue
        self.macName = macName
        self.appVersion = appVersion
        self.buttonTitles = buttonTitles
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveNext()
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
        close()
    }

    func resolveApproval(_ allowed: Bool) {
        guard requestedApproval, !isApproved else { return }
        if allowed {
            isApproved = true
            sendReady()
            AppLogger.shared.write("PHONE REMOTE approved")
        } else {
            sendSecure(PhoneRemoteWireMessage(type: "denied")) { [weak self] in
                self?.connection.cancel()
            }
            AppLogger.shared.write("PHONE REMOTE denied")
        }
    }

    func updateButtonTitles(_ titles: [String: String]) {
        buttonTitles = titles
        guard isApproved else { return }
        sendSecure(PhoneRemoteWireMessage(type: "buttonTitles", buttonTitles: titles))
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { consume(data) }
            if complete || error != nil {
                close()
            } else {
                receiveNext()
            }
        }
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        guard receiveBuffer.count <= 2 * 1024 * 1024 else {
            connection.cancel()
            return
        }
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let frame = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !frame.isEmpty,
                  let message = try? JSONDecoder().decode(PhoneRemoteWireMessage.self, from: frame)
            else { continue }
            handleEnvelope(message)
        }
    }

    private func handleEnvelope(_ message: PhoneRemoteWireMessage) {
        if message.type == "hello" {
            guard !requestedApproval else { return }
            establishSession(with: message)
            return
        }
        guard message.type == "secure",
              let message = decrypt(message)
        else { return }
        if message.type == "pairingReady" {
            finishSessionSetup()
            return
        }
        guard isApproved else { return }
        handleSecure(message)
    }

    private func establishSession(with message: PhoneRemoteWireMessage) {
        guard let encoded = message.publicKey,
              let data = Data(base64Encoded: encoded),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
        else {
            connection.cancel()
            return
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        guard let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            connection.cancel()
            return
        }
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("RemoteMic nearby session".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        switch PhoneRemoteIdentityVerifier.verify(
            identityPublicKey: message.identityPublicKey,
            identitySignature: message.identitySignature,
            sessionPublicKey: data
        ) {
        case .unavailable:
            identityFingerprint = nil
            waitsForPairingReady = false
        case let .verified(fingerprint):
            identityFingerprint = fingerprint
            waitsForPairingReady = true
        case .invalid:
            connection.cancel()
            return
        }
        sessionKey = key
        requestedApproval = true

        let deviceName = message.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = deviceName
            .flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            ?? "iPhone"
        pendingDisplayName = displayName
        pendingPairingCode = Self.pairingCode(for: key)
        sendPlain(PhoneRemoteWireMessage(
            type: "serverKey",
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
        )) { [weak self] in
            guard let self, !self.waitsForPairingReady else { return }
            self.finishSessionSetup()
        }
    }

    private func finishSessionSetup() {
        guard requestedApproval,
              !isApproved,
              let displayName = pendingDisplayName,
              let pairingCode = pendingPairingCode
        else { return }
        pendingDisplayName = nil
        pendingPairingCode = nil
        if let identityFingerprint,
           isIdentityTrusted?(identityFingerprint) == true {
            isApproved = true
            sendReady()
            AppLogger.shared.write("PHONE REMOTE trusted_identity_approved")
            return
        }
        onApprovalRequested?(displayName, pairingCode, identityFingerprint)
    }

    private func sendReady() {
        sendSecure(PhoneRemoteWireMessage(
            type: "ready",
            deviceName: macName,
            buttonTitles: buttonTitles,
            appVersion: appVersion,
            capabilities: [PhoneRemoteWireMessage.buttonEventsCapability]
        )) { [weak self] in
            self?.onApproved?()
        }
    }

    private func handleSecure(_ message: PhoneRemoteWireMessage) {
        switch message.type {
        case "command":
            guard let raw = message.command,
                  let button = RemoteButton(rawValue: raw)
            else {
                sendCommandError()
                return
            }
            onCommand?(button) { [weak self] succeeded in
                guard let self else { return }
                queue.async {
                    if !succeeded {
                        self.sendCommandError()
                    }
                }
            }
        case "buttonEvent":
            guard let raw = message.command,
                  let button = RemoteButton(rawValue: raw),
                  let rawPhase = message.buttonPhase,
                  let phase = RemoteButtonPhase(rawValue: rawPhase)
            else {
                sendCommandError()
                return
            }
            onButtonEvent?(button, phase) { [weak self] succeeded in
                guard let self else { return }
                queue.async {
                    if !succeeded {
                        self.sendCommandError()
                    }
                }
            }
        case "voiceStart":
            guard !isVoiceActive, !isVoiceStarting else {
                sendSecure(PhoneRemoteWireMessage(
                    type: "error",
                    detail: "Mac 的语音输出当前不可用。"
                ))
                return
            }
            isVoiceStarting = true
            guard let onVoiceStart else {
                isVoiceStarting = false
                sendSecure(PhoneRemoteWireMessage(
                    type: "error",
                    detail: "Mac 的语音输出当前不可用。"
                ))
                return
            }
            onVoiceStart { [weak self] succeeded in
                guard let self else { return }
                queue.async {
                    guard self.isVoiceStarting else { return }
                    self.isVoiceStarting = false
                    if succeeded {
                        self.isVoiceActive = true
                    } else {
                        self.sendSecure(PhoneRemoteWireMessage(
                            type: "error",
                            detail: "Mac 的语音输出当前不可用。"
                        ))
                    }
                }
            }
        case "voiceStop":
            stopVoiceIfNeeded()
        case "audio":
            guard isVoiceActive,
                  let encoded = message.samples,
                  let data = Data(base64Encoded: encoded),
                  data.count.isMultiple(of: MemoryLayout<Int16>.size)
            else { return }
            onAudio?(Self.samples(from: data))
        default:
            break
        }
    }

    private func sendCommandError() {
        sendSecure(PhoneRemoteWireMessage(
            type: "error",
            detail: "Mac 需要辅助功能权限，或该按键当前不可用。"
        ))
    }

    private func stopVoiceIfNeeded() {
        guard isVoiceActive || isVoiceStarting else { return }
        isVoiceActive = false
        isVoiceStarting = false
        onVoiceStop?()
    }

    private func close() {
        stopVoiceIfNeeded()
        connection.stateUpdateHandler = nil
        connection.cancel()
        sessionKey = nil
        onClosed?()
        onClosed = nil
    }

    private func sendSecure(
        _ message: PhoneRemoteWireMessage,
        completion: (() -> Void)? = nil
    ) {
        guard let sessionKey,
              let cleartext = try? JSONEncoder().encode(message),
              let sealed = try? ChaChaPoly.seal(cleartext, using: sessionKey)
        else { return }
        sendPlain(PhoneRemoteWireMessage(
            type: "secure",
            payload: sealed.combined.base64EncodedString()
        ), completion: completion)
    }

    private func sendPlain(
        _ message: PhoneRemoteWireMessage,
        completion: (() -> Void)? = nil
    ) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                self?.connection.cancel()
                return
            }
            completion?()
        })
    }

    private static func samples(from data: Data) -> [Int16] {
        var samples = [Int16]()
        samples.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index < data.endIndex {
            let next = data.index(after: index)
            let low = UInt16(data[index])
            let high = UInt16(data[next]) << 8
            samples.append(Int16(bitPattern: low | high))
            index = data.index(next, offsetBy: 1)
        }
        return samples
    }

    private func decrypt(_ envelope: PhoneRemoteWireMessage) -> PhoneRemoteWireMessage? {
        guard let sessionKey,
              let encoded = envelope.payload,
              let data = Data(base64Encoded: encoded),
              let sealedBox = try? ChaChaPoly.SealedBox(combined: data),
              let cleartext = try? ChaChaPoly.open(sealedBox, using: sessionKey)
        else { return nil }
        return try? JSONDecoder().decode(PhoneRemoteWireMessage.self, from: cleartext)
    }

    private static func pairingCode(for key: SymmetricKey) -> String {
        let value = key.withUnsafeBytes { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return String(format: "%02d", value % 100)
    }
}
