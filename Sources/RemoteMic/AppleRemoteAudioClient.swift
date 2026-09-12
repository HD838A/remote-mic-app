import Foundation
import Network
import AppleRemoteAudioCore
import AppleRemotePacketLogger

struct AppleRemoteAudioCaptureGenerationGate: Equatable {
    enum Phase: Equatable {
        case inactive
        case active
        case closing
    }

    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase = .inactive

    var isCapturing: Bool { phase != .inactive }

    mutating func begin() -> UInt64 {
        generation &+= 1
        phase = .active
        return generation
    }

    mutating func beginClosing() -> UInt64 {
        guard phase == .active else { return generation }
        phase = .closing
        return generation
    }

    mutating func resume() -> UInt64? {
        guard phase == .closing else { return nil }
        phase = .active
        return generation
    }

    mutating func stop() -> UInt64 {
        generation &+= 1
        phase = .inactive
        return generation
    }

    func accepts(_ callbackGeneration: UInt64) -> Bool {
        phase != .inactive && generation == callbackGeneration
    }
}

final class AppleRemoteAudioClient {
    private let helperURL: () -> URL?
    private let logger: (String) -> Void
    private var process: Process?
    private var outputPipe: Pipe?
    private var connection: NWConnection?
    private var outputBuffer = Data()
    private var inputBuffer = Data()
    private var token = UUID().uuidString
    private let packetQueue = DispatchQueue(
        label: "com.hd838a.RemoteMic.appleRemote.packetStream",
        qos: .userInitiated
    )
    private var hciConfigurationClient: AppleRemoteHCIConfigurationClient?
    private var packetLoggerClient: AppleRemotePacketLoggerClient?
    private var parser = AppleRemoteXPCVoiceParser()
    private var decoder: AppleRemoteOpusDecoder?
    private var helperReady = false
    private var packetStreamReady = false
    private var packetCapturing = false
    private var captureGenerationGate = AppleRemoteAudioCaptureGenerationGate()
    private var staleDeliveryBatchCount = 0
    private var staleDeliverySampleCount = 0
    private var staleDeliveryLogCount = 0
    private var isCapturing = false
    private var captureStopping = false
    private var captureStopCompletions: [() -> Void] = []
    private var captureStopSequence: UInt64 = 0
    private var captureStopRequestedAt: DispatchTime?
    private var captureStopAcknowledgedAt: DispatchTime?
    private var closingDecodedSampleCount = 0
    private var pendingMainDeliveryBatchCount = 0
    private var pendingMainDeliverySampleCount = 0
    private var captureTailQuietReached = false
    private var stopping = false
    private var rawPacketCount = 0
    private var opusPacketCount = 0
    private var decodedSampleCount = 0

    var onSamples: (([Int16]) -> Void)?
    var onStatus: ((String) -> Void)?

    init(
        helperURL: @escaping () -> URL? = {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SayAllAppleRemoteAudioCapture")
        },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.helperURL = helperURL
        self.logger = logger
    }

    deinit { stop() }

    func start() {
        guard process == nil else { return }
        stopping = false
        guard let helper = helperURL(), FileManager.default.isExecutableFile(atPath: helper.path) else {
            reportStatus("unavailable:helper_missing")
            logger("APPLE REMOTE AUDIO component=unavailable reason=helper_missing")
            return
        }
        token = UUID().uuidString
        let pipe = Pipe()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--port", "0", "--token", token]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.logger("APPLE REMOTE AUDIO helper=terminated status=\(process.terminationStatus)")
                self.connection?.cancel()
                self.connection = nil
                self.helperReady = false
                self.isCapturing = false
                self.forceCompleteCaptureStop(reason: "helper_terminated")
                self.process = nil
                self.reportStatus("unavailable:helper_terminated")
            }
        }
        do {
            try process.run()
        } catch {
            reportStatus("unavailable:helper_start_failed")
            logger("APPLE REMOTE AUDIO component=unavailable reason=helper_start_failed \(AppLogger.errorFields(error))")
            return
        }
        self.process = process
        self.outputPipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consumeHelperOutput(data)
        }
        logger("APPLE REMOTE AUDIO component=starting helper=present")
        preparePacketStream()
    }

    @discardableResult
    func beginCapture() -> Bool {
        guard process != nil else {
            reportStatus("unavailable:helper_not_running")
            return false
        }
        guard helperReady, packetStreamReady, let connection else {
            reportStatus(
                helperReady
                    ? "unavailable:packet_stream_not_ready"
                    : "unavailable:helper_not_ready"
            )
            return false
        }
        guard !isCapturing else { return false }
        guard let decoder = AppleRemoteOpusDecoder(sampleRate: 16_000) else {
            reportStatus("unavailable:opus_decoder_missing")
            return false
        }
        let captureGeneration = packetQueue.sync { () -> UInt64? in
            guard !captureStopping else { return nil }
            let previousStaleDelivery = (
                staleDeliveryBatchCount,
                staleDeliverySampleCount,
                staleDeliveryLogCount
            )
            if previousStaleDelivery.0 > 0 {
                logger(
                    "APPLE REMOTE AUDIO pcm=stale_summary " +
                        "batches=\(previousStaleDelivery.0) " +
                        "samples=\(previousStaleDelivery.1) " +
                        "logged=\(previousStaleDelivery.2)"
                )
            }
            staleDeliveryBatchCount = 0
            staleDeliverySampleCount = 0
            staleDeliveryLogCount = 0
            parser.reset()
            self.decoder = decoder
            packetCapturing = true
            rawPacketCount = 0
            opusPacketCount = 0
            decodedSampleCount = 0
            return captureGenerationGate.begin()
        }
        guard let captureGeneration else { return false }
        isCapturing = true
        connection.send(content: AppleRemoteAudioIPC.encode(.init(kind: .start)), completion: .contentProcessed { [weak self] error in
            if let error { self?.logger("APPLE REMOTE AUDIO start_send_failed \(AppLogger.errorFields(error))") }
        })
        logger(
            "APPLE REMOTE AUDIO capture=started source=apple_remote_microphone " +
                "generation=\(captureGeneration)"
        )
        return true
    }

    func stopCapture(completion: @escaping () -> Void = {}) {
        let stopRequest = packetQueue.sync { () -> (alreadyStopping: Bool, generation: UInt64?) in
            if captureStopping {
                captureStopCompletions.append(completion)
                return (true, nil)
            }
            guard captureGenerationGate.phase == .active else { return (false, nil) }
            captureStopping = true
            captureStopCompletions = [completion]
            captureStopRequestedAt = .now()
            captureStopAcknowledgedAt = nil
            closingDecodedSampleCount = 0
            captureTailQuietReached = false
            return (false, captureGenerationGate.beginClosing())
        }
        if stopRequest.alreadyStopping {
            return
        }
        guard let generation = stopRequest.generation else {
            completion()
            return
        }
        isCapturing = false
        connection?.send(
            content: AppleRemoteAudioIPC.encode(.init(kind: .stop)),
            completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.logger(
                    "APPLE REMOTE AUDIO capture_stop_send phase=failed " +
                        AppLogger.errorFields(error)
                )
            }
        )
        logger(
            "APPLE REMOTE AUDIO capture_stop phase=requested generation=\(generation)"
        )
        scheduleCaptureStopWatchdog(generation: generation)
    }

    func resumeCaptureIfStopping() -> Bool {
        guard helperReady, packetStreamReady, connection != nil else { return false }
        let resumed = packetQueue.sync { () -> (generation: UInt64, closingSamples: Int)? in
            guard captureStopping, let generation = captureGenerationGate.resume() else {
                return nil
            }
            let closingSamples = closingDecodedSampleCount
            captureStopping = false
            captureStopCompletions.removeAll()
            captureStopSequence &+= 1
            captureStopRequestedAt = nil
            captureStopAcknowledgedAt = nil
            closingDecodedSampleCount = 0
            captureTailQuietReached = false
            return (generation, closingSamples)
        }
        guard let resumed else { return false }
        isCapturing = true
        connection?.send(
            content: AppleRemoteAudioIPC.encode(.init(kind: .start)),
            completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                self?.logger(
                    "APPLE REMOTE AUDIO capture_resume_send phase=failed " +
                        AppLogger.errorFields(error)
                )
            }
        )
        logger(
            "APPLE REMOTE AUDIO capture_stop phase=cancelled result=resumed_by_new_press " +
                "generation=\(resumed.generation) closing_samples=\(resumed.closingSamples)"
        )
        return true
    }

    func stop() {
        stopping = true
        isCapturing = false
        forceCompleteCaptureStop(reason: "client_stop")
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        connection?.cancel()
        connection = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        helperReady = false
        packetStreamReady = false
        packetLoggerClient?.stop()
        packetLoggerClient = nil
        hciConfigurationClient?.stop()
        hciConfigurationClient = nil
    }

    private func consumeHelperOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeFirst(outputBuffer.distance(from: outputBuffer.startIndex, to: newline) + 1)
            guard let line = String(data: lineData, encoding: .utf8), line.hasPrefix("READY ") else { continue }
            let fields = line.split(separator: " ")
            guard fields.count == 2, let portValue = UInt16(fields[1]) else { continue }
            connect(port: portValue)
        }
    }

    private func connect(port: UInt16) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.helperReady = true
                self.reportStatus("ipc_ready")
                let hello = AppleRemoteAudioIPC.Frame(kind: .hello, payload: Data(self.token.utf8))
                connection.send(content: AppleRemoteAudioIPC.encode(hello), completion: .contentProcessed { error in
                    if let error { self.logger("APPLE REMOTE AUDIO hello_failed \(AppLogger.errorFields(error))") }
                })
                self.receive()
                self.logger("APPLE REMOTE AUDIO phase=ipc_ready result=connected")
            case .failed(let error):
                self.helperReady = false
                self.isCapturing = false
                self.forceCompleteCaptureStop(reason: "helper_connection_failed")
                self.reportStatus("unavailable:connection_failed")
                self.logger("APPLE REMOTE AUDIO connection_failed \(AppLogger.errorFields(error))")
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inputBuffer.append(data)
                for frame in AppleRemoteAudioIPC.decodeFrames(buffer: &self.inputBuffer) {
                    switch frame.kind {
                    case .pcm:
                        let samples = AppleRemoteAudioIPC.samples(from: frame)
                        if !samples.isEmpty {
                            let generation = self.packetQueue.sync {
                                let generation = self.captureGenerationGate.generation
                                self.pendingMainDeliveryBatchCount += 1
                                self.pendingMainDeliverySampleCount += samples.count
                                return generation
                            }
                            self.deliverSamples(samples, generation: generation)
                        }
                    case .status:
                        if let status = String(data: frame.payload, encoding: .utf8) {
                            if status == "stopped" {
                                self.isCapturing = false
                                self.packetQueue.async {
                                    guard self.captureStopping else { return }
                                    self.captureStopAcknowledgedAt = .now()
                                    self.scheduleCaptureTailSettlementOnQueue(
                                        reason: "helper_stopped"
                                    )
                                }
                            } else if status.hasPrefix("unavailable:") {
                                self.isCapturing = false
                                self.forceCompleteCaptureStop(reason: "helper_unavailable")
                            } else if status == "capturing" {
                                let captureIsActive = self.packetQueue.sync {
                                    self.captureGenerationGate.phase == .active
                                }
                                if captureIsActive {
                                    self.isCapturing = true
                                }
                            }
                            self.reportStatus(status)
                            self.logger("APPLE REMOTE AUDIO status=\(status)")
                        }
                    default:
                        break
                    }
                }
            }
            if let error { self.logger("APPLE REMOTE AUDIO receive_failed \(AppLogger.errorFields(error))") }
            if !isComplete && error == nil { self.receive() }
        }
    }

    private func preparePacketStream() {
        reportStatus("preparing_hci")
        logger("APPLE REMOTE AUDIO packet_stream phase=preparing_hci")
        let client = AppleRemoteHCIConfigurationClient()
        hciConfigurationClient = client
        client.prepare { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                switch result {
                case .ready:
                    self.startPacketLogger()
                case .failed(let reason):
                    let status = "unavailable:\(reason)"
                    self.reportStatus(status)
                    self.logger(
                        "APPLE REMOTE AUDIO packet_stream phase=failed reason=\(reason)"
                    )
                }
            }
        }
    }

    private func startPacketLogger() {
        guard packetLoggerClient == nil else { return }
        let client = AppleRemotePacketLoggerClient(
            stateQueue: packetQueue,
            callbackQueue: .main,
            // The privileged HCI helper installs a strict, short-lived right
            // during its lease. On macOS builds where that right is already
            // accepted, BTPacketLogger sends packets without a RequiresAuth
            // marker; the first valid packet is the daemon's readiness proof.
            allowsPacketAsAuthorization: true,
            sealAuthorizationRight: { [weak self] completion in
                guard let self else {
                    completion(false)
                    return
                }
                self.hciConfigurationClient?.sealAuthorizationRight(completion: completion)
                    ?? completion(false)
            },
            onPacket: { [weak self] packet in
                self?.handlePacketInline(packet)
            },
            onEvent: { [weak self] event in
                self?.handlePacketStreamEvent(event)
            }
        )
        packetLoggerClient = client
        client.start()
    }

    private func handlePacketStreamEvent(
        _ event: AppleRemotePacketLoggerClient.Event
    ) {
        guard !stopping else { return }
        switch event {
        case .connecting:
            packetStreamReady = false
            reportStatus("starting")
            logger("APPLE REMOTE AUDIO packet_stream phase=connecting")
        case .requiresAuthorization:
            packetStreamReady = false
            reportStatus("authorizing")
            logger("APPLE REMOTE AUDIO packet_stream phase=authorization_requested")
            packetLoggerClient?.requestAuthorization()
        case .authorizing:
            reportStatus("authorizing")
            logger("APPLE REMOTE AUDIO packet_stream phase=authorizing")
        case .authorized:
            packetStreamReady = true
            reportStatus("ready")
            logger("APPLE REMOTE AUDIO packet_stream phase=ready result=authorized")
        case .profileRequired:
            failPacketStream(reason: "hci_voice_tracing_disabled")
        case .stopped:
            failPacketStream(reason: "packet_stream_stopped")
        case .failed(let failure):
            failPacketStream(reason: "packet_stream_\(failure.diagnosticCode)")
        }
    }

    private func failPacketStream(reason: String) {
        packetStreamReady = false
        forceCompleteCaptureStop(reason: reason)
        reportStatus("unavailable:\(reason)")
        logger("APPLE REMOTE AUDIO packet_stream phase=failed reason=\(reason)")
    }

    private func handlePacketInline(_ packet: Data) {
        guard packetCapturing, let decoder else { return }
        rawPacketCount += 1
        for opusPacket in parser.ingestXPCPacket(packet) {
            opusPacketCount += 1
            guard let samples = decoder.decode(opusPacket), !samples.isEmpty else {
                continue
            }
            decodedSampleCount += samples.count
            if captureStopping {
                closingDecodedSampleCount += samples.count
                captureTailQuietReached = false
                scheduleCaptureTailSettlementOnQueue(reason: "tail_pcm_quiet")
            }
            pendingMainDeliveryBatchCount += 1
            pendingMainDeliverySampleCount += samples.count
            deliverSamples(samples, generation: captureGenerationGate.generation)
        }
    }

    private func scheduleCaptureTailSettlementOnQueue(reason: String) {
        guard captureStopping, captureStopAcknowledgedAt != nil else { return }
        captureStopSequence &+= 1
        let sequence = captureStopSequence
        packetQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self,
                  self.captureStopping,
                  self.captureStopSequence == sequence
            else { return }
            if self.pendingMainDeliveryBatchCount > 0 {
                self.captureTailQuietReached = true
                self.logger(
                    "APPLE REMOTE AUDIO capture_stop phase=waiting " +
                        "reason=main_delivery_pending " +
                        "pending_batches=\(self.pendingMainDeliveryBatchCount) " +
                        "pending_samples=\(self.pendingMainDeliverySampleCount)"
                )
                return
            }
            self.completeCaptureStopOnQueue(reason: reason)
        }
    }

    private func scheduleCaptureStopWatchdog(generation: UInt64) {
        packetQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self,
                  self.captureStopping,
                  self.captureGenerationGate.generation == generation
            else { return }
            self.logger(
                "APPLE REMOTE AUDIO capture_stop phase=forced reason=helper_ack_timeout " +
                    "generation=\(generation)"
            )
            self.completeCaptureStopOnQueue(reason: "helper_ack_timeout")
        }
    }

    private func completeCaptureStopOnQueue(reason: String) {
        guard captureStopping else { return }
        let requestMilliseconds = captureStopRequestedAt.map {
            Self.elapsedMilliseconds(since: $0)
        } ?? 0
        let acknowledgementMilliseconds = captureStopRequestedAt.flatMap { requested in
            captureStopAcknowledgedAt.map { acknowledged in
                Self.elapsedMilliseconds(from: requested, to: acknowledged)
            }
        }
        let completedNormally = captureStopAcknowledgedAt != nil
        let closingSamples = closingDecodedSampleCount
        let pendingMainDeliveryBatches = pendingMainDeliveryBatchCount
        let pendingMainDeliverySamples = pendingMainDeliverySampleCount
        stopPacketCaptureOnQueueAndLog(reason: reason)
        captureStopping = false
        captureStopRequestedAt = nil
        captureStopAcknowledgedAt = nil
        closingDecodedSampleCount = 0
        captureTailQuietReached = false
        pendingMainDeliveryBatchCount = 0
        pendingMainDeliverySampleCount = 0
        let completions = captureStopCompletions
        captureStopCompletions.removeAll()
        logger(
            "APPLE REMOTE AUDIO capture_stop phase=completed result=tail_settled " +
                "completion=\(completedNormally ? "normal" : "forced") " +
                "reason=\(reason) elapsed_ms=\(requestMilliseconds) " +
                "ack_ms=\(acknowledgementMilliseconds.map(String.init) ?? "unknown") " +
                "closing_samples=\(closingSamples) " +
                "pending_main_delivery_batches=\(pendingMainDeliveryBatches) " +
                "pending_main_delivery_samples=\(pendingMainDeliverySamples)"
        )
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            completions.forEach { $0() }
        }
    }

    private func forceCompleteCaptureStop(reason: String) {
        packetQueue.async { [weak self] in
            guard let self,
                  self.packetCapturing || self.decoder != nil ||
                    self.captureGenerationGate.isCapturing || self.captureStopping
            else { return }
            if !self.captureStopping {
                self.captureStopping = true
            }
            self.captureStopAcknowledgedAt = nil
            self.completeCaptureStopOnQueue(reason: reason)
        }
    }

    private static func elapsedMilliseconds(since start: DispatchTime) -> Int {
        elapsedMilliseconds(from: start, to: .now())
    }

    private static func elapsedMilliseconds(from start: DispatchTime, to end: DispatchTime) -> Int {
        guard end.uptimeNanoseconds >= start.uptimeNanoseconds else { return 0 }
        return Int((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    private func stopPacketCaptureAndLog(reason: String) {
        let statistics = packetQueue.sync { stopPacketCaptureOnQueue() }
        logPacketCaptureStop(statistics, reason: reason)
    }

    private func stopPacketCaptureOnQueueAndLog(reason: String) {
        logPacketCaptureStop(stopPacketCaptureOnQueue(), reason: reason)
    }

    private func stopPacketCaptureOnQueue() -> (Bool, Int, Int, Int, UInt64) {
        let wasCapturing = packetCapturing || decoder != nil || captureGenerationGate.isCapturing
        let snapshot = (
            wasCapturing,
            rawPacketCount,
            opusPacketCount,
            decodedSampleCount,
            captureGenerationGate.stop()
        )
        packetCapturing = false
        decoder = nil
        parser.reset()
        rawPacketCount = 0
        opusPacketCount = 0
        decodedSampleCount = 0
        return snapshot
    }

    private func logPacketCaptureStop(
        _ statistics: (Bool, Int, Int, Int, UInt64),
        reason: String
    ) {
        guard statistics.0 else { return }
        logger(
            "APPLE REMOTE AUDIO packet_stream phase=capture_stopped "
                + "reason=\(reason) raw_packets=\(statistics.1) "
                + "opus_packets=\(statistics.2) decoded_samples=\(statistics.3)"
                + " generation=\(statistics.4)"
        )
    }

    private func deliverSamples(_ samples: [Int16], generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let delivery = self.packetQueue.sync { () -> (accepted: Bool, completeStop: Bool) in
                let accepted = self.captureGenerationGate.accepts(generation)
                self.pendingMainDeliveryBatchCount = max(
                    0,
                    self.pendingMainDeliveryBatchCount - 1
                )
                self.pendingMainDeliverySampleCount = max(
                    0,
                    self.pendingMainDeliverySampleCount - samples.count
                )
                let completeStop = self.captureStopping &&
                    self.captureStopAcknowledgedAt != nil &&
                    self.captureTailQuietReached &&
                    self.pendingMainDeliveryBatchCount == 0
                return (accepted, completeStop)
            }
            guard delivery.accepted else {
                let shouldLog = self.packetQueue.sync { () -> Bool in
                    self.staleDeliveryBatchCount += 1
                    self.staleDeliverySampleCount += samples.count
                    guard self.staleDeliveryBatchCount == 1 ||
                            self.staleDeliveryBatchCount.isMultiple(of: 100)
                    else { return false }
                    self.staleDeliveryLogCount += 1
                    return true
                }
                if shouldLog {
                    let summary = self.packetQueue.sync {
                        (self.staleDeliveryBatchCount, self.staleDeliverySampleCount)
                    }
                    self.logger(
                        "APPLE REMOTE AUDIO pcm=ignored reason=stale_generation " +
                            "generation=\(generation) batches=\(summary.0) " +
                            "samples=\(summary.1)"
                    )
                }
                return
            }
            self.onSamples?(samples)
            if delivery.completeStop {
                self.packetQueue.async { [weak self] in
                    guard let self,
                          self.captureStopping,
                          self.captureTailQuietReached,
                          self.pendingMainDeliveryBatchCount == 0
                    else { return }
                    self.completeCaptureStopOnQueue(reason: "main_delivery_settled")
                }
            }
        }
    }

    private func reportStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }
}
