import Foundation
import Testing
@testable import RemoteMic

@Suite("Core voice input journeys")
struct CoreVoiceInputJourneyTests {
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
            drainAudio: { $0() },
            onFailure: { failure, _ in failures.append(failure) }
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
            drainAudio: { drains.append($0) },
            onFailure: { _, _ in }
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
            drainAudio: { $0() },
            onFailure: { _, _ in }
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
            drainAudio: { $0() },
            onFailure: { _, _ in }
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
