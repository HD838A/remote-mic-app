import AVFoundation
import Foundation

final class MicrophoneStreamer {
    enum StreamError: Error {
        case permissionDenied
        case formatUnavailable
    }

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private let converterLock = NSLock()
    private var converter: AVAudioConverter?
    private var isRunning = false
    private var tapInstalled = false
    var onSamples: (([Int16]) -> Void)?

    @MainActor
    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    @MainActor
    func prepareIfAuthorized() {
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try preparePipeline()
        } catch {
            resetPipeline()
        }
    }

    @MainActor
    func start() throws {
        guard !isRunning else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw StreamError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            try preparePipeline()
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            resetPipeline()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    @MainActor
    private func preparePipeline() throws {
        let hasConverter = converterLock.withLock { converter != nil }
        guard !tapInstalled || !hasConverter else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw StreamError.formatUnavailable
        }
        converterLock.withLock {
            self.converter = converter
        }

        input.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndPublish(buffer)
        }
        tapInstalled = true
        engine.prepare()
    }

    @MainActor
    private func resetPipeline() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
        converterLock.withLock {
            converter = nil
        }
        isRunning = false
    }

    private func convertAndPublish(_ inputBuffer: AVAudioPCMBuffer) {
        let samples: [Int16]? = converterLock.withLock {
            guard let converter else { return nil }
            let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
            let capacity = max(
                1,
                AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio))
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            ) else { return nil }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, status in
                guard !suppliedInput else {
                    status.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                status.pointee = .haveData
                return inputBuffer
            }
            guard status != .error,
                  conversionError == nil,
                  outputBuffer.frameLength > 0,
                  let channel = outputBuffer.int16ChannelData?[0]
            else { return nil }

            return Array(UnsafeBufferPointer(
                start: channel,
                count: Int(outputBuffer.frameLength)
            ))
        }
        if let samples {
            onSamples?(samples)
        }
    }
}
