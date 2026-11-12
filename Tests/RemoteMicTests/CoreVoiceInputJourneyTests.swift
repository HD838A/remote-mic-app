import Foundation
import Testing
@testable import RemoteMic

@Suite("Core voice input journeys")
struct CoreVoiceInputJourneyTests {
    @Test func firstVoiceAfterIdleReleasePreservesConfigurationBufferAndTail() {
        var idleRelease = VirtualAudioIdleReleaseState()
        idleRelease.release()
        let backgroundActivation = idleRelease.requestActivation(hasDemand: false)
        #expect(!backgroundActivation)

        let scheduler = VoiceInputManualScheduler()
        var snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.previous",
            role: "AXWindow",
            editable: false
        )
        var functionKeyEvents: [Bool] = []
        var playedAudio: [[Int16]] = []
        var drains: [() -> Void] = []
        let coordinator = VoiceInputDestinationCoordinator(
            schedule: scheduler.schedule,
            snapshot: { snapshot }
        )
        let controller = VoiceFnTapSessionController(
            schedule: scheduler.schedule,
            destinationReadiness: coordinator.waitUntilReady,
            setFunctionKeyPressed: {
                functionKeyEvents.append($0)
                return true
            },
            enqueueAudio: { playedAudio.append($0) },
            drainAudio: { _, completion in drains.append(completion) },
            onFailure: { _ in Issue.record("First voice after idle release failed") }
        )
        controller.setEnabled(true)
        coordinator.beginTargetSwitch(intent: .application(bundleIdentifier: "com.example.target"))

        // STREAM_START 先启动语音；出口异步重建期间保留首包和松键前的尾包。
        let voiceActivation = idleRelease.requestActivation(hasDemand: true)
        #expect(voiceActivation)
        #expect(controller.startVoice())
        var configurationAudio = CommandVoiceActivationAudioBuffer()
        configurationAudio.begin()
        let bufferedFirstPacket = configurationAudio.appendIfWaiting([11, 12])
        let bufferedTailPacket = configurationAudio.appendIfWaiting([21, 22])
        #expect(bufferedFirstPacket)
        #expect(bufferedTailPacket)
        #expect(functionKeyEvents.isEmpty)

        // 配置完成后先重放所有 PCM，再处理先到的 STREAM_STOP。
        let bufferedAudio = configurationAudio.drain()
        #expect(controller.receive(bufferedAudio))
        #expect(controller.stopVoice())
        snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.target")
        scheduler.advance(by: 0.05)
        scheduler.advance(by: 0.12)
        #expect(functionKeyEvents == [true, false])
        #expect(playedAudio == [[11, 12, 21, 22]])
        #expect(drains.count == 1)
        drains.removeFirst()()
        scheduler.advance(by: 0.12)
        #expect(functionKeyEvents == [true, false, true, false])
        #expect(controller.phase == .idle)
        #expect(!idleRelease.isReleased)
    }

    @Test func firstVoiceDoesNotPostFnBeforeDelayedTargetIsReady() {
        let scheduler = VoiceInputManualScheduler()
        var snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.previous",
            role: "AXWindow",
            editable: false
        )
        var functionKeyEvents: [Bool] = []
        var failures: [VoiceFnTapFailure] = []
        var enqueuedAudio: [[Int16]] = []
        let coordinator = VoiceInputDestinationCoordinator(
            schedule: scheduler.schedule,
            snapshot: { snapshot }
        )
        let controller = VoiceFnTapSessionController(
            schedule: scheduler.schedule,
            destinationReadiness: coordinator.waitUntilReady,
            setFunctionKeyPressed: { pressed in
                functionKeyEvents.append(pressed)
                return true
            },
            enqueueAudio: { enqueuedAudio.append($0) },
            drainAudio: { _, completion in completion() },
            onFailure: { failures.append($0) }
        )
        controller.setEnabled(true)
        coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )

        #expect(controller.startVoice())
        #expect(controller.receive([1, 2, 3]))
        scheduler.advance(by: 3)

        #expect(functionKeyEvents.isEmpty)
        #expect(failures.isEmpty)
        #expect(enqueuedAudio.isEmpty)

        snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.target")
        scheduler.advance(by: 0.05)
        #expect(functionKeyEvents == [true])
        scheduler.advance(by: 0.12)
        #expect(functionKeyEvents == [true, false])
        #expect(enqueuedAudio == [[1, 2, 3]])
        #expect(failures.isEmpty)
    }

    @Test func voiceReleasedBeforeReadinessStillReplaysAndClosesOneFnPair() {
        let scheduler = VoiceInputManualScheduler()
        var snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.previous",
            role: "AXWindow",
            editable: false
        )
        var functionKeyEvents: [Bool] = []
        var enqueuedAudio: [[Int16]] = []
        var drains: [() -> Void] = []
        let coordinator = VoiceInputDestinationCoordinator(
            schedule: scheduler.schedule,
            snapshot: { snapshot }
        )
        let controller = VoiceFnTapSessionController(
            schedule: scheduler.schedule,
            destinationReadiness: coordinator.waitUntilReady,
            setFunctionKeyPressed: {
                functionKeyEvents.append($0)
                return true
            },
            enqueueAudio: { enqueuedAudio.append($0) },
            drainAudio: { _, completion in drains.append(completion) },
            onFailure: { _ in }
        )
        controller.setEnabled(true)
        coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )

        #expect(controller.startVoice())
        #expect(controller.receive([4, 5, 6]))
        #expect(controller.stopVoice())
        scheduler.advance(by: 1)
        #expect(functionKeyEvents.isEmpty)

        snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.target")
        scheduler.advance(by: 0.05)
        scheduler.advance(by: 0.12)
        #expect(functionKeyEvents == [true, false])
        #expect(enqueuedAudio == [[4, 5, 6]])
        #expect(drains.count == 1)

        drains.removeFirst()()
        scheduler.advance(by: 0.12)
        #expect(functionKeyEvents == [true, false, true, false])
        #expect(controller.phase == .idle)
    }

    @Test func readinessTimeoutDropsTheBufferedVoiceWithoutPostingFn() {
        let scheduler = VoiceInputManualScheduler()
        var functionKeyEvents: [Bool] = []
        var enqueuedAudio: [[Int16]] = []
        let coordinator = VoiceInputDestinationCoordinator(
            maximumWait: 1,
            schedule: scheduler.schedule,
            snapshot: {
                voiceInputTestSnapshot(
                    bundleIdentifier: "com.example.previous",
                    role: "AXWindow",
                    editable: false
                )
            }
        )
        let controller = VoiceFnTapSessionController(
            schedule: scheduler.schedule,
            destinationReadiness: coordinator.waitUntilReady,
            setFunctionKeyPressed: {
                functionKeyEvents.append($0)
                return true
            },
            enqueueAudio: { enqueuedAudio.append($0) },
            drainAudio: { _, completion in completion() },
            onFailure: { _ in }
        )
        controller.setEnabled(true)
        coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )

        #expect(controller.startVoice())
        #expect(controller.receive([7, 8, 9]))
        scheduler.advance(by: 1)

        #expect(functionKeyEvents.isEmpty)
        #expect(enqueuedAudio.isEmpty)
        #expect(controller.receive([10]))
        #expect(!controller.stopVoice())
        #expect(controller.phase == .idle)
    }

    @Test func fiveSecondsOfSixteenKilohertzPreRollIsPreserved() {
        let scheduler = VoiceInputManualScheduler()
        var snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.previous",
            role: "AXWindow",
            editable: false
        )
        var enqueuedAudio: [[Int16]] = []
        let coordinator = VoiceInputDestinationCoordinator(
            schedule: scheduler.schedule,
            snapshot: { snapshot }
        )
        let controller = VoiceFnTapSessionController(
            schedule: scheduler.schedule,
            destinationReadiness: coordinator.waitUntilReady,
            setFunctionKeyPressed: { _ in true },
            enqueueAudio: { enqueuedAudio.append($0) },
            drainAudio: { _, completion in completion() },
            onFailure: { _ in }
        )
        controller.setEnabled(true)
        coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )
        #expect(controller.startVoice())

        for marker in 0..<5 {
            #expect(controller.receive(Array(repeating: Int16(marker), count: 16_000)))
        }
        snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.target")
        scheduler.advance(by: 0.05)
        scheduler.advance(by: 0.12)

        let replay = enqueuedAudio.first
        #expect(replay?.count == 80_000)
        #expect(replay?.prefix(16_000).allSatisfy { $0 == 0 } == true)
        #expect(replay?.suffix(16_000).allSatisfy { $0 == 4 } == true)
    }
}
