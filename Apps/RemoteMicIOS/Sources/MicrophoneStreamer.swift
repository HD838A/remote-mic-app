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
    var onSamples: (([Int16]) -> Void)?

    @MainActor
    func start() async throws {
        guard !isRunning else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw StreamError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setActive(true)

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

        input.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndPublish(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            converterLock.withLock {
                self.converter = nil
            }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    @MainActor
    func stop() {
        let hasConverter = converterLock.withLock { converter != nil }
        guard isRunning || hasConverter else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converterLock.withLock {
            converter = nil
        }
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
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
