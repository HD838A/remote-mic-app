import AppKit
import AVFoundation
import Carbon
import Foundation
import Testing
@testable import RemoteMic

@Suite("Mac microphone input")
struct MacMicrophoneInputTests {
    @Test func threeEntriesShareOneSessionAndDrainAfterTheCaptureTail() throws {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .connectionPage)
        h.prepareCompletion?(nil)
        h.startCompletion?(nil)
        #expect(h.controller.state == .recording)
        h.controller.toggle(from: .shortcut)
        h.controller.toggle(from: .statusMenu)
        #expect(h.events == ["prepare", "start", "stop_capture"])
        // The final admitted PCM must reach the player before its drain starts.
        h.events.append("tail_pcm")
        h.stopCompletion?()
        #expect(h.events.suffix(2) == ["tail_pcm", "drain"])
        h.drainCompletion?(true)
        h.drainCompletion?(true)
        #expect(h.controller.state == .idle)
        #expect(h.events.filter { $0 == "finish" }.count == 1)
        #expect(h.logs.filter { $0.contains("phase=completed") }.count == 1)
    }

    @Test func cancelledPermissionCannotStartThisOrTheNextSession() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .statusMenu)
        let oldPermission = h.prepareCompletion
        h.controller.toggle(from: .connectionPage)
        h.stopCompletion?()
        h.drainCompletion?(true)
        h.controller.toggle(from: .shortcut)
        oldPermission?(nil)
        #expect(h.controller.state == .preparing)
        #expect(!h.events.contains("start"))
        h.prepareCompletion?(nil)
        h.startCompletion?(nil)
        #expect(h.controller.state == .recording)
        #expect(h.controller.operationID == 2)
    }

    @Test func cancelledCaptureStartDoesNotResurrectRecording() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .shortcut)
        h.prepareCompletion?(nil)
        let oldStart = h.startCompletion
        h.controller.stop()
        h.stopCompletion?()
        h.drainCompletion?(true)
        oldStart?(nil)
        #expect(h.controller.state == .idle)
    }

    @Test func busyRejectsWithoutCaptureAndAllowsExplicitRetry() {
        let h = MacMicrophoneHarness()
        h.busy = true
        h.controller.toggle(from: .connectionPage)
        #expect(h.controller.state == .failed(.busy))
        #expect(h.events.isEmpty)
        h.busy = false
        h.controller.toggle(from: .statusMenu)
        #expect(h.controller.state == .preparing)
    }

    @Test(arguments: [MacMicrophoneFailure.permission, .accessibility, .inputUnavailable,
                      .outputUnavailable, .targetUnavailable, .capture])
    func preparationFailureFinishesOnceAndDoesNotStartCapture(_ failure: MacMicrophoneFailure) {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .connectionPage)
        h.prepareCompletion?(failure)
        h.stopCompletion?()
        h.drainCompletion?(true)
        #expect(h.controller.state == .failed(failure))
        #expect(!h.events.contains("start"))
        h.controller.toggle(from: .shortcut)
        #expect(h.controller.state == .preparing)
    }

    @Test func preparationDeadlineAndLateCallbacksRemainIsolated() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .shortcut)
        h.timeout?()
        h.prepareCompletion?(nil)
        h.stopCompletion?()
        h.drainCompletion?(true)
        #expect(h.controller.state == .failed(.timedOut))
        #expect(!h.events.contains("start"))
    }

    @Test func forcedDrainAndFailureDuringStoppingNeverReportNormalSuccess() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .connectionPage)
        h.prepareCompletion?(nil)
        h.startCompletion?(nil)
        h.controller.stop()
        h.controller.stop(failure: .capture)
        h.stopCompletion?()
        h.drainCompletion?(false)
        #expect(h.controller.state == .failed(.capture))
        #expect(h.logs.last?.contains("completion=forced") == true)
    }

    @Test func shutdownInvalidatesPendingWork() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .statusMenu)
        h.controller.shutdown()
        h.prepareCompletion?(nil)
        h.stopCompletion?()
        #expect(h.controller.state == .failed(.interrupted))
        #expect(!h.events.contains("start"))
        #expect(!h.events.contains("drain"))
        #expect(h.logs.last?.contains("completion=forced reason=app_stop") == true)
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func converterPreservesSplitBufferOrderAndEndOfStreamTail(_ sampleRate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let frames = Int(sampleRate)
        func buffer(from start: Int, count: Int) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)))
            buffer.frameLength = UInt32(count)
            for channel in 0..<2 {
                let samples = try #require(buffer.floatChannelData?[channel])
                for index in 0..<count {
                    samples[index] = Float(sin(Double(start + index) * 2 * .pi * 440 / sampleRate) * 0.4)
                }
            }
            return buffer
        }
        let whole = try #require(MacMicrophonePCMConverter(inputFormat: format))
        var expected: [Int16] = []
        try whole.convert(buffer(from: 0, count: frames)) { expected += $0 }
        try whole.convert(nil) { expected += $0 }
        let split = try #require(MacMicrophonePCMConverter(inputFormat: format))
        var actual: [Int16] = []
        for start in stride(from: 0, to: frames, by: 512) {
            try split.convert(buffer(from: start, count: min(512, frames - start))) { actual += $0 }
        }
        try split.convert(nil) { actual += $0 }
        let endedCount = actual.count
        try split.convert(nil) { actual += $0 }
        #expect(actual.count == endedCount)
        #expect(actual.count == expected.count)
        #expect(abs(actual.count - 16_000) <= 1)
        #expect(zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        #expect(actual.suffix(100).contains { abs(Int($0)) > 100 })
    }

    @MainActor @Test func hotKeyIgnoresOtherIDsAndRepeatedPresses() throws {
        let shortcut = MacMicrophoneShortcut()
        var count = 0
        shortcut.onPress = { count += 1 }
        func send(_ kind: UInt32, signature: OSType = 0x53414D43) throws -> OSStatus {
            var event: EventRef?
            #expect(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
            let value = try #require(event)
            defer { ReleaseEvent(value) }
            var id = EventHotKeyID(signature: signature, id: 1)
            #expect(SetEventParameter(value, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
            return shortcut.handle(value)
        }
        #expect(try send(UInt32(kEventHotKeyPressed), signature: 123) == OSStatus(eventNotHandledErr))
        #expect(try send(UInt32(kEventHotKeyPressed)) == noErr)
        #expect(try send(UInt32(kEventHotKeyPressed)) == noErr)
        #expect(count == 1)
        #expect(try send(UInt32(kEventHotKeyReleased)) == noErr)
        #expect(try send(UInt32(kEventHotKeyPressed)) == noErr)
        #expect(count == 2)
        #expect(!MacMicrophoneShortcut.supports(.init(keyCode: 54, modifierFlags: .command, keyLabel: "")))
        #expect(!MacMicrophoneShortcut.supports(.init(keyCode: 0, modifierFlags: .function, keyLabel: "A")))
        #expect(MacMicrophoneShortcut.supports(.init(keyCode: 0, modifierFlags: [.command, .shift], keyLabel: "A")))
    }

    @Test func settingsDefaultToNoHotKeyAndRoundTripWithoutChangingVoicePreferences() throws {
        let name = "MacMicrophoneInputTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.macMicrophoneInputUID.isEmpty)
        #expect(settings.macMicrophoneShortcut == nil)
        let voiceMode = settings.voiceKeyMode
        settings.macMicrophoneInputUID = "test-physical-mic"
        settings.macMicrophoneShortcut = .init(keyCode: 0, modifierFlags: [.control, .option], keyLabel: "A")
        let payload = try settings.exportedConfigurationData()
        settings.macMicrophoneInputUID = ""
        settings.macMicrophoneShortcut = nil
        try settings.importConfiguration(from: payload)
        #expect(settings.macMicrophoneInputUID == "test-physical-mic")
        #expect(settings.macMicrophoneShortcut?.keyCode == 0)
        #expect(settings.voiceKeyMode == voiceMode)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.macMicrophoneShortcut == settings.macMicrophoneShortcut)
        #expect(restored.macMicrophoneInputUID == settings.macMicrophoneInputUID)
    }

    @Test func explicitSearchFieldIsAllowedAndProtectedFieldsAreRejected() {
        func snapshot(role: String = "AXTextField", protected: Bool = false) -> VoiceInputDestinationSnapshot {
            .init(bundleIdentifier: "com.example.editor", role: role, subrole: "", enabled: true,
                editable: true, protectedContent: protected, semanticText: "Search 搜索")
        }
        #expect(MacMicrophoneInputTarget.isEligible(snapshot()))
        #expect(!MacMicrophoneInputTarget.isEligible(snapshot(protected: true)))
        #expect(!MacMicrophoneInputTarget.isEligible(snapshot(role: "AXSecureTextField")))
        #expect(!MacMicrophoneInputTarget.isEligible(snapshot(role: "AXButton")))
    }

    @Test func legacyConfigurationWithoutMacFieldsRemainsImportable() throws {
        let name = "MacMicrophoneInputTests.legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.gainDB = 17
        var payload = try #require(JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any])
        payload.removeValue(forKey: "macMicrophoneInputUID")
        payload.removeValue(forKey: "macMicrophoneShortcut")
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: payload))
        #expect(settings.gainDB == 17)
        #expect(settings.macMicrophoneShortcut == nil)
        #expect(settings.macMicrophoneInputUID.isEmpty)
    }

    @Test func fnTapJourneyKeepsTheFirstAndLastSamplesAndFinishesAfterTheStopTap() {
        let scheduler = MacMicrophoneScheduler()
        var keyEdges: [Bool] = []
        var played: [Int16] = []
        var captureTail: (() -> Void)?
        var playerDrain: (() -> Void)?
        var prepared: ((MacMicrophoneFailure?) -> Void)?
        var finished = false
        let tap = VoiceFnTapSessionController(schedule: scheduler.schedule,
            setFunctionKeyPressed: { keyEdges.append($0); return true },
            enqueueAudio: { played += $0 }, drainAudio: { _, done in playerDrain = done },
            onFailure: { _ in Issue.record("Fn tap failed") })
        tap.setEnabled(true)
        let session = MacMicrophoneSessionController(isBusy: { false },
            prepare: { prepared = $0 },
            startCapture: { done in #expect(tap.startVoice()); done(nil) },
            stopCapture: { captureTail = $0 },
            drain: { done in tap.stopVoice { done(true) } },
            finish: { finished = true }, schedule: scheduler.schedule, log: { _ in })
        session.toggle(from: .connectionPage)
        // Delayed audio/target preparation must not send an early Fn edge.
        #expect(keyEdges.isEmpty)
        prepared?(nil)
        #expect(tap.receive([11, 12]))
        session.toggle(from: .shortcut)
        #expect(tap.receive([13, 14]))
        captureTail?()
        scheduler.advance(0.27)
        #expect(played == [11, 12, 13, 14])
        #expect(keyEdges == [true, false])
        #expect(!finished)
        playerDrain?()
        #expect(!finished)
        scheduler.advance(0.12)
        #expect(keyEdges == [true, false, true, false])
        #expect(finished)
        #expect(session.state == .idle)
    }

    @Test(arguments: [3, 4])
    func failedStopTapReachesTheSessionBeforeItsCompletion(_ failedEdge: Int) {
        let scheduler = MacMicrophoneScheduler()
        var edgeCount = 0
        var playerDrain: (() -> Void)?
        var session: MacMicrophoneSessionController!
        var logs: [String] = []
        let tap = VoiceFnTapSessionController(schedule: scheduler.schedule,
            setFunctionKeyPressed: { _ in
                edgeCount += 1
                return edgeCount != failedEdge
            }, enqueueAudio: { _ in }, drainAudio: { _, done in playerDrain = done },
            onFailure: { _ in session.stop(failure: .capture) })
        tap.setEnabled(true)
        session = MacMicrophoneSessionController(isBusy: { false },
            prepare: { $0(nil) },
            startCapture: { done in #expect(tap.startVoice()); done(nil) },
            stopCapture: { $0() },
            drain: { done in tap.stopVoice { done(true) } },
            finish: {}, schedule: scheduler.schedule, log: { logs.append($0) })
        session.toggle(from: .shortcut)
        scheduler.advance(0.27)
        session.toggle(from: .statusMenu)
        playerDrain?()
        scheduler.advance(0.12)
        #expect(session.state == .failed(.capture))
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
        #expect(logs.last?.contains("result=failed") == true)
        #expect(logs.last?.contains("completion=forced") == true)
    }
}

private final class MacMicrophoneHarness {
    var busy = false
    var events: [String] = []
    var logs: [String] = []
    var prepareCompletion: ((MacMicrophoneFailure?) -> Void)?
    var startCompletion: ((MacMicrophoneFailure?) -> Void)?
    var stopCompletion: (() -> Void)?
    var drainCompletion: ((Bool) -> Void)?
    var timeout: (() -> Void)?
    lazy var controller = MacMicrophoneSessionController(
        isBusy: { self.busy },
        prepare: { self.events.append("prepare"); self.prepareCompletion = $0 },
        startCapture: { self.events.append("start"); self.startCompletion = $0 },
        stopCapture: { self.events.append("stop_capture"); self.stopCompletion = $0 },
        drain: { self.events.append("drain"); self.drainCompletion = $0 },
        finish: { self.events.append("finish") },
        schedule: { _, action in self.timeout = action; return VoiceFnTapScheduledTask {} },
        log: { self.logs.append($0) }
    )
}

private final class MacMicrophoneScheduler {
    private var clock: TimeInterval = 0
    private var work: [(id: UUID, deadline: TimeInterval, action: () -> Void)] = []
    lazy var schedule: VoiceFnTapSessionController.Scheduler = { [unowned self] delay, action in
        let id = UUID()
        work.append((id, clock + delay, action))
        return VoiceFnTapScheduledTask { [weak self] in self?.work.removeAll { $0.id == id } }
    }
    func advance(_ interval: TimeInterval) {
        let end = clock + interval
        while let next = work.filter({ $0.deadline <= end }).min(by: { $0.deadline < $1.deadline }) {
            work.removeAll { $0.id == next.id }
            clock = next.deadline
            next.action()
        }
        clock = end
    }
}
