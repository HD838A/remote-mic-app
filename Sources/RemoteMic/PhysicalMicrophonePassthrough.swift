import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum PhysicalMicrophonePassthroughState: Equatable {
    case disabled
    case permissionRequired
    case deviceUnavailable
    case running(inputName: String, outputName: String)
    case failed
}

/// Captures a user-selected physical input and plays it into the selected virtual microphone.
///
/// Capture and playback intentionally use separate audio engines. A single AUHAL instance cannot
/// bind its input and output sides to different CoreAudio devices reliably. The capture tap makes
/// a private copy of every buffer before scheduling it on the virtual-device player.
final class PhysicalMicrophonePassthrough {
    private let stateLock = NSLock()
    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation: UInt64 = 0

    private(set) var state: PhysicalMicrophonePassthroughState = .disabled

    @discardableResult
    func configure(inputUID: String, outputUID: String) -> Bool {
        stop(logResult: false)
        AppLogger.shared.write("MIC PASSTHROUGH phase=requested")

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            state = .permissionRequired
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=failed result=permission_required"
            )
            return false
        }

        let inputs = CoreAudioDeviceCatalog.inputDevices()
        let outputs = CoreAudioDeviceCatalog.outputDevices()
        guard let input = inputs.first(where: { $0.uid == inputUID }),
              let output = outputs.first(where: { $0.uid == outputUID }),
              input.uid != output.uid
        else {
            state = .deviceUnavailable
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=failed result=device_unavailable " +
                    "input_selected=\(!inputUID.isEmpty) output_selected=\(!outputUID.isEmpty)"
            )
            return false
        }

        let playbackEngine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        playbackEngine.attach(player)

        let captureEngine = AVAudioEngine()
        let inputNode = captureEngine.inputNode
        guard let inputUnit = inputNode.audioUnit,
              let outputUnit = playbackEngine.outputNode.audioUnit
        else {
            state = .failed
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=failed result=audio_unit_unavailable"
            )
            return false
        }

        var inputDeviceID = input.id
        let inputResult = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &inputDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard inputResult == noErr else {
            state = .failed
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=failed result=bind_input " +
                    AppLogger.errorFields(domain: "os_status", code: Int(inputResult))
            )
            return false
        }

        var outputDeviceID = output.id
        let outputResult = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &outputDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard outputResult == noErr else {
            state = .failed
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=failed result=bind_output " +
                    AppLogger.errorFields(domain: "os_status", code: Int(outputResult))
            )
            return false
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            state = .failed
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=failed result=invalid_input_format"
            )
            return false
        }
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: inputFormat)

        stateLock.lock()
        generation &+= 1
        let activeGeneration = generation
        stateLock.unlock()

        inputNode.installTap(
            onBus: 0,
            bufferSize: 512,
            format: inputFormat
        ) { [weak self, weak player] buffer, _ in
            guard let self, let player,
                  self.isCurrentGeneration(activeGeneration),
                  let copiedBuffer = Self.copy(buffer)
            else { return }
            player.scheduleBuffer(copiedBuffer)
        }

        do {
            playbackEngine.prepare()
            try playbackEngine.start()
            player.play()
            captureEngine.prepare()
            try captureEngine.start()
            self.captureEngine = captureEngine
            self.playbackEngine = playbackEngine
            self.player = player
            state = .running(inputName: input.name, outputName: output.name)
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=completed result=running " +
                    "input={\(CoreAudioDeviceCatalog.deviceDiagnostic(input))} " +
                    "output={\(CoreAudioDeviceCatalog.deviceDiagnostic(output))}"
            )
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            player.stop()
            playbackEngine.stop()
            captureEngine.stop()
            state = .failed
            AppLogger.shared.write(
                "MIC PASSTHROUGH phase=failed result=start_failed " +
                    AppLogger.errorFields(error)
            )
            return false
        }
    }

    func stop(logResult: Bool = true) {
        stateLock.lock()
        generation &+= 1
        stateLock.unlock()
        if captureEngine != nil {
            captureEngine?.inputNode.removeTap(onBus: 0)
        }
        captureEngine?.stop()
        player?.stop()
        playbackEngine?.stop()
        captureEngine = nil
        playbackEngine = nil
        player = nil
        state = .disabled
        if logResult {
            AppLogger.shared.write("MIC PASSTHROUGH phase=completed result=stopped")
        }
    }

    private func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == candidate
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  byteCount <= Int(destinationBuffers[index].mDataByteSize)
            else { return nil }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }
}
