import Foundation
#if canImport(AppleRemotePacketLogger) && canImport(AppleRemoteHCIProtocol)
import AppleRemotePacketLogger

/// Shares the existing bounded, in-memory system diagnostic client. Configuration
/// is owned by the signed root helper; no PacketLogger process or capture file.
final class G9N9NHCIController {
    var onControl: ((ChromecastRemoteControlEvent) -> Void)?
    var onLearningChange: ((String?) -> Void)?
    var onLearningFeedback: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var requestIdentityRead: (() -> Void)?
    private let queue = DispatchQueue(label: "sayall.g9n9n.hci", qos: .userInitiated)
    private var configuration: AppleRemoteHCIConfigurationClient?
    private var client: AppleRemotePacketLoggerClient?
    private var generation = 0
    private var enabled = false
    private var failed = false
    private var sequence = 0
    private var parser = G9N9NHCIParser()
    private var pressed = Set<ChromecastRemoteControl>()
    private var reportedBinding = false
    private var reportedPackets = false
    private var reportedAttributes = Set<UInt16>()
    private var reportedConsumerUsages = Set<UInt16>()
    private var reportedConsumerReportLengths = Set<Int>()
    private var identityWindow = G9N9NHCIIdentityWindow()
    private var identitySerial: Data?
    private var learningTimeout: DispatchWorkItem?
    private var learningAttempt = 0
    private let defaults: UserDefaults
    private static let learnedKey = "g9n9n.hci.learned.v1"
    private var streamReady = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.learnedKey) as? [String: String] ?? [:]
        if stored.count <= 32 {
            var mappings: [UInt16: ChromecastRemoteControl] = [:]
            for (key, value) in stored {
                if let usage = UInt16(key), let control = ChromecastRemoteControl(rawValue: value) {
                    mappings[usage] = control
                }
            }
            parser.setLearnedMappings(mappings)
        }
    }

    func learn(_ control: ChromecastRemoteControl) {
        cancelLearning()
        guard enabled, streamReady else { onLearningFeedback?("not_ready"); return }
        cancelControls(reason: "learning")
        learningAttempt += 1
        let learnAttempt = learningAttempt
        let attempt = generation
        onLearningChange?(control.rawValue)
        onLearningFeedback?("started")
        queue.async { [weak self] in
            guard let self else { return }
            let accepted = self.parser.beginLearning(control)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == attempt, self.learningAttempt == learnAttempt else { return }
                guard accepted else { self.cancelLearning(); self.onLearningFeedback?("not_ready"); return }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.learningAttempt == learnAttempt else { return }
                    self.queue.async { [weak self] in
                        guard let self else { return }
                        let reports = self.parser.learningReports
                        self.parser.cancelLearning()
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.learningAttempt == learnAttempt else { return }
                            self.onLearningChange?(nil)
                            self.onLearningFeedback?(reports == 0 ? "no_report" : "incomplete")
                            AppLogger.shared.write("G9N9N HCI LEARNING result=timed_out reports=\(reports)")
                        }
                    }
                }
                self.learningTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            }
        }
    }

    func cancelLearning() {
        learningAttempt += 1
        learningTimeout?.cancel()
        learningTimeout = nil
        onLearningChange?(nil)
        queue.async { [weak self] in self?.parser.cancelLearning() }
    }

    func start() {
        guard !enabled, !failed else { return }
        enabled = true
        streamReady = false
        generation += 1
        let attempt = generation
        let configuration = AppleRemoteHCIConfigurationClient()
        self.configuration = configuration
        status("preparing")
        configuration.prepare(buttonsOnly: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == attempt else {
                    configuration.stop()
                    return
                }
                guard result == .ready else {
                    self.failed = true
                    self.status("helper_unavailable")
                    self.stop()
                    return
                }
                self.beginPackets(attempt: attempt, configuration: configuration)
            }
        }
    }

    func retry() {
        failed = false
        start()
    }

    func stop() {
        guard enabled || configuration != nil else { return }
        cancelLearning()
        enabled = false
        streamReady = false
        identityWindow.invalidate()
        identitySerial = nil
        generation += 1
        cancelControls(reason: "capture_stopped")
        let oldClient = client
        let oldConfiguration = configuration
        client = nil
        configuration = nil
        // stop() enqueues on the same queue. Release the configuration lease only
        // after packet callbacks and the authorization session have been stopped.
        oldClient?.stop()
        queue.async { [weak self] in
            self?.parser.reset()
            self?.reportedBinding = false
            self?.reportedPackets = false
            self?.reportedAttributes.removeAll()
            self?.reportedConsumerUsages.removeAll()
            self?.reportedConsumerReportLengths.removeAll()
            DispatchQueue.main.async { oldConfiguration?.stop() }
        }
    }

    func identify(serial: Data) {
        guard !identityWindow.hasIdentity || identitySerial != serial else { return }
        identitySerial = serial
        let identityAttempt = identityWindow.begin()
        let attempt = generation
        queue.async { [weak self] in
            self?.parser.identify(serial: serial)
            self?.reportedBinding = false
            self?.reportedConsumerUsages.removeAll()
            self?.reportedConsumerReportLengths.removeAll()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.generation == attempt,
                      self.identityWindow.accepts(identityAttempt) else { return }
                self.requestIdentityRead?()
                if self.streamReady {
                    self.scheduleIdentityCheck(attempt: attempt, identityAttempt: identityAttempt, remaining: 5)
                }
            }
        }
    }

    func disconnected() {
        cancelLearning()
        identitySerial = nil
        identityWindow.invalidate()
        cancelControls(reason: "remote_disconnected")
        queue.async { [weak self] in
            self?.parser.reset()
            self?.reportedBinding = false
            self?.reportedAttributes.removeAll()
            self?.reportedConsumerUsages.removeAll()
            self?.reportedConsumerReportLengths.removeAll()
        }
    }

    private func beginPackets(attempt: Int, configuration: AppleRemoteHCIConfigurationClient) {
        let client = AppleRemotePacketLoggerClient(
            stateQueue: queue, callbackQueue: .main,
            allowsPacketAsAuthorization: true,
            requiresPreparedAuthorizationRule: true,
            sealsAfterServerAcceptance: true,
            sealAuthorizationRight: { configuration.sealAuthorizationRight(completion: $0) },
            onPacket: { [weak self] blob in
                guard let self else { return }
                let receivedAt = ProcessInfo.processInfo.systemUptime
                let receivedWall = Date().timeIntervalSince1970
                if !self.reportedPackets {
                    self.reportedPackets = true
                    AppLogger.shared.write("G9N9N HCI PACKET phase=first_received")
                }
                let wasBound = self.parser.isBound
                let edges = self.parser.consume(blob)
                let captureAge = G9N9NHCIParser.packetCaptureUnixTime(blob).map { receivedWall - $0 }
                let counts = (left: self.parser.leftReportCount, right: self.parser.rightReportCount,
                    release: self.parser.releaseReportCount, oneByte: self.parser.oneByteReportCount)
                if wasBound && !self.parser.isBound {
                    self.reportedConsumerUsages.removeAll()
                    self.reportedConsumerReportLengths.removeAll()
                }
                let learnedKey = self.parser.takeLearnedKey()
                let learnedMappings = learnedKey == nil ? nil : self.parser.learnedMappings
                for (attribute, bytes) in self.parser.observedNotifications
                    where self.reportedAttributes.insert(attribute).inserted {
                    AppLogger.shared.write("G9N9N HCI NOTIFICATION phase=first_received attribute=\(attribute) bytes=\(bytes)")
                }
                for bytes in self.parser.observedConsumerReportLengths
                    where self.reportedConsumerReportLengths.insert(bytes).inserted {
                    AppLogger.shared.write("G9N9N HCI INPUT phase=first_shape bytes=\(bytes)")
                }
                for usage in self.parser.observedConsumerUsages
                    where self.reportedConsumerUsages.insert(usage).inserted {
                    let mapped = self.parser.learnedMappings[usage] ?? G9N9NHCIParser.consumerControl(usage)
                    let value = String(format: "0x%04X", usage)
                    AppLogger.shared.write("G9N9N HCI INPUT phase=first_candidate usage=\(value) meaning=\(mapped?.rawValue ?? (usage == 0 ? "release" : "unmapped")) action_delivery=unobserved")
                }
                let bound = self.parser.isBound
                let conflict = self.parser.identityConflict
                let firstBinding = bound && !self.reportedBinding
                if firstBinding { self.reportedBinding = true }
                // Unrelated Bluetooth traffic stays on the bounded parser queue;
                // never enqueue a main-thread callback for every captured packet.
                guard conflict || firstBinding || !edges.isEmpty || learnedKey != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled, self.generation == attempt else { return }
                    if conflict {
                        self.failed = true
                        self.status("identity_conflict")
                        self.stop()
                        return
                    }
                    if firstBinding { self.status("identity_verified") }
                    if let learnedKey, let learnedMappings {
                        self.learningAttempt += 1
                        self.learningTimeout?.cancel()
                        self.learningTimeout = nil
                        self.defaults.set(Dictionary(uniqueKeysWithValues: learnedMappings.map { (String($0.key), $0.value.rawValue) }), forKey: Self.learnedKey)
                        self.onLearningChange?(nil)
                        self.onLearningFeedback?("completed")
                        AppLogger.shared.write("G9N9N HCI LEARNING result=completed control=\(learnedKey.control.rawValue)")
                    }
                    for edge in edges {
                        self.deliver(edge, receivedAt: receivedAt, captureAge: captureAge, counts: counts)
                    }
                }
            },
            onAuthorizationProgress: { [weak self] progress in
                guard let self, self.enabled, self.generation == attempt else { return }
                AppLogger.shared.write("G9N9N HCI AUTH phase=\(progress.rawValue)")
                if progress == .submitted {
                    self.status("waiting_for_stream")
                    // Give a quiet Bluetooth session one target-only ATT read;
                    // it can produce the first authenticated live-stream packet.
                    self.requestIdentityRead?()
                }
            },
            onEvent: { [weak self] event in
                guard let self, self.enabled, self.generation == attempt else { return }
                switch event {
                case .requiresAuthorization:
                    self.status("authorization_required")
                    self.client?.requestAuthorization()
                case .authorized:
                    self.streamReady = true
                    self.status("waiting_for_identity")
                    self.requestIdentityRead?()
                    let identityAttempt = self.identityWindow.generation
                    self.scheduleIdentityCheck(attempt: attempt, identityAttempt: identityAttempt, remaining: 5)
                case .profileRequired:
                    self.failed = true
                    self.status("profile_required")
                    self.stop()
                case .failed(let failure):
                    AppLogger.shared.write("G9N9N HCI phase=failed reason=\(failure.diagnosticCode)")
                    self.failed = true
                    self.status("capture_failed")
                    self.stop()
                case .stopped:
                    self.cancelControls(reason: "capture_stopped")
                case .connecting, .authorizing: break
                }
            }
        )
        self.client = client
        client.start()
    }

    private func scheduleIdentityCheck(attempt: Int, identityAttempt: Int, remaining: Int) {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.parser.isBound else { return }
            let packets = self.parser.packetsSeen
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.generation == attempt,
                      self.identityWindow.accepts(identityAttempt) else { return }
                // No identity was supplied yet: the peripheral is still asleep
                // or reconnecting after tracing reload. A future identify() starts
                // its own bounded verification window.
                guard remaining > 0 else {
                    AppLogger.shared.write("G9N9N HCI phase=failed reason=identity_timeout packets=\(packets)")
                    self.failed = true
                    self.status("capture_failed")
                    self.stop()
                    return
                }
                self.requestIdentityRead?()
                self.scheduleIdentityCheck(attempt: attempt, identityAttempt: identityAttempt, remaining: remaining - 1)
            }
        }
    }

    private func deliver(_ edge: G9N9NHCIParser.Edge, receivedAt: TimeInterval,
        captureAge: TimeInterval?, counts: (left: Int, right: Int, release: Int, oneByte: Int)) {
        let handlerStartedAt = ProcessInfo.processInfo.systemUptime
        if edge.down { pressed.insert(edge.control) } else { pressed.remove(edge.control) }
        sequence += 1
        onControl?(.init(control: edge.control,
                         phase: edge.cancelled ? .cancelled : (edge.down ? .began : .ended),
                         sequence: sequence, cancellationReason: edge.cancelled ? "hci_disconnected" : nil))
        if edge.down {
            let finishedAt = ProcessInfo.processInfo.systemUptime
            let captureMS = captureAge.map { String(Int(($0 * 1000).rounded())) } ?? "unavailable"
            AppLogger.shared.write("G9N9N HCI CONTROL phase=began control=\(edge.control.rawValue) " +
                "capture_to_receive_ms=\(captureMS) " +
                "queue_wait_ms=\(Int((max(0, handlerStartedAt - receivedAt) * 1000).rounded())) " +
                "handler_ms=\(Int((max(0, finishedAt - handlerStartedAt) * 1000).rounded())) " +
                "raw_left=\(counts.left) raw_right=\(counts.right) raw_release=\(counts.release) one_byte=\(counts.oneByte)")
        }
    }

    private func cancelControls(reason: String) {
        for control in pressed.sorted(by: { $0.rawValue < $1.rawValue }) {
            sequence += 1
            onControl?(.init(control: control, phase: .cancelled, sequence: sequence, cancellationReason: reason))
        }
        pressed.removeAll()
    }

    private func status(_ value: String) {
        AppLogger.shared.write("G9N9N HCI state=\(value)")
        onStatus?(value)
    }
}

#else
/// The standalone source self-test has no SwiftPM diagnostic modules.
final class G9N9NHCIController {
    var onControl: ((ChromecastRemoteControlEvent) -> Void)?
    var onLearningChange: ((String?) -> Void)?
    var onLearningFeedback: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var requestIdentityRead: (() -> Void)?
    func start() { onStatus?("helper_unavailable") }
    func retry() { start() }
    func learn(_ control: ChromecastRemoteControl) { onLearningFeedback?("not_ready") }
    func cancelLearning() { onLearningChange?(nil) }
    func stop() {}
    func identify(serial: Data) {}
    func disconnected() {}
}
#endif
