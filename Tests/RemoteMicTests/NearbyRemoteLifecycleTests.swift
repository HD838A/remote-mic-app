import Foundation
import Testing
@testable import RemoteMic

@Suite("Nearby remote idle sleep lifecycle")
@MainActor
struct NearbyRemoteLifecycleTests {
    @Test func defaultDisabledStaysStoppedAcrossSleepAndWake() {
        let harness = Harness()
        harness.update(enabled: false)
        harness.event(.systemWillSleep, enabled: false)
        harness.event(.systemDidWake, enabled: false)
        #expect(harness.operations.isEmpty)
    }

    @Test func idleSleepStopsBothServicesAndWakeRestoresUserIntentOnce() {
        let harness = Harness()
        harness.update(enabled: true)
        harness.event(.systemWillSleep)
        harness.event(.systemWillSleep)
        #expect(harness.lifecycle.isSystemSleeping)
        #expect(harness.operations == ["start_phone", "start_watch", "stop_phone", "stop_watch"])
        harness.event(.systemDidWake)
        harness.event(.systemDidWake)
        #expect(!harness.lifecycle.isSystemSleeping)
        #expect(harness.operations == [
            "start_phone", "start_watch", "stop_phone", "stop_watch", "start_phone", "start_watch",
        ])
    }

    @Test func disablingWhileAsleepPreventsWakeRestart() {
        let harness = Harness()
        harness.update(enabled: true)
        harness.event(.systemWillSleep)
        harness.update(enabled: false)
        harness.event(.systemDidWake, enabled: false)
        #expect(harness.operations == ["start_phone", "start_watch", "stop_phone", "stop_watch"])
    }

    @Test func enablingWhileAsleepWaitsForSystemWake() {
        let harness = Harness()
        harness.event(.systemWillSleep, enabled: false)
        harness.update(enabled: true)
        #expect(harness.operations.isEmpty)
        harness.event(.systemDidWake)
        #expect(harness.operations == ["start_phone", "start_watch"])
    }

    @Test(arguments: [
        SystemAudioLifecycleEvent.screenDidSleep, .screenDidWake,
        .sessionDidResignActive, .sessionDidBecomeActive,
    ])
    func screenAndSessionEventsDoNotDisconnectNearbyServices(_ event: SystemAudioLifecycleEvent) {
        let harness = Harness()
        harness.update(enabled: true)
        harness.event(event)
        #expect(harness.operations == ["start_phone", "start_watch"])
        #expect(!harness.lifecycle.isSystemSleeping)
    }

    @Test func existingConnectionAndVoiceDrainKeepTheirGeneration() {
        let harness = Harness()
        harness.update(enabled: true)
        let generation = harness.lifecycle.generation
        harness.event(.systemWillSleep, keepAlive: true)
        harness.update(enabled: true, keepAlive: true)
        #expect(harness.lifecycle.acceptsEvents(generation: generation))
        #expect(harness.operations == ["start_phone", "start_watch"])
        // The last connection and its tail audio have both finished.
        harness.update(enabled: true, keepAlive: false)
        #expect(!harness.lifecycle.acceptsEvents(generation: generation))
        #expect(Array(harness.operations.suffix(2)) == ["stop_phone", "stop_watch"])
    }

    @Test func userDisableStopsEvenAnExistingSession() {
        let harness = Harness()
        harness.update(enabled: true)
        harness.event(.systemWillSleep, keepAlive: true)
        harness.update(enabled: false, keepAlive: true)
        #expect(Array(harness.operations.suffix(2)) == ["stop_phone", "stop_watch"])
    }

    @Test func staleConnectionStateCannotRestartAStoppedServiceDuringSleep() {
        let harness = Harness()
        harness.update(enabled: true)
        harness.event(.systemWillSleep)
        harness.update(enabled: true, keepAlive: true)
        #expect(harness.operations == ["start_phone", "start_watch", "stop_phone", "stop_watch"])
    }

    @Test func queuedEventsFromBeforeSleepAreRejectedAfterWake() async {
        let harness = Harness()
        harness.update(enabled: true)
        let generation = harness.lifecycle.generation
        var delivered = false
        var rejected = false
        harness.lifecycle.deliver(onIgnored: { rejected = true }) { delivered = true }
        harness.event(.systemWillSleep)
        harness.event(.systemDidWake)
        await drainMainQueue()
        #expect(!delivered)
        #expect(rejected)
        #expect(!harness.lifecycle.acceptsEvents(generation: generation))
        #expect(harness.logs.last?.contains("reason=stale_generation") == true)
    }

    @Test func disableAndReenableRejectsOldCallbacksAndAnswersPendingRequests() async {
        let harness = Harness()
        harness.update(enabled: true)
        var result: Bool?
        harness.lifecycle.deliver(onIgnored: { result = false }) { result = true }
        harness.update(enabled: false)
        harness.update(enabled: true)
        await drainMainQueue()
        #expect(result == false)
    }

    @Test func firstEventsAfterWakeKeepQueueOrder() async {
        let harness = Harness()
        harness.update(enabled: true)
        harness.event(.systemWillSleep)
        harness.event(.systemDidWake)
        var events: [String] = []
        for event in ["voice_start", "first_pcm", "tail_pcm", "voice_stop", "drained"] {
            harness.lifecycle.deliver { events.append(event) }
        }
        await drainMainQueue()
        #expect(events == ["voice_start", "first_pcm", "tail_pcm", "voice_stop", "drained"])
    }

    @Test func voiceTailDrainsBeforeIdleSleepStopsTheServices() async {
        let harness = Harness()
        harness.update(enabled: true)
        var voice = MobileVoiceLifecycleState()
        voice.markStarted(.nearbyPhone)
        guard case let .begin(stopGeneration) = voice.beginStop(.nearbyPhone) else {
            Issue.record("Expected the normal mobile voice drain path")
            return
        }
        harness.event(.systemWillSleep, keepAlive: voice.activeSource != nil)
        var receivedSamples: [Int16] = []
        harness.lifecycle.deliver { receivedSamples.append(contentsOf: [1, 2]) }
        harness.lifecycle.deliver { receivedSamples.append(3) }
        harness.lifecycle.deliver {
            #expect(receivedSamples == [1, 2, 3])
            #expect(voice.completeStop(.nearbyPhone, generation: stopGeneration) == .stopped)
            harness.update(enabled: true, keepAlive: voice.activeSource != nil)
        }
        await drainMainQueue()
        #expect(receivedSamples == [1, 2, 3])
        #expect(voice.activeSource == nil)
        #expect(harness.operations == ["start_phone", "start_watch", "stop_phone", "stop_watch"])
    }

    @Test func logsDescribeSubmissionWithoutClaimingTransportCompletion() {
        let harness = Harness()
        harness.update(enabled: true)
        harness.event(.systemWillSleep)
        #expect(harness.logs.count == 2)
        #expect(harness.logs[0].contains("generation=1 phase=submitted result=start_requested"))
        #expect(harness.logs[1].contains("generation=2 phase=submitted result=stop_requested"))
        #expect(!harness.logs.contains { $0.contains("phase=completed") })
    }

    @Test func productionWiresLifecycleBeforeAudioEarlyReturnsAndRejectsStaleApproval() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/RemoteMic/BridgeAppModel.swift"
        ), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent(
            "Sources/RemoteMic/RemoteMicApp.swift"
        ), encoding: .utf8)
        let lifecycle = try #require(source.components(separatedBy:
            "func handleSystemAudioLifecycle(_ event: SystemAudioLifecycleEvent) {"
        ).last)
        let beforeAudioGuard = try #require(lifecycle.components(separatedBy:
            "guard started, changed else { return }"
        ).first)
        #expect(beforeAudioGuard.contains("nearbyRemoteLifecycle.handleSystemEvent(event)"))
        #expect(beforeAudioGuard.contains("updateNearbyRemoteLifecycle(reason: event.rawValue)"))
        #expect(source.contains("updateNearbyRemoteLifecycle(reason: \"voice_drained\")"))
        #expect(source.contains("self.nearbyRemoteLifecycle.acceptsEvents(generation: generation)"))
        #expect(app.contains("MainActor.assumeIsolated { [weak self] in"))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class Harness {
        var operations: [String] = []
        var logs: [String] = []
        lazy var lifecycle = NearbyRemoteLifecycle(
            start: { [weak self] in self?.operations.append(contentsOf: ["start_phone", "start_watch"]) },
            stop: { [weak self] in self?.operations.append(contentsOf: ["stop_phone", "stop_watch"]) },
            log: { [weak self] in self?.logs.append($0) }
        )

        func update(enabled: Bool, keepAlive: Bool = false) {
            lifecycle.update(enabled: enabled, keepAlive: keepAlive, reason: "test_update")
        }

        func event(_ event: SystemAudioLifecycleEvent, enabled: Bool = true, keepAlive: Bool = false) {
            lifecycle.handleSystemEvent(event)
            lifecycle.update(enabled: enabled, keepAlive: keepAlive, reason: event.rawValue)
        }
    }
}
