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

/// Captures only the selected input. PCM follows the existing 16 kHz voice path.
final class MacMicrophoneCapture {
    private let queue = DispatchQueue(label: "SayAll.macMicrophone.capture", qos: .userInitiated)
    private let ingressLock = NSLock()
    private var acceptingBuffers = false
    private var engine: AVAudioEngine?
    private var converter: MacMicrophonePCMConverter?
    private var deliver: (([Int16]) -> Void)?
    private var fail: (() -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var operationID: UInt64 = 0
    private var startedAt: TimeInterval = 0
    private var receivedSamples = 0
    private var conversionFailed = false

    func start(
        input: AudioDeviceInfo,
        operationID: UInt64,
        onSamples: @escaping ([Int16]) -> Void,
        onFailure: @escaping () -> Void,
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
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            guard let unit = inputNode.audioUnit else {
                DispatchQueue.main.async { completion(.capture) }; return
            }
            var deviceID = input.id
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
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
            guard RemoteMicTryInstallInputTap(inputNode, format, { [weak self] buffer, _ in
                self?.accept(buffer)
            }) else {
                self.engine = nil
                self.converter = nil
                DispatchQueue.main.async { completion(.capture) }
                return
            }
            do {
                engine.prepare()
                try engine.start()
                var boundDevice = AudioDeviceID(0)
                var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
                guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &boundDevice, &boundSize) == noErr,
                    boundDevice == input.id else { throw MacMicrophoneFailure.inputUnavailable }
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
                ) { [weak self, weak engine] _ in
                    guard let self, let engine else { return }
                    self.handleConfigurationChange(
                        engine: engine,
                        input: input,
                        onFailure: onFailure
                    )
                }
                AppLogger.shared.write(
                    "MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=started " +
                        "result=engine_running input_device_id=\(input.id) " +
                        "sample_rate_hz=\(Int(format.sampleRate)) channels=\(format.channelCount)"
                )
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

    private func handleConfigurationChange(
        engine: AVAudioEngine,
        input: AudioDeviceInfo,
        onFailure: @escaping () -> Void
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
            DispatchQueue.main.async { onFailure() }
        }
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
        let fail = self.fail
        AppLogger.shared.write("MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=failed reason=conversion_or_copy")
        DispatchQueue.main.async { fail?() }
    }

    func stop(completion: @escaping () -> Void) {
        ingressLock.lock()
        acceptingBuffers = false
        // This barrier follows every buffer admitted by the tap, including main-queue delivery.
        queue.async { [self] in
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
            AppLogger.shared.write("MAC MICROPHONE CAPTURE operation_id=\(operationID) phase=completed result=released samples=\(receivedSamples) conversion_failed=\(conversionFailed)")
            engine = nil
            converter = nil
            deliver = nil
            fail = nil
            DispatchQueue.main.async(execute: completion)
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
