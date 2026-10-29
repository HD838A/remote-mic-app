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

    @Test func persistenceIsPerDeviceAndBackupRoundTripsTimingAndModes() throws {
        let name = "SayAll.Interaction.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerBluetoothRemote(identifier: UUID())
        settings.selectRemoteProfile(first)
        settings.interactionSettings.doubleClickMilliseconds = 150
        settings.interactionSettings.longPressMilliseconds = 1000
        settings.setHoldMode(.holdSingle, for: .ok)
        let second = settings.registerBluetoothRemote(identifier: UUID())
        settings.selectRemoteProfile(second)
        settings.interactionSettings.doubleClickMilliseconds = 500
        settings.setHoldMode(.repeatLong, for: .menu)
        let restarted = AppSettings(defaults: defaults)
        restarted.selectRemoteProfile(first)
        #expect(restarted.interactionSettings.doubleClickMilliseconds == 150)
        #expect(restarted.interactionSettings.longPressMilliseconds == 1000)
        #expect(restarted.interactionSettings.mode(for: .ok) == .holdSingle)
        restarted.selectRemoteProfile(second)
        #expect(restarted.interactionSettings.doubleClickMilliseconds == 500)
        #expect(restarted.interactionSettings.mode(for: .menu) == .repeatLong)
        let data = try MacConfigurationBackup(host: restarted.completeConfigurationSnapshot(), components: nil).encoded(version: "2.0.0", build: "test")
        let backup = try MacConfigurationBackup.decode(data)
        let validated = try restarted.validatedCompleteConfigurationSnapshot(backup.host)
        try restarted.applyPortableLocalSnapshot(validated)
        #expect(restarted.interactionSettings.mode(for: .menu) == .repeatLong)
        #expect(restarted.interactionSettings.doubleClickMilliseconds == 500)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        object["schemaVersion"] = 1
        var requirements = try #require(object["requirements"] as? [String: String])
        requirements["reader"] = "sayall-macos-configuration/1"
        object["requirements"] = requirements
        #expect(throws: Never.self) { _ = try MacConfigurationBackup.decode(JSONSerialization.data(withJSONObject: object)) }
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
