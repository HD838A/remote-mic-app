import AppKit
import AVFoundation
import Carbon
import Foundation
import Testing
@testable import RemoteMic

@Suite("Mac microphone input")
struct MacMicrophoneInputTests {
    @Test func choosingInputDoesNotStartCapture() {
        let h = MacMicrophoneHarness(); h.controller.toggle(from: .connectionPage)
        h.prepareCompletion?(nil)
        #expect(!h.events.contains("start"))
    }
    @Test(arguments: [MacMicrophoneEntry.connectionPage, .statusMenu, .shortcut])
    func allSourceEntriesArmWithoutCapture(_ entry: MacMicrophoneEntry) {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: entry)
        h.prepareCompletion?(nil)
        #expect(h.controller.state == .armed)
        #expect(h.controller.isEnabled)
        #expect(!h.controller.state.isActive)
        #expect(h.events == ["prepare"])
        h.controller.toggle(from: entry)
        #expect(h.controller.state == .idle)
        #expect(!h.controller.isEnabled)
        #expect(!h.events.contains("start"))
    }

    @Test func holdKeyStartsOnlyAfterArmingAndDrainsTheCaptureTail() {
        let h = MacMicrophoneHarness()
        h.controller.handleVoiceKey(pressed: true, gesture: .hold)
        #expect(h.events.isEmpty)
        h.arm()
        h.controller.handleVoiceKey(pressed: true, gesture: .hold)
        h.prepareCompletion?(nil)
        h.startCompletion?(nil)
        #expect(h.controller.state == .recording)
        h.controller.handleVoiceKey(pressed: false, gesture: .hold)
        #expect(h.controller.state == .stopping)
        h.events.append("tail_pcm")
        h.stopCompletion?()
        #expect(h.events.suffix(2) == ["tail_pcm", "drain"])
        h.drainCompletion?(true)
        h.drainCompletion?(true)
        #expect(h.controller.state == .armed)
        #expect(h.events.filter { $0 == "finish" }.count == 1)
        #expect(h.logs.filter { $0.contains("phase=completed") }.count == 1)
    }

    @Test func toggleKeyKeepsCaptureAfterReleaseAndStopsOnNextPress() {
        let h = MacMicrophoneHarness(); h.arm()
        h.controller.handleVoiceKey(pressed: true, gesture: .toggle)
        h.controller.handleVoiceKey(pressed: true, gesture: .toggle)
        h.prepareCompletion?(nil); h.startCompletion?(nil)
        #expect(h.events.filter { $0 == "start" }.count == 1)
        h.controller.handleVoiceKey(pressed: false, gesture: .toggle)
        #expect(h.controller.state == .recording)
        h.controller.handleVoiceKey(pressed: true, gesture: .toggle)
        #expect(h.controller.state == .stopping)
        h.stopCompletion?(); h.drainCompletion?(true)
        #expect(h.controller.state == .armed)
    }

    @Test func cancelledSelectionCannotStartThisOrTheNextSession() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .statusMenu)
        let oldPermission = h.prepareCompletion
        h.controller.toggle(from: .connectionPage)
        h.stopCompletion?(); h.drainCompletion?(true)
        #expect(h.controller.state == .idle)
        h.controller.toggle(from: .shortcut)
        oldPermission?(nil)
        #expect(h.controller.state == .preparing)
        h.prepareCompletion?(nil)
        #expect(h.controller.state == .armed)
        #expect(!h.events.contains("start"))
        #expect(h.controller.operationID == 2)
    }

    @Test func voiceKeyDuringSelectionOnlyStartsIfStillRequested() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .connectionPage)
        h.controller.handleVoiceKey(pressed: true, gesture: .hold)
        h.controller.handleVoiceKey(pressed: false, gesture: .hold)
        h.prepareCompletion?(nil)
        #expect(h.controller.state == .armed)
        #expect(!h.events.contains("start"))
        h.controller.handleVoiceKey(pressed: true, gesture: .hold)
        h.prepareCompletion?(nil)
        let oldStart = h.startCompletion
        h.controller.handleVoiceKey(pressed: false, gesture: .hold)
        h.stopCompletion?(); h.drainCompletion?(true); oldStart?(nil)
        #expect(h.controller.state == .armed)
    }

    @Test func busyRejectsWithoutCaptureAndAllowsExplicitRetry() {
        let h = MacMicrophoneHarness(); h.busy = true
        h.controller.toggle(from: .connectionPage)
        #expect(h.controller.state == .failed(.busy))
        #expect(!h.controller.isEnabled)
        #expect(h.events.isEmpty)
        h.busy = false; h.arm()
        #expect(h.controller.state == .armed)
    }

    @Test(arguments: [MacMicrophoneFailure.permission, .accessibility, .inputMonitoring,
                      .inputUnavailable, .outputUnavailable, .targetUnavailable, .capture])
    func preparationFailureFinishesOnceAndDoesNotStartCapture(_ failure: MacMicrophoneFailure) {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .connectionPage)
        h.prepareCompletion?(failure); h.stopCompletion?(); h.drainCompletion?(true)
        #expect(h.controller.state == .failed(failure))
        #expect(!h.controller.isEnabled)
        #expect(!h.events.contains("start"))
        h.controller.toggle(from: .shortcut)
        #expect(h.controller.state == .preparing)
    }

    @Test func preparationDeadlineAndLateCallbacksRemainIsolated() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .shortcut); h.timeout?(); h.prepareCompletion?(nil)
        h.stopCompletion?(); h.drainCompletion?(true)
        #expect(h.controller.state == .failed(.timedOut))
        #expect(!h.events.contains("start"))
    }

    @Test func forcedDrainAndFailureDuringStoppingNeverReportNormalSuccess() {
        let h = MacMicrophoneHarness(); h.arm(); h.beginVoice()
        h.controller.handleVoiceKey(pressed: false, gesture: .hold)
        h.controller.stop(failure: .capture)
        h.stopCompletion?(); h.drainCompletion?(false)
        #expect(h.controller.state == .failed(.capture))
        #expect(!h.controller.isEnabled)
        #expect(h.logs.last?.contains("completion=forced") == true)
    }

    @Test func rapidNextKeyWaitsForDrainAndCanBeCancelled() {
        let h = MacMicrophoneHarness(); h.arm(); h.beginVoice()
        h.controller.handleVoiceKey(pressed: false, gesture: .hold)
        h.controller.handleVoiceKey(pressed: true, gesture: .hold)
        #expect(h.events.filter { $0 == "start" }.count == 1)
        h.stopCompletion?(); h.drainCompletion?(true)
        #expect(h.controller.state == .preparing)
        h.prepareCompletion?(nil); h.startCompletion?(nil)
        #expect(h.events.filter { $0 == "start" }.count == 2)
        h.controller.handleVoiceKey(pressed: false, gesture: .hold)
        h.controller.handleVoiceKey(pressed: true, gesture: .hold)
        h.controller.handleVoiceKey(pressed: false, gesture: .hold)
        h.stopCompletion?(); h.drainCompletion?(true)
        #expect(h.controller.state == .armed)
        #expect(h.events.filter { $0 == "start" }.count == 2)
    }

    @Test func twentyInjectedKeySessionsKeepSelectionArmed() {
        let h = MacMicrophoneHarness(); h.arm()
        for _ in 0..<20 {
            h.beginVoice()
            h.controller.handleVoiceKey(pressed: false, gesture: .hold)
            h.stopCompletion?(); h.drainCompletion?(true)
            #expect(h.controller.state == .armed)
        }
        #expect(h.events.filter { $0 == "start" }.count == 20)
        #expect(h.events.filter { $0 == "finish" }.count == 20)
        h.controller.toggle(from: .statusMenu)
        #expect(h.controller.state == .idle)
        h.controller.handleVoiceKey(pressed: true, gesture: .hold)
        #expect(h.events.filter { $0 == "start" }.count == 20)
    }

    @Test func shutdownInvalidatesPendingWorkAndSelection() {
        let h = MacMicrophoneHarness()
        h.controller.toggle(from: .statusMenu); h.controller.shutdown(); h.prepareCompletion?(nil)
        h.stopCompletion?()
        #expect(h.controller.state == .failed(.interrupted))
        #expect(!h.controller.isEnabled)
        #expect(!h.events.contains("start"))
        #expect(!h.events.contains("drain"))
        #expect(h.logs.last?.contains("completion=forced reason=app_stop") == true)
    }

    @Test func firstEffectivePCMUsesTheCurrentPhysicalKeyTimestampOnlyOnce() {
        let h = MacMicrophoneHarness(); h.arm()
        h.controller.handleVoiceKey(pressed: true, gesture: .hold, observedAt: 10)
        h.prepareCompletion?(nil); h.startCompletion?(nil)
        h.controller.observePCM([0, 0], at: 10.125)
        #expect(!h.logs.contains { $0.contains("first_effective_pcm") })
        h.controller.observePCM([1, 0], at: 10.25)
        h.controller.observePCM([2], at: 10.5)
        #expect(h.logs.filter { $0.contains("first_effective_pcm") }.count == 1)
        #expect(h.logs.contains { $0.contains("trigger_down_to_first_pcm_ms=250") })
    }

    @Test func physicalFnDetectionRejectsArrowFlagsOtherKeysAndSyntheticEvents() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        event.flags = .maskSecondaryFn
        event.setIntegerValueField(.keyboardEventKeycode, value: 63)
        #expect(MacMicrophoneVoiceKeyMonitor.physicalEdge(type: .flagsChanged, event: event, mode: .function) == true)
        #expect(MacMicrophoneVoiceKeyMonitor.physicalEdge(type: .keyDown, event: event, mode: .function) == nil)
        event.setIntegerValueField(.keyboardEventKeycode, value: 126)
        #expect(MacMicrophoneVoiceKeyMonitor.physicalEdge(type: .flagsChanged, event: event, mode: .function) == nil)
        event.setIntegerValueField(.keyboardEventKeycode, value: 63)
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        #expect(MacMicrophoneVoiceKeyMonitor.physicalEdge(type: .flagsChanged, event: event, mode: .function) == nil)
        let release = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false))
        release.flags = []
        #expect(MacMicrophoneVoiceKeyMonitor.physicalEdge(type: .flagsChanged, event: release, mode: .function) == false)
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

    @Test func inputConfigurationChangeOnlyFailsWhenTheDeviceActuallyChanged() {
        #expect(!MacMicrophoneConfigurationChangePolicy.shouldFail(
            selectedDeviceID: 118,
            currentDeviceID: 118
        ))
        #expect(MacMicrophoneConfigurationChangePolicy.shouldFail(
            selectedDeviceID: 118,
            currentDeviceID: 119
        ))
        #expect(!MacMicrophoneConfigurationChangePolicy.shouldFail(
            selectedDeviceID: 118,
            currentDeviceID: nil
        ))
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

    @Test(arguments: [MobileVoiceSource.macMicrophone, .nearbyPhone, .nearbyWatch, .web])
    func onlyRemoteSourcesSendVoiceKeyEdges(_ source: MobileVoiceSource) {
        var edges: [Bool] = []
        #expect(source.updateVoiceTrigger { edges.append(true); return true })
        #expect(source.updateVoiceTrigger { edges.append(false); return true })
        #expect(edges == (source == .macMicrophone ? [] : [true, false]))
    }

    @Test func macMicrophoneDoesNotDependOnKeyboardInjectionPermission() {
        var attempts = 0
        #expect(MobileVoiceSource.macMicrophone.updateVoiceTrigger {
            attempts += 1
            return false
        })
        #expect(attempts == 0)
        #expect(!MobileVoiceSource.nearbyPhone.updateVoiceTrigger { false })
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
    func arm() {
        controller.toggle(from: .connectionPage)
        prepareCompletion?(nil)
    }
    func beginVoice() {
        controller.handleVoiceKey(pressed: true, gesture: .hold)
        prepareCompletion?(nil)
        startCompletion?(nil)
    }
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
