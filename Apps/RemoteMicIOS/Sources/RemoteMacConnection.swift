import CryptoKit
import Foundation
import Network
import UIKit

@MainActor
final class RemoteMacConnection: ObservableObject {
    enum State: Equatable {
        case searching
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
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var voiceRequestID: UInt64 = 0
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var pairingCode: String?

    init() {
        microphone.onSamples = { [weak self] samples in
            self?.sendAudio(samples)
        }
    }

    var statusText: String {
        switch state {
        case .searching: return "正在查找"
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

    var guidanceText: String {
        switch state {
        case let .connectedWithError(detail), let .unavailable(detail):
            return detail
        default:
            return "麦克风仅在按住时启用"
        }
    }

    var hasIssue: Bool {
        switch state {
        case .connectedWithError, .unavailable: return true
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
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error), let .waiting(error):
                DispatchQueue.main.async {
                    self?.handleFailure(error.localizedDescription)
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            DispatchQueue.main.async {
                self?.connect(to: endpoint)
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
                if isConnected {
                    state = .connectedWithError("无法使用麦克风，请在系统设置中允许访问")
                } else {
                    state = .unavailable("无法使用麦克风，请在系统设置中允许访问")
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
        guard connection == nil else { return }
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
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            self.privateKey = privateKey
            sendPlain(RemoteWireMessage(
                type: "hello",
                deviceName: UIDevice.current.name,
                publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
            ))
            receiveNext()
        case let .failed(error):
            handleFailure(error.localizedDescription)
        case .cancelled:
            if self.connection != nil {
                handleFailure("连接已断开")
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
                    self.handleFailure(error?.localizedDescription ?? "连接已断开")
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
            state = .connectedWithError(message.detail ?? "Mac 无法执行这个操作")
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
                self?.handleFailure(error.localizedDescription)
            }
        })
    }

    private func handleFailure(_ detail: String) {
        endVoice()
        connection?.cancel()
        connection = nil
        privateKey = nil
        sessionKey = nil
        pairingCode = nil
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
        return String(format: "%06d", value % 1_000_000)
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
