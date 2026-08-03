import Foundation

final class WebRemoteRelayClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    typealias ApprovalHandler = (String, String, @escaping (Bool) -> Void) -> Void

    private let queue = DispatchQueue(label: "RemoteMic.webRemote", qos: .userInitiated)
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "RemoteMic.webRemote.urlSession"
        return queue
    }()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var relayURL: URL?
    private var macName = "Mac"
    private var appVersion: String?
    private var buttonTitles: [String: String] = [:]
    private var joinURL: URL?
    private var pairingCode: String?
    private var pendingApproval = false
    private var isVoiceActive = false
    private var stopped = true

    var onStateChange: ((WebRemoteSessionState) -> Void)?
    var onApprovalRequested: ApprovalHandler?
    var onApprovalCancelled: (() -> Void)?
    var onCommand: ((RemoteButton, @escaping (Bool) -> Void) -> Void)?
    var onVoiceStart: ((@escaping (Bool) -> Void) -> Void)?
    var onVoiceStop: (() -> Void)?
    var onAudio: (([Int16]) -> Void)?

    func start(
        relayURL: URL,
        macName: String,
        appVersion: String?,
        buttonTitles: [String: String]
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            stopOnQueue(notify: false)
            self.relayURL = relayURL
            self.macName = macName
            self.appVersion = appVersion
            self.buttonTitles = buttonTitles
            stopped = false
            publish(.connecting)

            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: delegateQueue
            )
            self.session = session
            let task = session.webSocketTask(with: relayURL)
            self.task = task
            task.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if !stopped {
                send(WebRemoteWireMessage(type: "sessionClose", reason: "Mac 已断开网页版"))
            }
            stopOnQueue(notify: true)
        }
    }

    func updateButtonTitles(_ titles: [String: String]) {
        queue.async { [weak self] in
            guard let self else { return }
            buttonTitles = titles
            guard !stopped else { return }
            send(WebRemoteWireMessage(type: "buttonTitles", buttonTitles: titles))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        queue.async { [weak self, weak webSocketTask] in
            guard let self,
                  !stopped,
                  webSocketTask === task
            else { return }
            send(WebRemoteWireMessage(
                type: "sessionCreate",
                macName: macName,
                appVersion: appVersion,
                buttonTitles: buttonTitles
            ))
            receiveNext()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async { [weak self, weak webSocketTask] in
            guard let self, webSocketTask === task else { return }
            failOnQueue("网页版连接已关闭")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil else { return }
        queue.async { [weak self, weak task] in
            guard let self, task === self.task else { return }
            failOnQueue("无法连接网页版服务，请检查网络后重试")
        }
    }

    private func receiveNext() {
        guard let task, !stopped else { return }
        task.receive { [weak self, weak task] result in
            guard let self else { return }
            queue.async {
                guard !self.stopped, task === self.task else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
                    self.receiveNext()
                case .failure:
                    self.failOnQueue("网页版连接中断，请重新连接")
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(value):
            guard let data = value.data(using: .utf8),
                  let message = try? JSONDecoder().decode(WebRemoteWireMessage.self, from: data),
                  message.protocolVersion == WebRemoteWireMessage.currentProtocolVersion
            else { return }
            handle(message)
        case let .data(data):
            guard isVoiceActive,
                  let frame = WebRemoteAudioFrame.decode(data)
            else { return }
            onAudio?(frame.samples)
        @unknown default:
            break
        }
    }

    private func handle(_ message: WebRemoteWireMessage) {
        switch message.type {
        case "sessionCreated":
            guard let rawJoinURL = message.joinURL,
                  let joinURL = URL(string: rawJoinURL),
                  let pairingCode = message.pairingCode
            else {
                failOnQueue("网页版服务返回了无效会话")
                return
            }
            self.joinURL = joinURL
            self.pairingCode = pairingCode
            let expiresAt = message.expiresAt.flatMap(Self.dateFormatter.date(from:))
            publish(.waitingForPhone(
                joinURL: joinURL,
                pairingCode: pairingCode,
                expiresAt: expiresAt
            ))
        case "sessionPendingApproval":
            guard let joinURL,
                  let pairingCode = message.pairingCode ?? self.pairingCode,
                  let deviceName = message.deviceName
            else { return }
            pendingApproval = true
            publish(.awaitingApproval(
                joinURL: joinURL,
                pairingCode: pairingCode,
                deviceName: deviceName
            ))
            onApprovalRequested?(deviceName, pairingCode) { [weak self] allowed in
                self?.queue.async {
                    guard let self, self.pendingApproval, !self.stopped else { return }
                    self.pendingApproval = false
                    self.send(WebRemoteWireMessage(type: allowed ? "sessionApprove" : "sessionDeny"))
                    if !allowed {
                        self.failOnQueue("已拒绝本次网页连接")
                    }
                }
            }
        case "sessionReady":
            let deviceName = message.deviceName ?? "手机浏览器"
            publish(.connected(deviceName: deviceName))
        case "command":
            guard let rawCommand = message.command,
                  let button = RemoteButton(rawValue: rawCommand)
            else {
                sendOperationError("invalid_command", "网页发送了不支持的按键")
                return
            }
            onCommand?(button) { [weak self] succeeded in
                guard !succeeded else { return }
                self?.queue.async {
                    self?.sendOperationError(
                        "command_unavailable",
                        "Mac 需要辅助功能权限，或该按键当前不可用"
                    )
                }
            }
        case "voiceStart":
            guard !isVoiceActive, let onVoiceStart else {
                sendOperationError("voice_unavailable", "Mac 的语音输出当前不可用")
                return
            }
            onVoiceStart { [weak self] succeeded in
                self?.queue.async {
                    guard let self, !self.stopped else { return }
                    if succeeded {
                        self.isVoiceActive = true
                        self.send(WebRemoteWireMessage(type: "voiceReady"))
                    } else {
                        self.sendOperationError("voice_unavailable", "Mac 的语音输出当前不可用")
                    }
                }
            }
        case "voiceStop":
            stopVoiceIfNeeded()
        case "heartbeat":
            send(WebRemoteWireMessage(
                type: "heartbeat",
                timestamp: Date().timeIntervalSince1970 * 1_000
            ))
        case "error":
            if message.recoverable == true {
                if isVoiceActive { stopVoiceIfNeeded() }
            } else {
                failOnQueue(message.detail ?? "网页版会话发生错误")
            }
        case "sessionClose":
            failOnQueue(message.reason ?? "网页版会话已结束")
        default:
            break
        }
    }

    private func sendOperationError(_ code: String, _ detail: String) {
        send(WebRemoteWireMessage(
            type: "error",
            code: code,
            detail: detail,
            recoverable: true
        ))
    }

    private func send(_ message: WebRemoteWireMessage) {
        guard let task,
              !stopped,
              let data = try? JSONEncoder().encode(message),
              let value = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(value)) { [weak self, weak task] error in
            guard error != nil else { return }
            self?.queue.async {
                guard let self, task === self.task else { return }
                self.failOnQueue("网页版消息发送失败")
            }
        }
    }

    private func stopVoiceIfNeeded() {
        guard isVoiceActive else { return }
        isVoiceActive = false
        onVoiceStop?()
    }

    private func failOnQueue(_ detail: String) {
        guard !stopped else { return }
        stopVoiceIfNeeded()
        if pendingApproval {
            pendingApproval = false
            onApprovalCancelled?()
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        stopped = true
        publish(.failed(detail))
    }

    private func stopOnQueue(notify: Bool) {
        stopVoiceIfNeeded()
        if pendingApproval {
            pendingApproval = false
            onApprovalCancelled?()
        }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        relayURL = nil
        joinURL = nil
        pairingCode = nil
        stopped = true
        if notify { publish(.disabled) }
    }

    private func publish(_ state: WebRemoteSessionState) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
