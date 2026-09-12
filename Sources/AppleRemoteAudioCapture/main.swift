import AppleRemoteAudioCore
import AppleRemotePacketLogger
import Foundation
import Network

enum AppleRemoteAudioCaptureMain {
    private static var server: CaptureServer?
    private static var packetLoggerProbe: AppleRemotePacketLoggerClient?
    private static var voiceController: AppleRemoteVoiceController?
    private static var audioProbeParser = AppleRemoteXPCVoiceParser()
    private static var audioProbeDecoder: AppleRemoteOpusDecoder?
    private static var audioProbeStarted = false
    private static var audioProbePackets = 0
    private static var audioProbeFrames = 0
    private static var audioProbeSamples = 0
    private static var audioProbePeak = 0
    private static var audioProbeRecordTypes = [Int](repeating: 0, count: 256)

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--packetlogger-probe") {
            runPacketLoggerProbe()
            dispatchMain()
        }
        if args.contains("--voice-command-probe") {
            runVoiceCommandProbe()
        }
        if let probeIndex = args.firstIndex(of: "--packetlogger-audio-probe") {
            let duration = probeIndex + 1 < args.count ? Double(args[probeIndex + 1]) ?? 8 : 8
            runPacketLoggerAudioProbe(duration: max(2, min(duration, 30)))
            dispatchMain()
        }
        guard let portIndex = args.firstIndex(of: "--port"), portIndex + 1 < args.count,
              let port = UInt16(args[portIndex + 1]),
              let tokenIndex = args.firstIndex(of: "--token"), tokenIndex + 1 < args.count
        else {
            fputs("usage: SayAllAppleRemoteAudioCapture --port 0 --token TOKEN\n", stderr)
            exit(2)
        }
        let captureServer = CaptureServer(requestedPort: port, token: String(args[tokenIndex + 1]))
        server = captureServer
        captureServer.start()
        dispatchMain()
    }

    private static func runPacketLoggerProbe() {
        let stateQueue = DispatchQueue(label: "SayAll.appleRemoteAudio.packetLoggerProbe")
        let client = AppleRemotePacketLoggerClient(
            stateQueue: stateQueue,
            callbackQueue: .main,
            onPacket: { _ in
                FileHandle.standardOutput.write(Data("PROBE_RESULT packet_received_without_prompt\n".utf8))
                exit(0)
            },
            onEvent: { event in
                switch event {
                case .connecting:
                    FileHandle.standardOutput.write(Data("PROBE_STATE connecting\n".utf8))
                case .requiresAuthorization:
                    FileHandle.standardOutput.write(Data("PROBE_RESULT requires_authorization\n".utf8))
                    exit(0)
                case .authorized:
                    FileHandle.standardOutput.write(Data("PROBE_RESULT authorized_without_prompt\n".utf8))
                    exit(0)
                case .profileRequired:
                    FileHandle.standardOutput.write(Data("PROBE_RESULT profile_required\n".utf8))
                    exit(3)
                case .authorizing:
                    FileHandle.standardOutput.write(Data("PROBE_RESULT unexpected_authorizing\n".utf8))
                    exit(4)
                case .stopped:
                    FileHandle.standardOutput.write(Data("PROBE_RESULT stopped\n".utf8))
                    exit(5)
                case .failed(let failure):
                    FileHandle.standardOutput.write(
                        Data("PROBE_RESULT failed reason=\(failure.diagnosticCode)\n".utf8)
                    )
                    exit(6)
                }
            }
        )
        packetLoggerProbe = client
        client.start()
    }

    private static func runVoiceCommandProbe() {
        guard let controller = AppleRemoteVoiceController() else {
            print("VOICE_COMMAND_PROBE failed reason=hid_manager_open_failed")
            exit(20)
        }
        let start = controller.setActive(true)
        usleep(100_000)
        let stop = controller.setActive(false)
        print("VOICE_COMMAND_PROBE start=\(start) stop=\(stop)")
        exit(start == .accepted && stop == .accepted ? 0 : 21)
    }

    private static func runPacketLoggerAudioProbe(duration: TimeInterval) {
        let stateQueue = DispatchQueue(label: "SayAll.appleRemoteAudio.packetLoggerAudioProbe")
        audioProbeParser = AppleRemoteXPCVoiceParser()
        audioProbeDecoder = AppleRemoteOpusDecoder(sampleRate: 16_000)
        audioProbeStarted = false
        audioProbePackets = 0
        audioProbeFrames = 0
        audioProbeSamples = 0
        audioProbePeak = 0
        audioProbeRecordTypes = [Int](repeating: 0, count: 256)
        guard audioProbeDecoder != nil else {
            FileHandle.standardOutput.write(Data("AUDIO_PROBE_RESULT failed reason=opus_decoder_missing\n".utf8))
            exit(10)
        }

        let client = AppleRemotePacketLoggerClient(
            stateQueue: stateQueue,
            callbackQueue: stateQueue,
            allowsPacketAsAuthorization: true,
            onPacket: { packet in
                audioProbePackets += 1
                if AppleRemotePacketLoggerRecord.isValid(packet) {
                    audioProbeRecordTypes[Int(packet[12])] += 1
                }
                for opusPacket in audioProbeParser.ingestXPCPacket(packet) {
                    audioProbeFrames += 1
                    guard let samples = audioProbeDecoder?.decode(opusPacket) else { continue }
                    audioProbeSamples += samples.count
                    for sample in samples {
                        audioProbePeak = max(audioProbePeak, abs(Int(sample)))
                    }
                }
            },
            onEvent: { event in
                switch event {
                case .connecting:
                    FileHandle.standardOutput.write(Data("AUDIO_PROBE_STATE connecting\n".utf8))
                case .requiresAuthorization:
                    FileHandle.standardOutput.write(Data("AUDIO_PROBE_STATE authorization_required\n".utf8))
                    packetLoggerProbe?.requestAuthorization()
                case .authorizing:
                    FileHandle.standardOutput.write(Data("AUDIO_PROBE_STATE authorizing\n".utf8))
                case .authorized:
                    guard !audioProbeStarted else { return }
                    audioProbeStarted = true
                    let controller = AppleRemoteVoiceController()
                    voiceController = controller
                    guard let controller else {
                        FileHandle.standardOutput.write(Data("AUDIO_PROBE_RESULT failed reason=hid_manager_open_failed\n".utf8))
                        exit(11)
                    }
                    let startResult = controller.setActive(true)
                    guard startResult == .accepted else {
                        FileHandle.standardOutput.write(Data("AUDIO_PROBE_RESULT failed reason=voice_start_\(startResult)\n".utf8))
                        exit(12)
                    }
                    FileHandle.standardOutput.write(
                        Data("AUDIO_PROBE_STATE recording duration_seconds=\(Int(duration))\n".utf8)
                    )
                    stateQueue.asyncAfter(deadline: .now() + duration) {
                        let stopResult = voiceController?.setActive(false)
                        let typeSummary = audioProbeRecordTypes.enumerated()
                            .filter { $0.element > 0 }
                            .map { String(format: "%02X:%d", $0.offset, $0.element) }
                            .joined(separator: ",")
                        let summary = "AUDIO_PROBE_RESULT completed "
                            + "packets=\(audioProbePackets) "
                            + "frames=\(audioProbeFrames) "
                            + "samples=\(audioProbeSamples) "
                            + "peak=\(audioProbePeak) "
                            + "xpc_blobs=\(audioProbeParser.statistics.xpcBlobsSeen) "
                            + "raw_acl=\(audioProbeParser.statistics.normalizedRawACLPackets) "
                            + "records=\(audioProbeParser.statistics.packetLoggerRecordsSeen) "
                            + "inbound_acl=\(audioProbeParser.statistics.inboundACLPacketsSeen) "
                            + "att_values=\(audioProbeParser.statistics.completedATTValues) "
                            + "voice_wrappers=\(audioProbeParser.statistics.validVoiceWrappers) "
                            + "streams_locked=\(audioProbeParser.statistics.streamsLocked) "
                            + "record_types=\(typeSummary.isEmpty ? "none" : typeSummary) "
                            + "stop=\(String(describing: stopResult))\n"
                        FileHandle.standardOutput.write(Data(summary.utf8))
                        exit(audioProbeFrames > 0 && audioProbeSamples > 0 && audioProbePeak > 0 ? 0 : 13)
                    }
                case .profileRequired:
                    FileHandle.standardOutput.write(Data("AUDIO_PROBE_RESULT failed reason=profile_required\n".utf8))
                    exit(14)
                case .failed(let failure):
                    FileHandle.standardOutput.write(
                        Data("AUDIO_PROBE_RESULT failed reason=\(failure.diagnosticCode)\n".utf8)
                    )
                    exit(15)
                case .stopped:
                    break
                }
            }
        )
        packetLoggerProbe = client
        client.start()
    }
}

AppleRemoteAudioCaptureMain.main()

private final class CaptureServer {
    private let requestedPort: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "SayAll.appleRemoteAudio.capture")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var commandBuffer = Data()
    private var voiceController: AppleRemoteVoiceController?
    private var capturing = false
    private var authorized = false
    private let packetStreamReady = true
    private let packetStreamStatus = "ready"

    init(requestedPort: UInt16, token: String) {
        self.requestedPort = requestedPort
        self.token = token
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    let line = Data("READY \(port.rawValue)\n".utf8)
                    FileHandle.standardOutput.write(line)
                    try? FileHandle.standardOutput.synchronize()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            fputs("listener failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        authorized = false
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.connection = nil }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.commandBuffer.append(data)
                for frame in AppleRemoteAudioIPC.decodeFrames(buffer: &self.commandBuffer) {
                    self.handle(frame)
                }
            }
            if isComplete || error != nil { self.stopCapture() } else { self.receive() }
        }
    }

    private func handle(_ frame: AppleRemoteAudioIPC.Frame) {
        switch frame.kind {
        case .hello:
            guard String(data: frame.payload, encoding: .utf8) == token else {
                sendStatus("unauthorized")
                connection?.cancel()
                return
            }
            authorized = true
            sendStatus(packetStreamStatus)
        case .start:
            guard authorized else { sendStatus("unauthorized"); return }
            startCapture()
        case .stop:
            guard authorized else { sendStatus("unauthorized"); return }
            stopCapture()
        case .status, .pcm:
            break
        }
    }

    private func startCapture() {
        guard !capturing else { return }
        guard packetStreamReady else {
            sendStatus(packetStreamStatus)
            return
        }
        guard let controller = AppleRemoteVoiceController() else {
            sendStatus("unavailable:remote_microphone_control")
            return
        }
        voiceController = controller
        capturing = true
        guard controller.setActive(true) == .accepted else {
            finishCapture(status: "unavailable:remote_microphone_start_failed")
            return
        }
        sendStatus("capturing")
    }

    private func stopCapture() {
        finishCapture(status: "stopped")
    }

    private func finishCapture(status: String) {
        guard capturing || voiceController != nil else { return }
        _ = voiceController?.setActive(false)
        capturing = false
        voiceController = nil
        sendStatus(status)
    }

    private func sendStatus(_ status: String) {
        connection?.send(
            content: AppleRemoteAudioIPC.encode(.init(kind: .status, payload: Data(status.utf8))),
            completion: .contentProcessed { _ in }
        )
    }

}
