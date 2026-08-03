import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

@MainActor
final class RemoteMacConnection: ObservableObject {
    enum State: Equatable {
        case searching
        case awaitingLocalNetworkPermission
        case connecting
        case awaitingApproval
        case connected
        case connectedWithError(String)
        case unavailable(String)
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var macName = "正在查找 Mac"
    @Published private(set) var isVoiceActive = false

    private let queue = DispatchQueue(label: "RemoteMicIOS.network", qos: .userInitiated)
    private let microphone = MicrophoneStreamer()
    private let identityPrivateKey: P256.Signing.PrivateKey?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RemoteMicIOS",
        category: "NearbyConnection"
    )
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var isBrowserReady = false
    private var pendingEndpoint: NWEndpoint?
    private var receiveBuffer = Data()
    private var voiceRequestID: UInt64 = 0
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var pairingCode: String?

    init() {
        identityPrivateKey = InstallationIdentity.loadOrCreate()
        microphone.onSamples = { [weak self] samples in
            self?.sendAudio(samples)
        }
    }

    var statusText: String {
        switch state {
        case .searching: return "正在查找"
        case .awaitingLocalNetworkPermission: return "等待网络授权"
        case .connecting: return "正在连接"
        case .awaitingApproval:
            return pairingCode.map { "确认码 \($0)" } ?? "等待 Mac 确认"
        case .connected: return "已连接"
        case .connectedWithError: return "需要处理"
        case .unavailable: return "未连接"
        }
    }

    var isConnected: Bool {
        switch state {
        case .connected, .connectedWithError: return true
        default: return false
        }
    }

    var displayedPairingCode: String? {
        guard case .awaitingApproval = state else { return nil }
        return pairingCode
    }

    var guidanceText: String {
        switch state {
        case let .connectedWithError(detail), let .unavailable(detail):
            return detail
        case .awaitingLocalNetworkPermission:
            return "请允许访问本地网络，以发现附近的 Mac"
        default:
            return "麦克风仅在按住时启用"
        }
    }

    var hasIssue: Bool {
        switch state {
        case .awaitingLocalNetworkPermission, .connectedWithError, .unavailable: return true
        default: return false
        }
    }

    func start() {
        guard browser == nil else { return }
        state = .searching
        macName = "正在查找 Mac"

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_remotemic._tcp", domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, browser === self.browser else { return }
                self.handleBrowserState(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, browser === self.browser else { return }
                self.handleBrowseResults(results)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func restartDiscovery() {
        endVoice()
        connection?.cancel()
        connection = nil
        privateKey = nil
        sessionKey = nil
        pairingCode = nil
        browser?.cancel()
        browser = nil
        isBrowserReady = false
        pendingEndpoint = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        start()
    }

    func send(_ command: RemoteCommand) {
        guard isConnected, let commandName = command.wireName else { return }
        if case .connectedWithError = state {
            state = .connected
        }
        send(RemoteWireMessage(type: "command", command: commandName))
    }

    func beginVoice() {
        voiceRequestID &+= 1
        let requestID = voiceRequestID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard await microphone.requestPermission() else {
                    throw MicrophoneStreamer.StreamError.permissionDenied
                }
                guard voiceRequestID == requestID, isConnected else { return }
                try await microphone.start()
                guard voiceRequestID == requestID, isConnected else {
                    microphone.stop()
                    return
                }
                isVoiceActive = true
                send(RemoteWireMessage(type: "voiceStart"))
            } catch {
                guard voiceRequestID == requestID else { return }
                isVoiceActive = false
                logger.error("Microphone start failed: \(String(describing: error), privacy: .public)")
                let message: String
                if case MicrophoneStreamer.StreamError.permissionDenied = error {
                    message = "请在系统设置中允许麦克风访问"
                } else {
                    message = "暂时无法使用麦克风，请稍后重试"
                }
                if isConnected {
                    state = .connectedWithError(message)
                } else {
                    state = .unavailable(message)
                }
            }
        }
    }

    func endVoice() {
        voiceRequestID &+= 1
        let wasActive = isVoiceActive
        microphone.stop()
        isVoiceActive = false
        if wasActive {
            send(RemoteWireMessage(type: "voiceStop"))
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        guard isBrowserReady else {
            pendingEndpoint = endpoint
            return
        }
        guard connection == nil else { return }
        pendingEndpoint = nil
        state = .connecting
        if case let .service(name, _, _, _) = endpoint {
            macName = name
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                self?.handleConnectionState(state, connection: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ connectionState: NWConnection.State, connection: NWConnection?) {
        guard connection === self.connection else { return }
        switch connectionState {
        case .ready:
            guard let identityPrivateKey else {
                handleFailure("无法准备安全连接，请重新安装 App 后重试")
                return
            }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicKeyData = privateKey.publicKey.rawRepresentation
            guard let identitySignature = try? identityPrivateKey.signature(
                for: Self.identityProof(for: publicKeyData)
            ) else {
                handleFailure("无法准备安全连接，请重新安装 App 后重试")
                return
            }
            self.privateKey = privateKey
            sendPlain(RemoteWireMessage(
                type: "hello",
                deviceName: UIDevice.current.name,
                publicKey: publicKeyData.base64EncodedString(),
                identityPublicKey: identityPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
                identitySignature: identitySignature.rawRepresentation.base64EncodedString()
            ))
            receiveNext()
        case let .failed(error):
            logger.error("Connection failed: \(String(describing: error), privacy: .public)")
            handleFailure("连接 Mac 失败，请确认两台设备在附近并重试")
        case .cancelled:
            if self.connection != nil {
                handleFailure("与 Mac 的连接已断开，请重新连接")
            }
        default:
            break
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data { self.consume(data) }
                if isComplete || error != nil {
                    if let error {
                        self.logger.error("Receive failed: \(String(describing: error), privacy: .public)")
                    }
                    self.handleFailure("与 Mac 的连接已断开，请重新连接")
                } else {
                    self.receiveNext()
                }
            }
        }
    }

    private func consume(_ data: Data) {
        receiveBuffer.append(data)
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let frame = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !frame.isEmpty,
                  let message = try? JSONDecoder().decode(RemoteWireMessage.self, from: frame)
            else { continue }
            handleEnvelope(message)
        }
    }

    private func handleEnvelope(_ message: RemoteWireMessage) {
        if message.type == "serverKey" {
            establishSession(with: message)
            return
        }
        guard message.type == "secure",
              let message = decrypt(message)
        else { return }
        handleSecure(message)
    }

    private func establishSession(with message: RemoteWireMessage) {
        guard let privateKey,
              let encoded = message.publicKey,
              let data = Data(base64Encoded: encoded),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        else {
            handleFailure("无法建立安全连接")
            return
        }
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("RemoteMic nearby session".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        sessionKey = key
        self.privateKey = nil
        pairingCode = Self.pairingCode(for: key)
        state = .awaitingApproval
        send(RemoteWireMessage(type: "pairingReady"))
    }

    private func handleSecure(_ message: RemoteWireMessage) {
        switch message.type {
        case "ready":
            macName = message.deviceName ?? macName
            state = .connected
        case "denied":
            handleFailure("Mac 拒绝了本次连接")
        case "error":
            endVoice()
            if let detail = message.detail {
                logger.error("Mac reported an operation error: \(detail, privacy: .public)")
            }
            state = .connectedWithError("Mac 暂时无法执行这个操作，请稍后重试")
        default:
            break
        }
    }

    private nonisolated func sendAudio(_ samples: [Int16]) {
        let data = samples.withUnsafeBytes { Data($0) }
        Task { @MainActor [weak self] in
            guard let self, isVoiceActive, isConnected else { return }
            send(RemoteWireMessage(type: "audio", samples: data.base64EncodedString()))
        }
    }

    private func send(_ message: RemoteWireMessage) {
        guard let sessionKey,
              let cleartext = try? JSONEncoder().encode(message),
              let sealed = try? ChaChaPoly.seal(cleartext, using: sessionKey)
        else { return }
        sendPlain(RemoteWireMessage(
            type: "secure",
            payload: sealed.combined.base64EncodedString()
        ))
    }

    private func sendPlain(_ message: RemoteWireMessage) {
        guard let connection,
              var data = try? JSONEncoder().encode(message)
        else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.logger.error("Send failed: \(String(describing: error), privacy: .public)")
                self.handleFailure("发送失败，请重新连接 Mac 后重试")
            }
        })
    }

    private func handleBrowserState(_ browserState: NWBrowser.State) {
        switch browserState {
        case .ready:
            isBrowserReady = true
            if connection == nil {
                state = .searching
                macName = "正在查找 Mac"
                if let pendingEndpoint {
                    connect(to: pendingEndpoint)
                }
            }
        case let .waiting(error):
            isBrowserReady = false
            logger.notice("Bonjour browser is waiting: \(String(describing: error), privacy: .public)")
            if connection == nil {
                state = .awaitingLocalNetworkPermission
                macName = "等待访问本地网络"
            }
        case let .failed(error):
            isBrowserReady = false
            logger.error("Bonjour browser failed: \(String(describing: error), privacy: .public)")
            browser?.cancel()
            browser = nil
            handleFailure("无法发现附近的 Mac，请检查本地网络权限后重试")
        case .cancelled:
            isBrowserReady = false
        default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        guard let endpoint = results.first?.endpoint else {
            pendingEndpoint = nil
            return
        }
        pendingEndpoint = endpoint
        if isBrowserReady {
            connect(to: endpoint)
        }
    }

    private func handleFailure(_ detail: String) {
        endVoice()
        connection?.cancel()
        connection = nil
        privateKey = nil
        sessionKey = nil
        pairingCode = nil
        pendingEndpoint = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        state = .unavailable(detail)
        macName = "未找到可用的 Mac"
    }

    private func decrypt(_ envelope: RemoteWireMessage) -> RemoteWireMessage? {
        guard let sessionKey,
              let encoded = envelope.payload,
              let data = Data(base64Encoded: encoded),
              let sealedBox = try? ChaChaPoly.SealedBox(combined: data),
              let cleartext = try? ChaChaPoly.open(sealedBox, using: sessionKey)
        else { return nil }
        return try? JSONDecoder().decode(RemoteWireMessage.self, from: cleartext)
    }

    private static func pairingCode(for key: SymmetricKey) -> String {
        let value = key.withUnsafeBytes { bytes in
            bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return String(format: "%02d", value % 100)
    }

    private static func identityProof(for sessionPublicKey: Data) -> Data {
        var proof = Data("RemoteMic nearby identity v1\0".utf8)
        proof.append(sessionPublicKey)
        return proof
    }
}

private enum InstallationIdentity {
    private static let installationMarkerKey = "nearbyIdentity.installationInitialized"
    private static let keychainAccount = "nearby-controller-identity-v1"

    static func loadOrCreate() -> P256.Signing.PrivateKey? {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: installationMarkerKey) {
            deleteStoredKey()
            defaults.set(true, forKey: installationMarkerKey)
        }

        if let storedData = storedKeyData() {
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: storedData) {
                return key
            }
            deleteStoredKey()
        }

        let key = P256.Signing.PrivateKey()
        guard store(key.rawRepresentation) else { return nil }
        return key
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "RemoteMicIOS",
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func storedKeyData() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private static func store(_ data: Data) -> Bool {
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteStoredKey() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

private extension RemoteCommand {
    var wireName: String? {
        switch self {
        case .power: return "power"
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .confirm: return "ok"
        case .back: return "back"
        case .home: return "home"
        case .menu: return "menu"
        case .television: return "tv"
        case .volumeUp: return "volume_up"
        case .volumeDown: return "volume_down"
        case .chooseDevice, .voiceStart, .voiceStop: return nil
        }
    }
}
