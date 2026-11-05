import Foundation
#if canImport(AppleRemotePacketLogger) && canImport(AppleRemoteHCIProtocol)
import AppleRemotePacketLogger

/// Shares the existing bounded, in-memory system diagnostic client. Configuration
/// is owned by the signed root helper; no PacketLogger process or capture file.
final class G9N9NHCIController {
    var onControl: ((ChromecastRemoteControlEvent) -> Void)?
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

    func start() {
        guard !enabled, !failed else { return }
        enabled = true
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
        enabled = false
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
            DispatchQueue.main.async { oldConfiguration?.stop() }
        }
    }

    func identify(serial: Data) {
        queue.async { [weak self] in
            self?.parser.identify(serial: serial)
            self?.reportedBinding = false
            self?.reportedAttributes.removeAll()
            DispatchQueue.main.async { [weak self] in self?.requestIdentityRead?() }
        }
    }

    func disconnected() {
        cancelControls(reason: "remote_disconnected")
        queue.async { [weak self] in
            self?.parser.reset()
            self?.reportedBinding = false
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
                if !self.reportedPackets {
                    self.reportedPackets = true
                    AppLogger.shared.write("G9N9N HCI PACKET phase=first_received")
                }
                let edges = self.parser.consume(blob)
                for (attribute, bytes) in self.parser.observedNotifications
                    where self.reportedAttributes.insert(attribute).inserted {
                    AppLogger.shared.write("G9N9N HCI NOTIFICATION phase=first_received attribute=\(attribute) bytes=\(bytes)")
                }
                let bound = self.parser.isBound
                let conflict = self.parser.identityConflict
                let firstBinding = bound && !self.reportedBinding
                if firstBinding { self.reportedBinding = true }
                // Unrelated Bluetooth traffic stays on the bounded parser queue;
                // never enqueue a main-thread callback for every captured packet.
                guard conflict || firstBinding || !edges.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled, self.generation == attempt else { return }
                    if conflict {
                        self.failed = true
                        self.status("identity_conflict")
                        self.stop()
                        return
                    }
                    if firstBinding { self.status("identity_verified") }
                    for edge in edges { self.deliver(edge) }
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
                    self.status("waiting_for_identity")
                    self.requestIdentityRead?()
                    self.scheduleIdentityCheck(attempt: attempt, remaining: 5)
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

    private func scheduleIdentityCheck(attempt: Int, remaining: Int) {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.parser.isBound else { return }
            let packets = self.parser.packetsSeen
            DispatchQueue.main.async { [weak self] in
                guard let self, self.enabled, self.generation == attempt else { return }
                guard remaining > 0 else {
                    AppLogger.shared.write("G9N9N HCI phase=failed reason=identity_timeout packets=\(packets)")
                    self.failed = true
                    self.status("capture_failed")
                    self.stop()
                    return
                }
                self.requestIdentityRead?()
                self.scheduleIdentityCheck(attempt: attempt, remaining: remaining - 1)
            }
        }
    }

    private func deliver(_ edge: G9N9NHCIParser.Edge) {
        if edge.down { pressed.insert(edge.control) } else { pressed.remove(edge.control) }
        sequence += 1
        onControl?(.init(control: edge.control,
                         phase: edge.cancelled ? .cancelled : (edge.down ? .began : .ended),
                         sequence: sequence, cancellationReason: edge.cancelled ? "hci_disconnected" : nil))
        if edge.down { AppLogger.shared.write("G9N9N HCI CONTROL phase=began control=\(edge.control.rawValue)") }
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
    var onStatus: ((String) -> Void)?
    var requestIdentityRead: (() -> Void)?
    func start() { onStatus?("helper_unavailable") }
    func retry() { start() }
    func stop() {}
    func identify(serial: Data) {}
    func disconnected() {}
}
#endif
