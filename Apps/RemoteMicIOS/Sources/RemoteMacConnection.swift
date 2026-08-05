import AVFoundation
import CryptoKit
import Foundation
import Network
import OSLog
import Security
import UIKit

@MainActor
final class RemoteMacConnection: ObservableObject {
    enum DiscoveryMode: String, Equatable {
        case localNetwork = "local_network"
        case peerToPeer = "peer_to_peer"

        var includesPeerToPeer: Bool {
            self == .peerToPeer
        }
    }

    enum DiscoveryAction: Equatable {
        case switchToPeerToPeer
        case retryPeerToPeer
        case showRecoveryGuidance
    }

    struct ScheduledDiscoveryStep: Equatable {
        let delaySeconds: Double
        let action: DiscoveryAction
    }

    enum State: Equatable {
        case searching
        case awaitingLocalNetworkPermission
        case connecting
        case awaitingApproval
        case connected
        case connectedWithError(String)
        case unavailable(String)

        var shouldRestartDiscoveryOnActivation: Bool {
            switch self {
            case .awaitingLocalNetworkPermission, .unavailable: return true
            default: return false
            }
        }
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var macName = "正在查找 Mac"
    @Published private(set) var isVoiceActive = false
    @Published private(set) var buttonTitles: [String: String] = [:]
    @Published private(set) var macAppVersion: String?
    @Published private(set) var lastConnectedAt: Date?
    @Published private(set) var isNearbyNetworkReady = false

    private let queue = DispatchQueue(label: "RemoteMicIOS.network", qos: .userInitiated)
    private let microphone = MicrophoneStreamer()
    private let identityPrivateKey: P256.Signing.PrivateKey?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "RemoteMicIOS",
        category: "NearbyConnection"
    )
    private let diagnostics = DiagnosticsLogger.shared
    private let networkPathMonitor = NWPathMonitor()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var discoveryRetryTask: Task<Void, Never>?
    private var discoveryRetryAttempt = 0
    private var discoveryMode = DiscoveryMode.localNetwork
    private var hasDiscoveryResult = false
    private var pendingEndpoint: NWEndpoint?
    private var receiveBuffer = Data()
    private var voiceRequestID: UInt64 = 0
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var pairingCode: String?
    private var browserGeneration = 0
    private var browserStartedAt: Date?
    private var connectionGeneration = 0
    private var connectionStartedAt: Date?

    init() {
        identityPrivateKey = InstallationIdentity.loadOrCreate()
        diagnostics.record("connection_initialized", fields: [
            "identity_available": identityPrivateKey == nil ? "false" : "true"
        ])
        startNetworkPathMonitoring()
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

    func statusText(for language: AppLanguage) -> String {
        if case .awaitingApproval = state, let pairingCode {
            return language.format("确认码 %@", pairingCode)
        }
        return language.text(statusText)
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

    func guidanceText(for language: AppLanguage) -> String {
        language.text(guidanceText)
    }

    func macName(for language: AppLanguage) -> String {
        language.text(macName)
    }

    var hasIssue: Bool {
        switch state {
        case .awaitingLocalNetworkPermission, .connectedWithError, .unavailable: return true
        default: return false
        }
    }

    func start() {
        microphone.prepareIfAuthorized()
        guard browser == nil else {
            diagnostics.record("discovery_start_skipped", fields: ["reason": "browser_exists"])
            return
        }
        resetDiscoveryStrategy()
        startBrowser()
    }

    private func startBrowser() {
        state = .searching
        macName = "正在查找 Mac"
        browserGeneration += 1
        let generation = browserGeneration
        browserStartedAt = Date()
        diagnostics.record("discovery_start", fields: [
            "attempt": String(discoveryRetryAttempt),
            "browser": String(generation),
            "domain": "default",
            "mode": discoveryMode.rawValue,
            "peer_to_peer": discoveryMode.includesPeerToPeer ? "true" : "false",
            "service": "_remotemic._tcp",
        ])

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = discoveryMode.includesPeerToPeer
        let browser = NWBrowser(
            for: .bonjour(type: "_remotemic._tcp", domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, browser === self.browser else { return }
                self.handleBrowserState(state, generation: generation)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, changes in
            DispatchQueue.main.async {
                guard let self, browser === self.browser else { return }
                self.handleBrowseResults(results, changes: changes, generation: generation)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
        scheduleDiscoveryRetry()
    }

    func restartDiscovery(reason: String = "manual") {
        diagnostics.record("discovery_restart", fields: [
            "browser": String(browserGeneration),
            "reason": reason,
            "state": diagnosticStateName,
        ])
        discoveryRetryTask?.cancel()
        discoveryRetryTask = nil
        resetDiscoveryStrategy()
        endVoice()
        if connection != nil {
            diagnostics.record("connection_cancel_requested", fields: [
                "connection": String(connectionGeneration),
                "reason": reason,
            ])
        }
        connection?.cancel()
        connection = nil
        connectionStartedAt = nil
        privateKey = nil
        sessionKey = nil
        pairingCode = nil
        buttonTitles = [:]
        macAppVersion = nil
        if browser != nil {
            diagnostics.record("browser_cancel_requested", fields: [
                "browser": String(browserGeneration),
                "reason": reason,
            ])
        }
        browser?.cancel()
        browser = nil
        browserStartedAt = nil
        isNearbyNetworkReady = false
        pendingEndpoint = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        startBrowser()
    }

    func send(_ command: RemoteCommand) {
        guard isConnected, let commandName = command.wireName else { return }
        if case .connectedWithError = state {
            state = .connected
        }
        send(RemoteWireMessage(type: "command", command: commandName))
    }

    func buttonTitle(for command: RemoteCommand) -> String? {
        Self.buttonTitle(for: command, in: buttonTitles)
    }

    nonisolated static func buttonTitle(
        for command: RemoteCommand,
        in buttonTitles: [String: String]
    ) -> String? {
        guard let commandName = command.wireName else { return nil }
        return buttonTitles[commandName]
    }

    func beginVoice() {
        voiceRequestID &+= 1
        let requestID = voiceRequestID
        diagnostics.record("voice_request", fields: [
            "connected": isConnected ? "true" : "false",
            "permission": Self.microphonePermissionName(AVAudioApplication.shared.recordPermission),
        ])
        Task { @MainActor [weak self] in
            guard let self else { return }
            var didSendVoiceStart = false
            do {
                let permitted = await microphone.requestPermission()
                diagnostics.record("microphone_permission", fields: [
                    "granted": permitted ? "true" : "false",
                    "status": Self.microphonePermissionName(AVAudioApplication.shared.recordPermission),
                ])
                guard permitted else {
                    throw MicrophoneStreamer.StreamError.permissionDenied
                }
                guard voiceRequestID == requestID, isConnected else { return }
                send(RemoteWireMessage(type: "voiceStart"))
                didSendVoiceStart = true
                diagnostics.record("voice_state", fields: ["state": "start_sent"])
                try microphone.start()
                guard voiceRequestID == requestID, isConnected else {
                    microphone.stop()
                    send(RemoteWireMessage(type: "voiceStop"))
                    diagnostics.record("voice_state", fields: ["state": "cancelled_after_start"])
                    return
                }
                isVoiceActive = true
                diagnostics.record("voice_state", fields: ["state": "recording"])
            } catch {
                guard voiceRequestID == requestID else { return }
                if didSendVoiceStart {
                    send(RemoteWireMessage(type: "voiceStop"))
                }
                isVoiceActive = false
                diagnostics.record("voice_state", fields: [
                    "error": DiagnosticsLogger.errorCode(error),
                    "state": "failed",
                ])
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
            diagnostics.record("voice_state", fields: ["state": "stopped"])
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        guard isNearbyNetworkReady else {
            pendingEndpoint = endpoint
            diagnostics.record("connection_deferred", fields: ["reason": "browser_not_ready"])
            return
        }
        guard connection == nil else {
            diagnostics.record("connection_start_skipped", fields: ["reason": "connection_exists"])
            return
        }
        discoveryRetryTask?.cancel()
        discoveryRetryTask = nil
        pendingEndpoint = nil
        state = .connecting
        connectionGeneration += 1
        let generation = connectionGeneration
        connectionStartedAt = Date()
        diagnostics.record("connection_start", fields: [
            "connection": String(generation),
            "endpoint": Self.endpointCategory(endpoint),
            "mode": discoveryMode.rawValue,
            "peer_to_peer": discoveryMode.includesPeerToPeer ? "true" : "false",
        ])
        if case let .service(name, _, _, _) = endpoint {
            macName = name
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = discoveryMode.includesPeerToPeer
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                self?.handleConnectionState(
                    state,
                    connection: connection,
                    generation: generation
                )
            }
        }
        connection.pathUpdateHandler = { [weak self, weak connection] path in
            DispatchQueue.main.async {
                guard let self, connection === self.connection else { return }
                var fields = DiagnosticsLogger.networkPathFields(path)
                fields["connection"] = String(generation)
                self.diagnostics.record("connection_path", fields: fields)
            }
        }
        connection.viabilityUpdateHandler = { [weak self, weak connection] viable in
            DispatchQueue.main.async {
                guard let self, connection === self.connection else { return }
                self.diagnostics.record("connection_viability", fields: [
                    "connection": String(generation),
                    "viable": viable ? "true" : "false",
                ])
            }
        }
        connection.betterPathUpdateHandler = { [weak self, weak connection] available in
            DispatchQueue.main.async {
                guard let self, connection === self.connection else { return }
                self.diagnostics.record("connection_better_path", fields: [
                    "available": available ? "true" : "false",
                    "connection": String(generation),
                ])
            }
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(
        _ connectionState: NWConnection.State,
        connection: NWConnection?,
        generation: Int
    ) {
        guard connection === self.connection else { return }
        let commonFields = [
            "connection": String(generation),
            "elapsed_ms": elapsedMilliseconds(since: connectionStartedAt),
        ]
        switch connectionState {
        case .ready:
            diagnostics.record(
                "connection_state",
                fields: commonFields.merging(["state": "ready"]) { _, new in new }
            )
            diagnostics.record("session_state", fields: ["state": "hello_preparing"])
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
            diagnostics.record("session_state", fields: ["state": "hello_sent"])
            receiveNext()
        case let .failed(error):
            diagnostics.record(
                "connection_state",
                fields: commonFields.merging([
                    "error": DiagnosticsLogger.networkErrorCode(error),
                    "state": "failed",
                ]) { _, new in new }
            )
            logger.error("Connection failed: \(String(describing: error), privacy: .public)")
            handleFailure("连接 Mac 失败，请确认两台设备在附近并重试")
        case .cancelled:
            diagnostics.record(
                "connection_state",
                fields: commonFields.merging(["state": "cancelled"]) { _, new in new }
            )
            if self.connection != nil {
                handleFailure("与 Mac 的连接已断开，请重新连接")
            }
        case .preparing:
            diagnostics.record(
                "connection_state",
                fields: commonFields.merging(["state": "preparing"]) { _, new in new }
            )
        case let .waiting(error):
            diagnostics.record(
                "connection_state",
                fields: commonFields.merging([
                    "error": DiagnosticsLogger.networkErrorCode(error),
                    "state": "waiting",
                ]) { _, new in new }
            )
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
                    var fields = [
                        "complete": isComplete ? "true" : "false",
                        "connection": String(self.connectionGeneration),
                        "data_bytes": String(data?.count ?? 0),
                    ]
                    if let error {
                        fields["error"] = DiagnosticsLogger.networkErrorCode(error)
                        self.logger.error("Receive failed: \(String(describing: error), privacy: .public)")
                    }
                    self.diagnostics.record("receive_terminal", fields: fields)
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
            diagnostics.record("session_state", fields: ["state": "server_key_received"])
            establishSession(with: message)
            return
        }
        guard message.type == "secure",
              let message = decrypt(message)
        else {
            diagnostics.record("session_state", fields: ["state": "message_rejected"])
            return
        }
        handleSecure(message)
    }

    private func establishSession(with message: RemoteWireMessage) {
        guard let privateKey,
              let encoded = message.publicKey,
              let data = Data(base64Encoded: encoded),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data),
              let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        else {
            diagnostics.record("session_state", fields: ["state": "key_agreement_failed"])
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
        diagnostics.record("session_state", fields: ["state": "awaiting_approval"])
        send(RemoteWireMessage(type: "pairingReady"))
    }

    private func handleSecure(_ message: RemoteWireMessage) {
        switch message.type {
        case "ready":
            macName = message.deviceName ?? macName
            buttonTitles = message.buttonTitles ?? [:]
            macAppVersion = message.appVersion
            lastConnectedAt = Date()
            state = .connected
            diagnostics.record("session_state", fields: ["state": "connected"])
        case "buttonTitles":
            buttonTitles = message.buttonTitles ?? [:]
            diagnostics.record("session_state", fields: ["state": "button_titles_received"])
        case "denied":
            diagnostics.record("session_state", fields: ["state": "denied"])
            handleFailure("Mac 拒绝了本次连接")
        case "error":
            endVoice()
            diagnostics.record("session_state", fields: ["state": "operation_error_received"])
            if let detail = message.detail {
                logger.error("Mac reported an operation error: \(detail, privacy: .public)")
            }
            state = .connectedWithError(Self.userFacingOperationError(message.detail))
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
                self.diagnostics.record("send_failed", fields: [
                    "connection": String(self.connectionGeneration),
                    "error": DiagnosticsLogger.networkErrorCode(error),
                    "message_type": message.type,
                ])
                self.logger.error("Send failed: \(String(describing: error), privacy: .public)")
                self.handleFailure("发送失败，请重新连接 Mac 后重试")
            }
        })
    }

    private func handleBrowserState(_ browserState: NWBrowser.State, generation: Int) {
        let commonFields = [
            "browser": String(generation),
            "elapsed_ms": elapsedMilliseconds(since: browserStartedAt),
            "mode": discoveryMode.rawValue,
            "peer_to_peer": discoveryMode.includesPeerToPeer ? "true" : "false",
        ]
        switch browserState {
        case .setup:
            diagnostics.record(
                "browser_state",
                fields: commonFields.merging(["state": "setup"]) { _, new in new }
            )
        case .ready:
            diagnostics.record(
                "browser_state",
                fields: commonFields.merging(["state": "ready"]) { _, new in new }
            )
            isNearbyNetworkReady = true
            if connection == nil {
                state = .searching
                macName = "正在查找 Mac"
                if let pendingEndpoint {
                    connect(to: pendingEndpoint)
                }
            }
        case let .waiting(error):
            diagnostics.record(
                "browser_state",
                fields: commonFields.merging([
                    "error": DiagnosticsLogger.networkErrorCode(error),
                    "state": "waiting",
                ]) { _, new in new }
            )
            discoveryRetryTask?.cancel()
            discoveryRetryTask = nil
            isNearbyNetworkReady = false
            logger.notice("Bonjour browser is waiting: \(String(describing: error), privacy: .public)")
            if connection == nil {
                state = .awaitingLocalNetworkPermission
                macName = "等待访问本地网络"
            }
        case let .failed(error):
            diagnostics.record(
                "browser_state",
                fields: commonFields.merging([
                    "error": DiagnosticsLogger.networkErrorCode(error),
                    "state": "failed",
                ]) { _, new in new }
            )
            discoveryRetryTask?.cancel()
            discoveryRetryTask = nil
            isNearbyNetworkReady = false
            logger.error("Bonjour browser failed: \(String(describing: error), privacy: .public)")
            diagnostics.record("browser_cancel_requested", fields: [
                "browser": String(generation),
                "reason": "failed",
            ])
            browser?.cancel()
            browser = nil
            browserStartedAt = nil
            if discoveryMode == .localNetwork {
                switchToPeerToPeer(reason: "local_browser_failed")
            } else {
                finishDiscoveryWithRecoveryGuidance(reason: "peer_browser_failed")
            }
        case .cancelled:
            diagnostics.record(
                "browser_state",
                fields: commonFields.merging(["state": "cancelled"]) { _, new in new }
            )
            isNearbyNetworkReady = false
        @unknown default:
            diagnostics.record(
                "browser_state",
                fields: commonFields.merging(["state": "unknown"]) { _, new in new }
            )
        }
    }

    private func handleBrowseResults(
        _ results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>,
        generation: Int
    ) {
        var added = 0
        var removed = 0
        var changed = 0
        var identical = 0
        var unknown = 0
        for change in changes {
            switch change {
            case .added:
                added += 1
            case .removed:
                removed += 1
            case .changed:
                changed += 1
            case .identical:
                identical += 1
            @unknown default:
                unknown += 1
            }
        }
        var endpointCounts: [String: Int] = [:]
        for result in results {
            endpointCounts[Self.endpointCategory(result.endpoint), default: 0] += 1
        }
        let endpointSummary = endpointCounts.keys.sorted().map {
            "\($0):\(endpointCounts[$0] ?? 0)"
        }.joined(separator: ",")
        let interfaces = results.flatMap(\.interfaces)
        var fields = DiagnosticsLogger.interfaceFields(interfaces)
        fields.merge([
            "added": String(added),
            "browser": String(generation),
            "changed": String(changed),
            "count": String(results.count),
            "elapsed_ms": elapsedMilliseconds(since: browserStartedAt),
            "endpoints": endpointSummary.isEmpty ? "none" : endpointSummary,
            "identical": String(identical),
            "mode": discoveryMode.rawValue,
            "peer_to_peer": discoveryMode.includesPeerToPeer ? "true" : "false",
            "removed": String(removed),
            "unknown": String(unknown),
        ]) { _, new in new }
        diagnostics.record("browser_results", fields: fields)
        guard let endpoint = results.first?.endpoint else {
            pendingEndpoint = nil
            return
        }
        hasDiscoveryResult = true
        discoveryRetryTask?.cancel()
        discoveryRetryTask = nil
        pendingEndpoint = endpoint
        if isNearbyNetworkReady {
            connect(to: endpoint)
        }
    }

    private func handleFailure(_ detail: String) {
        diagnostics.record("connection_failure", fields: [
            "connection": String(connectionGeneration),
            "elapsed_ms": elapsedMilliseconds(since: connectionStartedAt),
            "state": diagnosticStateName,
        ])
        discoveryRetryTask?.cancel()
        discoveryRetryTask = nil
        endVoice()
        if connection != nil {
            diagnostics.record("connection_cancel_requested", fields: [
                "connection": String(connectionGeneration),
                "reason": "failure",
            ])
        }
        connection?.cancel()
        connection = nil
        connectionStartedAt = nil
        privateKey = nil
        sessionKey = nil
        pairingCode = nil
        buttonTitles = [:]
        macAppVersion = nil
        pendingEndpoint = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        state = .unavailable(detail)
        macName = "未找到可用的 Mac"
    }

    private func scheduleDiscoveryRetry() {
        discoveryRetryTask?.cancel()
        guard let step = Self.nextDiscoveryStep(
            mode: discoveryMode,
            attempt: discoveryRetryAttempt,
            state: state,
            hasResult: hasDiscoveryResult
        ) else {
            diagnostics.record("discovery_retry_exhausted", fields: [
                "attempt": String(discoveryRetryAttempt),
                "browser": String(browserGeneration),
                "mode": discoveryMode.rawValue,
                "state": diagnosticStateName,
            ])
            return
        }
        let scheduledGeneration = browserGeneration
        let scheduledMode = discoveryMode
        diagnostics.record("discovery_step_scheduled", fields: [
            "action": Self.discoveryActionName(step.action),
            "attempt": String(discoveryRetryAttempt + 1),
            "browser": String(browserGeneration),
            "delay_ms": String(Int(step.delaySeconds * 1_000)),
            "mode": discoveryMode.rawValue,
        ])
        discoveryRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(step.delaySeconds))
            guard let self, !Task.isCancelled,
                  connection == nil,
                  state == .searching,
                  browserGeneration == scheduledGeneration,
                  discoveryMode == scheduledMode,
                  !hasDiscoveryResult
            else { return }
            performDiscoveryAction(step.action)
        }
    }

    private func performDiscoveryAction(_ action: DiscoveryAction) {
        diagnostics.record("discovery_step", fields: [
            "action": Self.discoveryActionName(action),
            "attempt": String(discoveryRetryAttempt),
            "browser": String(browserGeneration),
            "elapsed_ms": elapsedMilliseconds(since: browserStartedAt),
            "mode": discoveryMode.rawValue,
        ])
        switch action {
        case .switchToPeerToPeer:
            switchToPeerToPeer(reason: "local_no_results")
        case .retryPeerToPeer:
            discoveryRetryAttempt += 1
            rebuildBrowser(reason: "peer_retry")
        case .showRecoveryGuidance:
            finishDiscoveryWithRecoveryGuidance(reason: "all_modes_no_results")
        }
    }

    private func switchToPeerToPeer(reason: String) {
        diagnostics.record("discovery_mode_changed", fields: [
            "from": discoveryMode.rawValue,
            "reason": reason,
            "to": DiscoveryMode.peerToPeer.rawValue,
        ])
        discoveryMode = .peerToPeer
        discoveryRetryAttempt = 0
        hasDiscoveryResult = false
        rebuildBrowser(reason: reason)
    }

    private func rebuildBrowser(reason: String) {
        diagnostics.record("browser_cancel_requested", fields: [
            "browser": String(browserGeneration),
            "reason": reason,
        ])
        browser?.cancel()
        browser = nil
        browserStartedAt = nil
        isNearbyNetworkReady = false
        pendingEndpoint = nil
        startBrowser()
    }

    private func finishDiscoveryWithRecoveryGuidance(reason: String) {
        diagnostics.record("discovery_failed", fields: [
            "attempt": String(discoveryRetryAttempt),
            "browser": String(browserGeneration),
            "mode": discoveryMode.rawValue,
            "reason": reason,
        ])
        diagnostics.record("browser_cancel_requested", fields: [
            "browser": String(browserGeneration),
            "reason": "discovery_failed",
        ])
        discoveryRetryTask?.cancel()
        discoveryRetryTask = nil
        browser?.cancel()
        browser = nil
        browserStartedAt = nil
        isNearbyNetworkReady = false
        pendingEndpoint = nil
        state = .unavailable(Self.discoveryRecoveryGuidance)
        macName = "未找到可用的 Mac"
    }

    private func resetDiscoveryStrategy() {
        discoveryMode = Self.discoveryModeForFreshStart()
        discoveryRetryAttempt = 0
        hasDiscoveryResult = false
    }

    nonisolated static func discoveryModeForFreshStart() -> DiscoveryMode {
        .localNetwork
    }

    nonisolated static func nextDiscoveryStep(
        mode: DiscoveryMode,
        attempt: Int,
        state: State,
        hasResult: Bool
    ) -> ScheduledDiscoveryStep? {
        guard case .searching = state, !hasResult else { return nil }
        switch (mode, attempt) {
        case (.localNetwork, 0):
            return ScheduledDiscoveryStep(delaySeconds: 3, action: .switchToPeerToPeer)
        case (.peerToPeer, 0):
            return ScheduledDiscoveryStep(delaySeconds: 2, action: .retryPeerToPeer)
        case (.peerToPeer, 1):
            return ScheduledDiscoveryStep(delaySeconds: 5, action: .retryPeerToPeer)
        case (.peerToPeer, 2):
            return ScheduledDiscoveryStep(delaySeconds: 5, action: .showRecoveryGuidance)
        default:
            return nil
        }
    }

    nonisolated static let discoveryRecoveryGuidance =
        "iPhone 的附近设备发现暂时异常。请关闭并重新打开 Wi-Fi；仍无法连接时，请重启 iPhone。"

    nonisolated static func discoveryActionName(_ action: DiscoveryAction) -> String {
        switch action {
        case .switchToPeerToPeer: return "switch_to_peer_to_peer"
        case .retryPeerToPeer: return "retry_peer_to_peer"
        case .showRecoveryGuidance: return "show_recovery_guidance"
        }
    }

    private func startNetworkPathMonitoring() {
        diagnostics.record("network_path_monitor", fields: ["state": "started"])
        let diagnostics = diagnostics
        networkPathMonitor.pathUpdateHandler = { path in
            diagnostics.record(
                "network_path",
                fields: DiagnosticsLogger.networkPathFields(path)
            )
        }
        networkPathMonitor.start(queue: queue)
    }

    private func elapsedMilliseconds(since start: Date?) -> String {
        guard let start else { return "unknown" }
        return String(max(0, Int(Date().timeIntervalSince(start) * 1_000)))
    }

    private var diagnosticStateName: String {
        switch state {
        case .searching: return "searching"
        case .awaitingLocalNetworkPermission: return "awaiting_local_network"
        case .connecting: return "connecting"
        case .awaitingApproval: return "awaiting_approval"
        case .connected: return "connected"
        case .connectedWithError: return "connected_with_error"
        case .unavailable: return "unavailable"
        }
    }

    nonisolated static func endpointCategory(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service: return "service"
        case .hostPort: return "host_port"
        case .unix: return "unix"
        case .url: return "url"
        case .opaque: return "opaque"
        @unknown default: return "unknown"
        }
    }

    nonisolated static func microphonePermissionName(
        _ permission: AVAudioApplication.recordPermission
    ) -> String {
        switch permission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    nonisolated static func userFacingOperationError(_ detail: String?) -> String {
        switch detail {
        case "Mac 需要辅助功能权限，或该按键当前不可用。":
            return "请在 Mac 的“系统设置 > 隐私与安全性 > 辅助功能”中允许无线麦，或检查该按键配置"
        case "Mac 的语音输出当前不可用。":
            return "Mac 的语音输出当前不可用，请检查辅助功能权限和虚拟麦克风后重试"
        default:
            return "Mac 暂时无法执行这个操作，请稍后重试"
        }
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

    nonisolated static func pairingCode(for key: SymmetricKey) -> String {
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

extension RemoteCommand {
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
