import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Configurable button interactions", .serialized)
@MainActor
struct RemoteButtonInteractionTests {
    private func snapshot(_ mode: RemoteButtonHoldMode = .once, double: Bool = false,
                          long: Bool = false, d: Int = 300, l: Int = 550) -> RemoteButtonInteractionSnapshot {
        .init(settings: .init(doubleClickMilliseconds: d, longPressMilliseconds: l), mode: mode,
              single: .init(action: .deleteBackward, shortcut: nil),
              double: .init(action: double ? .returnKey : .disabled, shortcut: nil),
              long: .init(action: long ? .arrowRight : .disabled, shortcut: nil))
    }

    @Test func doubleWindowStartsAtReleaseAndUsesCapturedTiming() {
        let clock = InteractionClock()
        let controller = RemoteButtonInteractionController(scheduler: clock)
        var events: [ButtonTrigger] = []
        var config = snapshot(double: true, d: 200)
        controller.handle(.press, button: .ok, snapshot: config, valid: { true }) { t, _ in events.append(t); return true }
        clock.advance(150)
        config.settings.doubleClickMilliseconds = 500
        controller.handle(.release, button: .ok, snapshot: config, valid: { true }, perform: { _, _ in false })
        clock.advance(349)
        #expect(events.isEmpty)
        clock.advance(350)
        #expect(events == [.singleClick])
        #expect(!controller.isTracking(.ok))
    }

    @Test func longPressStartsAtDownAndSuppressesReleaseClick() {
        let clock = InteractionClock()
        let controller = RemoteButtonInteractionController(scheduler: clock)
        var events: [ButtonTrigger] = []
        controller.handle(.press, button: .ok, snapshot: snapshot(long: true, l: 400), valid: { true }) { t, _ in events.append(t); return true }
        clock.advance(399)
        #expect(events.isEmpty)
        clock.advance(400)
        #expect(events == [.longPress])
        controller.handle(.release, button: .ok, snapshot: snapshot(), valid: { true }, perform: { _, _ in false })
        clock.advance(1500)
        #expect(events == [.longPress])
    }

    @Test(arguments: [RemoteButtonHoldMode.repeatSingle, .repeatLong])
    func repeatingStopsAtRelease(_ mode: RemoteButtonHoldMode) {
        let clock = InteractionClock()
        let controller = RemoteButtonInteractionController(scheduler: clock)
        var events: [ButtonTrigger] = []
        let config = snapshot(mode, long: mode == .repeatLong, l: 400)
        controller.handle(.press, button: .ok, snapshot: config, valid: { true }) { t, _ in events.append(t); return true }
        #expect(events.count == (mode == .repeatSingle ? 1 : 0))
        clock.advance(600)
        #expect(events.count == (mode == .repeatSingle ? 4 : 3))
        controller.handle(.release, button: .ok, snapshot: config, valid: { true }, perform: { _, _ in false })
        let count = events.count
        clock.advance(2000)
        #expect(events.count == count)
    }

    @Test func repeatSingleWithDoubleHasDistinctHoldAndSecondPressPaths() {
        let clock = InteractionClock()
        let controller = RemoteButtonInteractionController(scheduler: clock)
        var events: [ButtonTrigger] = []
        let config = snapshot(.repeatSingle, double: true, d: 200)
        func edge(_ phase: RemoteButtonPhase) {
            controller.handle(phase, button: .ok, snapshot: config, valid: { true }) { t, _ in events.append(t); return true }
        }
        edge(.press)
        clock.advance(199)
        #expect(events.isEmpty)
        clock.advance(400)
        #expect(events == [.singleClick, .singleClick, .singleClick])
        edge(.release)
        events = []
        edge(.press)
        clock.advance(410)
        edge(.release)
        clock.advance(450)
        edge(.press)
        clock.advance(1500)
        #expect(events.isEmpty)
        edge(.release)
        #expect(events == [.doubleClick])
    }

    @Test func keyOwnershipBalancesDownUpAcrossDevicesAndCancellation() {
        var keys: [(UInt16, Bool, CGEventFlags)] = []
        let ownership = RemoteButtonKeyOwnership { code, down, flags in keys.append((code, down, flags)); return true }
        let clock = InteractionClock()
        let first = RemoteButtonInteractionController(scheduler: clock, keys: ownership)
        let second = RemoteButtonInteractionController(scheduler: clock, keys: ownership)
        let config = snapshot(.holdSingle)
        for controller in [first, second] {
            controller.handle(.press, button: .ok, snapshot: config, valid: { true }, perform: { _, _ in false })
        }
        #expect(keys.map { $0.1 } == [true])
        first.cancelAll(reason: "disconnect")
        #expect(keys.map { $0.1 } == [true])
        second.handle(.release, button: .ok, snapshot: config, valid: { false }, perform: { _, _ in false })
        #expect(keys.map { $0.1 } == [true, false])
        #expect(keys.map { $0.0 } == [51, 51])
    }

    @Test func learningStartCancellationStopsRepeatsAndReleasesHeldKeys() {
        let clock = InteractionClock()
        var keys: [(UInt16, Bool)] = []
        let ownership = RemoteButtonKeyOwnership { code, down, _ in
            keys.append((code, down))
            return true
        }
        let held = RemoteButtonInteractionController(scheduler: clock, keys: ownership)
        let repeating = RemoteButtonInteractionController(scheduler: clock)
        held.handle(.press, button: .ok, snapshot: snapshot(.holdSingle), valid: { true }) { _, _ in false }
        var repeatCount = 0
        repeating.handle(.press, button: .back, snapshot: snapshot(.repeatSingle), valid: { true }) { _, _ in
            repeatCount += 1
            return true
        }

        held.cancelAll(reason: "learning_started")
        repeating.cancelAll(reason: "learning_started")
        let countAfterCancellation = repeatCount
        clock.advance(2_000)

        #expect(keys.map(\.1) == [true, false])
        #expect(keys.map(\.0) == [51, 51])
        #expect(repeatCount == countAfterCancellation)
    }

    @Test func invalidModeAndConflictingGesturesNeverFallBack() {
        let clock = InteractionClock()
        let controller = RemoteButtonInteractionController(scheduler: clock)
        var count = 0
        for config in [snapshot(.holdSingle, double: true), snapshot(.repeatSingle, long: true),
                       snapshot(d: 149), RemoteButtonInteractionSnapshot(settings: .init(), mode: nil,
                            single: .disabled, double: .disabled, long: .disabled)] {
            controller.handle(.press, button: .ok, snapshot: config, valid: { true }) { _, _ in count += 1; return true }
            clock.advance(clock.now + 2000)
            controller.handle(.release, button: .ok, snapshot: config, valid: { true }, perform: { _, _ in false })
        }
        #expect(count == 0)
    }

    @Test func contextChangeAndFailedActionCancelRepeats() {
        for fail in [false, true] {
            let clock = InteractionClock()
            let controller = RemoteButtonInteractionController(scheduler: clock)
            var valid = true
            var count = 0
            controller.handle(.press, button: .ok, snapshot: snapshot(.repeatSingle), valid: { valid }) { _, _ in count += 1; return !fail }
            valid = false
            clock.advance(1000)
            #expect(count == 1)
            #expect(!controller.isTracking(.ok))
        }
    }

    @Test func opaqueSecondaryGesturesRemainRecognizableButCannotRepeat() {
        var config = snapshot()
        config.opaqueLong = true
        config.hasOpaqueBinding = true
        #expect(config.unavailableReason == nil)
        let clock = InteractionClock()
        let controller = RemoteButtonInteractionController(scheduler: clock)
        var events: [ButtonTrigger] = []
        controller.handle(.press, button: .ok, snapshot: config, valid: { true }) { t, _ in events.append(t); return true }
        clock.advance(550)
        #expect(events == [.longPress])
        config.mode = .repeatLong
        #expect(config.unavailableReason != nil)
    }

    @Test func timingAndModeMigrationAreIdempotentAndInvalidOverridesStayInactive() throws {
        let name = "SayAll.InteractionMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = RemoteDeviceProfile(model: .rc003, mappings: .init(
            buttonBindings: AppSettings.defaultBindings, buttonShortcuts: [:], secondaryButtonBindings: [:]))
        let original = try JSONEncoder().encode([legacy])
        defaults.set(original, forKey: "remoteDeviceProfiles")
        defaults.set(legacy.id.uuidString, forKey: "selectedRemoteProfileID")
        let first = AppSettings(defaults: defaults)
        #expect(first.interactionSettings.mode(for: .back) == .repeatSingle)
        #expect(first.interactionSettings.migratedRepeatButtons?.contains("back") == true)
        #expect(defaults.data(forKey: "buttonInteractionMigrationBackup") == original)
        let second = AppSettings(defaults: defaults)
        #expect(second.interactionSettings == first.interactionSettings)
        #expect(defaults.data(forKey: "buttonInteractionMigrationBackup") == original)
        second.interactionModeOverride = { _, _ in "holdSingle" }
        #expect(second.interactionSnapshot(for: .back).mode == .holdSingle)
        second.interactionModeOverride = { _, _ in "unknown" }
        #expect(second.interactionSnapshot(for: .back).unavailableReason != nil)
        second.interactionModeOverride = nil
        second.setHoldMode(.once, for: .back)
        #expect(second.interactionSettings.migratedRepeatButtons?.contains("back") == false)
        #expect(second.interactionSnapshot(for: .back).mode == .once)
        second.interactionSettings.modes["back"] = "unknown"
        second.interactionSettings.migratedRepeatButtons = ["back"]
        second.setAction(.arrowLeft, for: .back, trigger: .longPress)
        #expect(second.interactionSnapshot(for: .back).unavailableReason != nil)
    }

    @Test func timingChangesDoNotCancelButModeAndMappingChangesDo() throws {
        let name = "SayAll.InteractionChanges.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        var cancelled = 0
        settings.onInteractionModeChanged = { _ in cancelled += 1 }
        settings.interactionSettings.doubleClickMilliseconds = 200
        settings.interactionSettings.longPressMilliseconds = 800
        #expect(cancelled == 0)
        settings.setHoldMode(.holdSingle, for: .ok)
        #expect(cancelled > 0)
        cancelled = 0
        settings.setAction(.arrowLeft, for: .ok)
        #expect(cancelled > 0)
    }

    @Test func timingIsPerModelWhileModesRemainPerDeviceAndBackupRoundTrips() throws {
        let name = "SayAll.Interaction.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID())
        settings.updateRemoteProfileModel(first, model: .rc003)
        settings.selectRemoteProfile(first)
        settings.setButtonGestureTiming(.init(
            doubleClickMilliseconds: 150,
            longPressMilliseconds: 1000
        ), for: .rc003)
        settings.setHoldMode(.holdSingle, for: .ok)
        let second = settings.registerBluetoothRemote(identifier: UUID())
        settings.updateRemoteProfileModel(second, model: .rc003)
        settings.selectRemoteProfile(second)
        #expect(settings.buttonInteractionSettings().timing == .init(
            doubleClickMilliseconds: 150,
            longPressMilliseconds: 1000
        ))
        settings.setHoldMode(.repeatLong, for: .menu)
        let third = settings.registerBluetoothRemote(identifier: UUID())
        settings.updateRemoteProfileModel(third, model: .rc001)
        settings.selectRemoteProfile(third)
        settings.setButtonGestureTiming(.init(
            doubleClickMilliseconds: 500,
            longPressMilliseconds: 600
        ), for: .rc001)
        let restarted = AppSettings(defaults: defaults)
        restarted.selectRemoteProfile(first)
        #expect(restarted.buttonInteractionSettings().doubleClickMilliseconds == 150)
        #expect(restarted.buttonInteractionSettings().longPressMilliseconds == 1000)
        #expect(restarted.interactionSettings.mode(for: .ok) == .holdSingle)
        restarted.selectRemoteProfile(second)
        #expect(restarted.buttonInteractionSettings().doubleClickMilliseconds == 150)
        #expect(restarted.interactionSettings.mode(for: .menu) == .repeatLong)
        restarted.selectRemoteProfile(third)
        #expect(restarted.buttonInteractionSettings().doubleClickMilliseconds == 500)
        #expect(restarted.buttonInteractionSettings().longPressMilliseconds == 600)
        let data = try MacConfigurationBackup(host: restarted.completeConfigurationSnapshot(), components: nil).encoded(version: "2.0.0", build: "test")
        let backup = try MacConfigurationBackup.decode(data)
        let validated = try restarted.validatedCompleteConfigurationSnapshot(backup.host)
        try restarted.applyPortableLocalSnapshot(validated)
        #expect(restarted.buttonGestureTiming(for: .rc003).doubleClickMilliseconds == 150)
        #expect(restarted.buttonGestureTiming(for: .rc001).doubleClickMilliseconds == 500)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        object["schemaVersion"] = 1
        var requirements = try #require(object["requirements"] as? [String: String])
        requirements["reader"] = "sayall-macos-configuration/1"
        object["requirements"] = requirements
        #expect(throws: Never.self) { _ = try MacConfigurationBackup.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func unknownModelTimingIsRejectedDuringLoadAndImport() throws {
        let name = "SayAll.Interaction.UnknownModel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let timing = RemoteButtonGestureTiming(
            doubleClickMilliseconds: 150,
            longPressMilliseconds: 1_000
        )
        defaults.set(
            try JSONEncoder().encode([XiaomiRemoteModel.unknown.rawValue: timing]),
            forKey: "buttonGestureTimingsByModel"
        )
        let settings = AppSettings(defaults: defaults)
        #expect(settings.buttonGestureTimingsByModel[XiaomiRemoteModel.unknown.rawValue] == nil)
        #expect(settings.buttonGestureTiming(for: .unknown) == RemoteButtonGestureTiming())

        settings.setButtonGestureTiming(timing, for: .rc003)
        var object = try #require(
            JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any]
        )
        object["buttonGestureTimingsByModel"] = [
            XiaomiRemoteModel.unknown.rawValue: [
                "doubleClickMilliseconds": 150,
                "longPressMilliseconds": 1_000,
            ],
        ]
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.configurationImportNotice?.rejectedEntryStorageKeys.contains(
            "buttonGestureTimingsByModel"
        ) == true)
        #expect(settings.buttonGestureTiming(for: .rc003) == timing)
    }

    @Test func learningRequiresAConnectedKnownModelButManualTimingDoesNot() {
        let disconnected = RemoteButtonGestureLearningAvailability(model: .rc003, isConnected: false)
        #expect(disconnected.canSaveTiming)
        #expect(!disconnected.canLearn)

        let connected = RemoteButtonGestureLearningAvailability(model: .rc003, isConnected: true)
        #expect(connected.canSaveTiming)
        #expect(connected.canLearn)

        let unknown = RemoteButtonGestureLearningAvailability(model: .unknown, isConnected: true)
        #expect(!unknown.canSaveTiming)
        #expect(!unknown.canLearn)
    }

    @Test func learningMeasuresOneButtonAndSuggestsValidSliderValues() {
        var learner = RemoteButtonGestureLearner()
        learner.start(model: .rc003)
        #expect(learner.status.step == .singleClick)
        #expect(learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_000) == nil)
        #expect(learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_080) == nil)
        #expect(learner.status.singleClickMilliseconds == 80)
        #expect(learner.status.step == .doubleClick)

        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 2_000)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 2_070)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 2_286)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 2_350)
        #expect(learner.status.doubleClickMilliseconds == 216)
        #expect(learner.status.step == .longPress)

        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 3_000)
        let result = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 3_735)
        #expect(result?.singleClickMilliseconds == 80)
        #expect(result?.doubleClickMilliseconds == 216)
        #expect(result?.longPressMilliseconds == 735)
        #expect(result?.suggestedTiming == .init(
            doubleClickMilliseconds: 250,
            longPressMilliseconds: 700
        ))
        #expect(result?.suggestedTiming.isValid == true)
        #expect(learner.status.step == .complete)
    }

    @Test func learningIgnoresOtherButtonsAndModelsWithoutAdvancing() {
        var learner = RemoteButtonGestureLearner()
        learner.start(model: .rc003)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 100)
        _ = learner.handle(.release, button: .back, model: .rc003, timestampMilliseconds: 150)
        _ = learner.handle(.release, button: .ok, model: .rc001, timestampMilliseconds: 160)
        #expect(learner.status.step == .singleClick)
        #expect(learner.status.singleClickMilliseconds == nil)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 170)
        #expect(learner.status.singleClickMilliseconds == 70)
    }
}

private final class InteractionClock: HIDRemoteScheduling {
    final class Task: HIDRemoteScheduledTask {
        var at: UInt64
        let repeatInterval: UInt64?
        let run: () -> Void
        var cancelled = false
        init(_ at: UInt64, _ repeatInterval: UInt64?, _ run: @escaping () -> Void) {
            self.at = at; self.repeatInterval = repeatInterval; self.run = run
        }
        func cancel() { cancelled = true }
    }
    var now: UInt64 = 0
    var tasks: [Task] = []
    func schedule(afterMilliseconds: UInt64, repeatingEveryMilliseconds: UInt64?, _ action: @escaping () -> Void) -> HIDRemoteScheduledTask {
        let task = Task(now + afterMilliseconds, repeatingEveryMilliseconds, action)
        tasks.append(task)
        return task
    }
    func advance(_ target: UInt64) {
        while let task = tasks.filter({ !$0.cancelled && $0.at <= target }).min(by: { $0.at < $1.at }) {
            now = task.at
            if let interval = task.repeatInterval { task.at += interval } else { task.cancelled = true }
            task.run()
        }
        now = target
    }
}
