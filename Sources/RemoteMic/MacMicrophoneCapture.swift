import AVFoundation
import AudioExceptionGuard
import AudioToolbox
import CoreAudio
import Foundation

enum MacMicrophoneConfigurationChangePolicy {
    static func shouldFail(
        selectedDeviceID: AudioDeviceID,
        currentDeviceID: AudioDeviceID?
    ) -> Bool {
        guard let currentDeviceID else { return false }
        return currentDeviceID != selectedDeviceID
    }
}

enum MacMicrophoneDefaultInputPolicy {
    enum Source: String, Equatable {
        case systemDefault = "system_default"
        case builtIn = "built_in"
    }

    struct Selection: Equatable {
        let device: AudioDeviceInfo
        let source: Source
    }

    /// Uses the system default only when it is one of the selectable physical inputs.
    static func select(
        available: [AudioDeviceInfo],
        systemDefault: AudioDeviceInfo?,
        builtInDeviceIDs: Set<AudioDeviceID>
    ) -> Selection? {
        if let systemDefault,
           let match = available.first(where: { $0.uid == systemDefault.uid }) {
            return Selection(device: match, source: .systemDefault)
        }
        if let builtIn = available.first(where: { builtInDeviceIDs.contains($0.id) }) {
            return Selection(device: builtIn, source: .builtIn)
        }
        return nil
    }
}

/// Captures only the selected input. PCM follows the existing 16 kHz voice path.
final class MacMicrophoneCapture {
    private let queue = DispatchQueue(label: "SayAll.macMicrophone.capture", qos: .userInitiated)
    private let ingressLock = NSLock()
    private var acceptingBuffers = false
    private var engine: AVAudioEngine?
    private var converter: MacMicrophonePCMConverter?
    private var captureSession: AVCaptureSession?
    private var captureOutput: AVCaptureAudioDataOutput?
    private var captureDelegate: MacMicrophoneAudioCaptureDelegate?
    private var deliver: (([Int16]) -> Void)?
    private var fail: ((MacMicrophoneFailure) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var firstPCMWatchdog: DispatchWorkItem?
    private var operationID: UInt64 = 0
    private var startedAt: TimeInterval = 0
    private var receivedSamples = 0
    private var conversionFailed = false

    func start(
        input: AudioDeviceInfo,
        operationID: UInt64,
        onSamples: @escaping ([Int16]) -> Void,
        onFailure: @escaping (MacMicrophoneFailure) -> Void,
        completion: @escaping (MacMicrophoneFailure?) -> Void
    ) {
        ingressLock.lock()
        acceptingBuffers = true
        queue.async { [self] in
            ingressLock.lock()
            let shouldStart = acceptingBuffers
            ingressLock.unlock()
            guard shouldStart else {
                DispatchQueue.main.async { completion(.interrupted) }
                return
            }
            self.operationID = operationID
            startedAt = ProcessInfo.processInfo.systemUptime
            receivedSamples = 0
            conversionFailed = false
            // Bluetooth routes can be recreated between catalog refresh and
            // capture start. Resolve the selected UID to the current device ID.
            let resolvedInput = CoreAudioDeviceCatalog.inputDevices().first(where: {
                $0.uid == input.uid
            }) ?? input
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                    "phase=device_resolved result=\(resolvedInput.id == input.id ? "same" : "refreshed") " +
                    "previous_device_id=\(input.id) current_device_id=\(resolvedInput.id)"
            )
            let transport = CoreAudioDeviceCatalog.transportType(for: resolvedInput.id)
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth ||
                transport == kAudioDeviceTransportTypeBluetoothLE
            if isBluetooth {
                startAVCapture(
                    input: resolvedInput,
                    operationID: operationID,
                    onSamples: onSamples,
                    onFailure: onFailure,
                    completion: completion
                )
                return
            }
            let engineBegin = ProcessInfo.processInfo.systemUptime
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let engineReadyMs = Self.ms(since: engineBegin)
            guard let unit = inputNode.audioUnit else {
                DispatchQueue.main.async { completion(.capture) }; return
            }
            var deviceID = resolvedInput.id
            let inputBindBegin = ProcessInfo.processInfo.systemUptime
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            let inputBindMs = Self.ms(since: inputBindBegin)
            let format = inputNode.outputFormat(forBus: 0)
            guard result == noErr, format.sampleRate > 0, format.channelCount > 0,
                  let converter = MacMicrophonePCMConverter(inputFormat: format)
            else {
                AppLogger.shared.write("MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=failed reason=format_or_binding code=\(result)")
                DispatchQueue.main.async { completion(.inputUnavailable) }; return
            }
            self.engine = engine
            self.converter = converter
            deliver = onSamples
            fail = onFailure
            let tapBegin = ProcessInfo.processInfo.systemUptime
            let tapInstalled = RemoteMicTryInstallInputTap(inputNode, format, { [weak self] buffer, _ in
                self?.accept(buffer)
            })
            let tapMs = Self.ms(since: tapBegin)
            guard tapInstalled else {
                self.engine = nil
                self.converter = nil
                DispatchQueue.main.async { completion(.capture) }
                return
            }
            do {
                let prepareBegin = ProcessInfo.processInfo.systemUptime
                engine.prepare()
                let prepareMs = Self.ms(since: prepareBegin)
                let startBegin = ProcessInfo.processInfo.systemUptime
                try engine.start()
                let startMs = Self.ms(since: startBegin)
                var boundDevice = AudioDeviceID(0)
                var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
                guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &boundDevice, &boundSize) == noErr,
                    boundDevice == resolvedInput.id else { throw MacMicrophoneFailure.inputUnavailable }
                let deviceStartBegin = ProcessInfo.processInfo.systemUptime
                let deviceStart = AudioDeviceStart(resolvedInput.id, nil)
                let deviceStartMs = Self.ms(since: deviceStartBegin)
                AppLogger.shared.write(
                    "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                        "phase=device_started result=\(deviceStart == noErr ? "started" : "failed") " +
                        "input_device_id=\(resolvedInput.id) code=\(deviceStart)"
                )
                AppLogger.shared.write(
                    "MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=startup_timing " +
                        "engine_ms=\(engineReadyMs) input_bind_ms=\(inputBindMs) tap_ms=\(tapMs) " +
                        "prepare_ms=\(prepareMs) start_ms=\(startMs) device_start_ms=\(deviceStartMs)"
                )
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
                ) { [weak self, weak engine] _ in
                    guard let self, let engine else { return }
                    self.handleConfigurationChange(
                        engine: engine,
                        input: resolvedInput,
                        onFailure: onFailure
                    )
                }
                AppLogger.shared.write(
                    "MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=started " +
                        "result=engine_running input_device_id=\(resolvedInput.id) " +
                        "sample_rate_hz=\(Int(format.sampleRate)) channels=\(format.channelCount)"
                )
                scheduleFirstPCMWatchdog(operationID: operationID)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                ingressLock.lock()
                acceptingBuffers = false
                ingressLock.unlock()
                inputNode.removeTap(onBus: 0)
                engine.stop()
                self.engine = nil
                self.converter = nil
                self.deliver = nil
                self.fail = nil
                AppLogger.shared.write("MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=failed reason=start_failed " + AppLogger.errorFields(error))
                DispatchQueue.main.async { completion(.capture) }
            }
        }
        ingressLock.unlock()
    }

    private func startAVCapture(
        input: AudioDeviceInfo,
        operationID: UInt64,
        onSamples: @escaping ([Int16]) -> Void,
        onFailure: @escaping (MacMicrophoneFailure) -> Void,
        completion: @escaping (MacMicrophoneFailure?) -> Void
    ) {
        let devices = AVCaptureDevice.devices(for: .audio)
        let captureDevice = devices.first(where: { $0.uniqueID == input.uid })
            ?? devices.first(where: { $0.localizedName == input.name })
        guard let captureDevice else {
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                    "phase=avcapture_failed reason=device_not_found"
            )
            DispatchQueue.main.async { completion(.inputUnavailable) }
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let deviceInput = try AVCaptureDeviceInput(device: captureDevice)
            guard session.canAddInput(deviceInput) else {
                session.commitConfiguration()
                AppLogger.shared.write(
                    "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                        "phase=avcapture_failed reason=input_not_added"
                )
                DispatchQueue.main.async { completion(.inputUnavailable) }
                return
            }
            session.addInput(deviceInput)
        } catch {
            session.commitConfiguration()
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                    "phase=avcapture_failed reason=input_error " + AppLogger.errorFields(error)
            )
            DispatchQueue.main.async { completion(.capture) }
            return
        }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                    "phase=avcapture_failed reason=output_not_added"
            )
            DispatchQueue.main.async { completion(.capture) }
            return
        }
        session.addOutput(output)
        let delegate = MacMicrophoneAudioCaptureDelegate(
            onSamples: { [weak self] samples in self?.acceptPCM(samples) },
            onFailure: { [weak self] in self?.reportAVCaptureFailure() }
        )
        output.setSampleBufferDelegate(delegate, queue: queue)
        session.commitConfiguration()
        captureSession = session
        captureOutput = output
        captureDelegate = delegate
        deliver = onSamples
        fail = onFailure
        let startBegin = ProcessInfo.processInfo.systemUptime
        session.startRunning()
        let startMs = Self.ms(since: startBegin)
        guard session.isRunning else {
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                    "phase=avcapture_failed reason=not_running elapsed_ms=\(startMs)"
            )
            output.setSampleBufferDelegate(nil, queue: nil)
            captureSession = nil
            captureOutput = nil
            captureDelegate = nil
            deliver = nil
            fail = nil
            DispatchQueue.main.async { completion(.capture) }
            return
        }
        AppLogger.shared.write(
            "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                "phase=avcapture_started input_device_id=\(input.id) elapsed_ms=\(startMs)"
        )
        scheduleFirstPCMWatchdog(operationID: operationID)
        DispatchQueue.main.async { completion(nil) }
    }

    private func scheduleFirstPCMWatchdog(operationID: UInt64) {
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.operationID == operationID else { return }
            self.ingressLock.lock()
            let accepting = self.acceptingBuffers
            self.ingressLock.unlock()
            guard accepting, self.engine != nil || self.captureSession != nil,
                  self.receivedSamples == 0 else { return }
            self.firstPCMWatchdog = nil
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(self.operationID) phase=failed reason=no_audio"
            )
            DispatchQueue.main.async { self.fail?(.noAudio) }
        }
        firstPCMWatchdog = watchdog
        queue.asyncAfter(deadline: .now() + 2, execute: watchdog)
    }

    private func acceptPCM(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        ingressLock.lock()
        let accepting = acceptingBuffers
        ingressLock.unlock()
        guard accepting else { return }
        queue.async { [self] in
            guard captureSession != nil || engine != nil else { return }
            if receivedSamples == 0 {
                firstPCMWatchdog?.cancel()
                firstPCMWatchdog = nil
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
                AppLogger.shared.write(
                    "MAC MICROPHONE CAPTURE operation_id=\(operationID) " +
                        "phase=first_pcm elapsed_ms=\(elapsed) samples=\(samples.count)"
                )
            }
            receivedSamples += samples.count
            let deliver = self.deliver
            DispatchQueue.main.async { deliver?(samples) }
        }
    }

    private func reportAVCaptureFailure() {
        AppLogger.shared.write(
            "MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=failed reason=sample_format"
        )
        DispatchQueue.main.async { self.fail?(.capture) }
    }

    static func int16Samples(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return [] }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?
                  .pointee else { return nil }
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mChannelsPerFrame == 1,
              asbd.mBitsPerChannel == 16,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              audioBufferList.mNumberBuffers == 1,
              let data = audioBufferList.mBuffers.mData else { return nil }
        let byteCount = Int(audioBufferList.mBuffers.mDataByteSize)
        let count = min(frames, byteCount / MemoryLayout<Int16>.size)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Int16.self),
            count: count
        ))
    }

    private func handleConfigurationChange(
        engine: AVAudioEngine,
        input: AudioDeviceInfo,
        onFailure: @escaping (MacMicrophoneFailure) -> Void
    ) {
        queue.async { [weak self, weak engine] in
            guard let self, let engine, self.engine === engine else { return }
            let currentDeviceID = Self.currentInputDeviceID(for: engine)
            let result: String
            let shouldFail = MacMicrophoneConfigurationChangePolicy.shouldFail(
                selectedDeviceID: input.id,
                currentDeviceID: currentDeviceID
            )
            result = shouldFail ? "failed" : "ignored"
            let currentDeviceDescription = currentDeviceID.map { String($0) } ?? "unknown"
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(self.operationID) " +
                    "phase=configuration_changed result=\(result) " +
                    "selected_device_id=\(input.id) " +
                    "current_device_id=\(currentDeviceDescription)"
            )
            guard shouldFail else { return }
            DispatchQueue.main.async { onFailure(.capture) }
        }
    }

    private static func ms(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    private static func currentInputDeviceID(for engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        ) == noErr else { return nil }
        return deviceID == kAudioObjectUnknown ? nil : deviceID
    }

    private func accept(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        // Serialize admission with stop. No admitted buffer can arrive after its barrier.
        ingressLock.lock()
        defer { ingressLock.unlock() }
        guard acceptingBuffers else { return }
        guard let copy = Self.copy(buffer) else {
            queue.async { [weak self] in self?.reportFailure() }
            return
        }
        queue.async { [self] in convert(copy) }
    }

    private func convert(_ input: AVAudioPCMBuffer?) {
        guard let converter else { return }
        do {
            try converter.convert(input) { samples in
                if receivedSamples == 0 {
                    firstPCMWatchdog?.cancel()
                    firstPCMWatchdog = nil
                    let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
                    AppLogger.shared.write("MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=first_pcm elapsed_ms=\(elapsed) samples=\(samples.count)")
                }
                receivedSamples += samples.count
                let deliver = self.deliver
                DispatchQueue.main.async { deliver?(samples) }
            }
        } catch { reportFailure() }
    }

    private func reportFailure() {
        guard !conversionFailed else { return }
        conversionFailed = true
        firstPCMWatchdog?.cancel()
        firstPCMWatchdog = nil
        let fail = self.fail
        AppLogger.shared.write("MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=failed reason=conversion_or_copy")
        DispatchQueue.main.async { fail?(.capture) }
    }

    func stop(completion: @escaping () -> Void) {
        ingressLock.lock()
        acceptingBuffers = false
        // This barrier follows every buffer admitted by the tap, including main-queue delivery.
        queue.async { [self] in
            firstPCMWatchdog?.cancel()
            firstPCMWatchdog = nil
            if let session = captureSession {
                captureOutput?.setSampleBufferDelegate(nil, queue: nil)
                session.stopRunning()
                captureSession = nil
                captureOutput = nil
                captureDelegate = nil
                let hadNoAudio = receivedSamples == 0 && !conversionFailed
                AppLogger.shared.write(
                    "MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=completed " +
                        "result=released samples=\(receivedSamples) conversion_failed=\(conversionFailed) " +
                        "completion=\(hadNoAudio ? "no_audio" : "normal")"
                )
                deliver = nil
                fail = nil
                DispatchQueue.main.async(execute: completion)
                return
            }
            guard engine != nil || converter != nil else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            if let observer = configurationObserver {
                NotificationCenter.default.removeObserver(observer)
                configurationObserver = nil
            }
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            convert(nil)
            let hadNoAudio = receivedSamples == 0 && !conversionFailed
            AppLogger.shared.write(
                "MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=completed " +
                    "result=released samples=\(receivedSamples) conversion_failed=\(conversionFailed) " +
                    "completion=\(hadNoAudio ? "no_audio" : "normal")"
            )
            engine = nil
            converter = nil
            deliver = nil
            self.fail = nil
            DispatchQueue.main.async {
                completion()
            }
        }
        ingressLock.unlock()
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for index in from.indices {
            guard let src = from[index].mData, let dst = to[index].mData,
                  from[index].mDataByteSize <= to[index].mDataByteSize else { return nil }
            memcpy(dst, src, Int(from[index].mDataByteSize))
        }
        return copy
    }
}

/// Stateful conversion is shared by live capture and format/tail regression tests.
private final class MacMicrophoneAudioCaptureDelegate: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onSamples: ([Int16]) -> Void
    private let onFailure: () -> Void

    init(onSamples: @escaping ([Int16]) -> Void, onFailure: @escaping () -> Void) {
        self.onSamples = onSamples
        self.onFailure = onFailure
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let samples = MacMicrophoneCapture.int16Samples(from: sampleBuffer) else {
            onFailure()
            return
        }
        onSamples(samples)
    }
}

final class MacMicrophonePCMConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var ended = false

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                  channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        self.converter = converter
        outputFormat = output
    }

    /// nil signals end-of-stream and emits the converter's remaining tail once.
    func convert(_ input: AVAudioPCMBuffer?, deliver: ([Int16]) -> Void) throws {
        guard !ended else { return }
        let capacity = input.map {
            AVAudioFrameCount(ceil(Double($0.frameLength) * 16_000 / $0.format.sampleRate)) + 512
        } ?? 512
        var supplied = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw MacMicrophoneFailure.capture
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if output.frameLength > 0, let values = output.int16ChannelData?[0] {
                deliver(Array(UnsafeBufferPointer(start: values, count: Int(output.frameLength))))
            }
            if status == .error || error != nil { throw error ?? MacMicrophoneFailure.capture as NSError }
            if status == .endOfStream { ended = true }
            if status != .haveData || output.frameLength == 0 { return }
        }
    }
}
