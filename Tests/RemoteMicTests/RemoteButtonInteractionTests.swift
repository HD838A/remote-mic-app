import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Configurable button interactions", .serialized)
@MainActor
struct RemoteButtonInteractionTests {
    private func snapshot(_ mode: RemoteButtonHoldMode = .once, double: Bool = false,
                          long: Bool = false, d: Int = 300, l: Int = 550,
                          single: ButtonAction = .deleteBackward) -> RemoteButtonInteractionSnapshot {
        .init(settings: .init(doubleClickMilliseconds: d, longPressMilliseconds: l), mode: mode,
              single: .init(action: single, shortcut: nil),
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

    @Test func learningStartCancellationStopsRepeats() {
        let clock = InteractionClock()
        let repeating = RemoteButtonInteractionController(scheduler: clock)
        var repeatCount = 0
        repeating.handle(.press, button: .back, snapshot: snapshot(.repeatSingle), valid: { true }) { _, _ in
            repeatCount += 1
            return true
        }

        repeating.cancelAll(reason: "learning_started")
        let countAfterCancellation = repeatCount
        clock.advance(2_000)

        #expect(repeatCount == countAfterCancellation)
    }

    @Test func invalidModeAndConflictingGesturesNeverFallBack() {
        let clock = InteractionClock()
        let controller = RemoteButtonInteractionController(scheduler: clock)
        var count = 0
        for config in [snapshot(.repeatSingle, long: true), snapshot(d: 49),
                       RemoteButtonInteractionSnapshot(settings: .init(), mode: nil,
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
        #expect(second.interactionSnapshot(for: .back).mode == nil)
        #expect(second.interactionSnapshot(for: .back).unavailableReason != nil)
        second.interactionModeOverride = { _, _ in "unknown" }
        #expect(second.interactionSnapshot(for: .back).unavailableReason != nil)
        second.interactionModeOverride = nil
        second.setHoldMode(.once, for: .back)
        #expect(second.interactionSettings.migratedRepeatButtons?.contains("back") == false)
        #expect(second.interactionSnapshot(for: .back).mode == .once)
        let cleared = AppSettings(defaults: defaults)
        #expect(cleared.interactionSettings.modes["back"] == "once")
        second.interactionSettings.modes["back"] = "unknown"
        second.interactionSettings.migratedRepeatButtons = ["back"]
        second.setAction(.arrowLeft, for: .back, trigger: .longPress)
        #expect(second.interactionSnapshot(for: .back).unavailableReason != nil)
    }

    @Test func holdDefaultOnlyRaisesAnUnsetEligibleButton() {
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot()) == .repeatSingle)
        // A double press does not block repeat single; it still blocks repeat long only.
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot(double: true)) == .repeatSingle)
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot(long: true)) == nil)
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot(single: .appSwitcher)) == nil)
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot(single: .disabled)) == nil)
        // Out-of-range timing must not be "fixed" into a saved mode.
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot(d: 49)) == nil)
    }

    @Test func holdDefaultNeverRewritesAChoiceOrAnInheritedMode() {
        // A cleared button keeps its clear marker and must not regain the default.
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: .once, snapshot: snapshot()) == nil)
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: .repeatLong, snapshot: snapshot(long: true)) == nil)
        // A saved repeat-single that conflicts with a new long press degrades in the
        // runtime snapshot only; storage must stay repeatSingle so it resumes by itself.
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: .repeatSingle, snapshot: snapshot(.repeatSingle, long: true)) == nil)
        // A mode inherited from the base buttons is not this scope's to rewrite.
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot(.repeatSingle, long: true)) == nil)
        #expect(RemoteButtonHoldModeDefault.storedMode(
            explicit: nil, snapshot: snapshot(.repeatLong, long: true)) == nil)
    }

    @Test func changingAnActionClearsAHoldChoiceItCanNoLongerRun() throws {
        let name = "SayAll.HoldConflict.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let profileID = try #require(settings.selectedRemoteProfileID)
        let singleBefore = settings.interactionSnapshot(for: .ok).single
        settings.setHoldMode(.repeatSingle, for: .ok)

        // A completed edit goes through `setBaseBinding`, exactly like the settings page.
        settings.setBaseBinding(
            ConfiguredButtonAction(action: .arrowLeft, shortcut: nil),
            for: .ok,
            trigger: .longPress,
            profileID: profileID
        )

        // The saved choice is dropped back to "unset" instead of becoming a paused state.
        #expect(settings.interactionSettings.modes["ok"] == "once")
        #expect(settings.interactionSnapshot(for: .ok).mode == .once)
        #expect(settings.interactionSnapshot(for: .ok).unavailableReason == nil)

        // The button keeps working: the click stays live, next to the new long press.
        #expect(settings.interactionSnapshot(for: .ok).single == singleBefore)
        #expect(settings.interactionSnapshot(for: .ok).long.action == .arrowLeft)

        let restarted = AppSettings(defaults: defaults)
        #expect(restarted.interactionSnapshot(for: .ok).mode == .once)

        // Removing the conflict does not silently restore the old choice; the user picks again.
        settings.setBaseBinding(
            .disabled, for: .ok, trigger: .longPress, profileID: profileID
        )
        #expect(settings.interactionSnapshot(for: .ok).mode == .once)
    }

    @Test func changingTheModelSeedsTheNewModelTimingFromTheLegacyFieldsOnce() throws {
        let name = "SayAll.ModelTiming.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let device = settings.registerBluetoothRemote(identifier: UUID())
        settings.selectRemoteProfile(device)
        settings.interactionSettings.timing = RemoteButtonGestureTiming(
            doubleClickMilliseconds: 200,
            longPressMilliseconds: 900
        )
        settings.updateRemoteProfileModel(device, model: .rc003)
        #expect(settings.buttonGestureTiming(for: .rc003) == .init(
            doubleClickMilliseconds: 200,
            longPressMilliseconds: 900
        ))
        settings.setButtonGestureTiming(.init(
            doubleClickMilliseconds: 350,
            longPressMilliseconds: 700
        ), for: .rc003)
        settings.updateRemoteProfileModel(device, model: .rc001)
        // A model without a saved entry seeds from the legacy fields and never steals rc003.
        #expect(settings.buttonGestureTiming(for: .rc001) == .init(
            doubleClickMilliseconds: 200,
            longPressMilliseconds: 900
        ))
        #expect(settings.buttonGestureTiming(for: .rc003) == .init(
            doubleClickMilliseconds: 350,
            longPressMilliseconds: 700
        ))
    }

    @Test func invalidHoldModesAndTimingsAreRejectedOnImportWithoutChangingTheRest() throws {
        let name = "SayAll.InteractionImport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.setHoldMode(.repeatSingle, for: .back)
        settings.setButtonGestureTiming(.init(
            doubleClickMilliseconds: 150,
            longPressMilliseconds: 1_000
        ), for: .rc003)

        var object = try #require(
            JSONSerialization.jsonObject(with: settings.exportedConfigurationData()) as? [String: Any]
        )
        var interactionSettings = try #require(object["interactionSettings"] as? [String: Any])
        interactionSettings["modes"] = ["back": "unknown"]
        object["interactionSettings"] = interactionSettings
        object["buttonGestureTimingsByModel"] = [
            XiaomiRemoteModel.rc003.rawValue: [
                "doubleClickMilliseconds": 49,
                "longPressMilliseconds": 1_000,
            ],
        ]
        try settings.importConfiguration(from: JSONSerialization.data(withJSONObject: object))

        let rejected = try #require(settings.configurationImportNotice?.rejectedEntryStorageKeys)
        #expect(rejected.contains("interactionSettings"))
        #expect(rejected.contains("buttonGestureTimingsByModel"))
        #expect(settings.buttonGestureTiming(for: .rc003) == .init(
            doubleClickMilliseconds: 150,
            longPressMilliseconds: 1_000
        ))
        #expect(settings.configuredBaseAction(for: .back, trigger: .singleClick).action != .disabled)
    }

    @Test func removedRawHoldModeDecodesWhileExplicitClearPersists() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "doubleClickMilliseconds": 300,
            "longPressMilliseconds": 550,
            "modes": [
                "back": "holdSingle",
                "right": "once",
                "left": "repeatSingle",
            ],
        ])
        let decoded = try JSONDecoder().decode(RemoteButtonInteractionSettings.self, from: data)
        #expect(decoded.modes == ["right": "once", "left": "repeatSingle"])
        #expect(decoded.mode(for: .back) == .once)
        #expect(decoded.mode(for: .right) == .once)
    }

    @Test func unrecordedShortcutNeverReadsAsABinding() throws {
        let name = "SayAll.UnrecordedShortcut.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let profileID = settings.selectedRemoteProfileID

        // Choosing the action without recording keys must not produce a usable binding.
        settings.setAction(.customShortcut, for: .power)
        settings.setAction(.customShortcut, for: .power, trigger: .longPress)
        #expect(settings.configuredAction(for: .power, trigger: .singleClick, profileID: profileID).action
            == .disabled)
        #expect(settings.configuredAction(for: .power, trigger: .longPress, profileID: profileID).action
            == .disabled)

        // Once keys exist the same action becomes a real binding again.
        settings.setShortcut(
            CustomKeyboardShortcut(keyCode: 40, modifierFlags: [.command], keyLabel: "K"),
            for: .power
        )
        #expect(settings.configuredAction(for: .power, trigger: .singleClick, profileID: profileID).action
            == .customShortcut)
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
        settings.setHoldMode(.repeatLong, for: .ok)
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
        settings.setHoldMode(.repeatSingle, for: .ok)
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
        #expect(restarted.interactionSettings.mode(for: .ok) == .repeatSingle)
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

    @Test func learningDiscardsImpossibleDoubleClickIntervals() {
        var learner = RemoteButtonGestureLearner()
        learner.start(model: .rc003)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_000)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_284)
        #expect(learner.status.step == .doubleClick)

        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_300)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_400)

        // 真机现场：松手后 1 ms 又收到一次按下，手指不可能完成。
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_401)
        #expect(learner.status.doubleClickMilliseconds == nil)
        #expect(learner.status.step == .doubleClick)
        #expect(learner.status.discardedDoubleClickEdges == 1)

        // 用户真正的第二下仍能测出来：重复边沿整对被忽略，双击计数保持不变，
        // 间隔仍从第一次松手（1 400）算起。
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_450)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_570)
        #expect(learner.status.doubleClickMilliseconds == 170)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_620)
        #expect(learner.status.step == .longPress)
    }

    @Test func learningRejectsOutOfOrderDoubleClickTimestampsInsteadOfRecordingZero() {
        var learner = RemoteButtonGestureLearner()
        learner.start(model: .rc003)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_000)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_284)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_300)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_400)

        // 排队让第二次按下的时间戳早于上一次松手：旧实现 max(0, …) 会写成 0 ms。
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_200)
        #expect(learner.status.doubleClickMilliseconds == nil)
        #expect(learner.status.discardedDoubleClickEdges == 1)
        #expect(learner.status.step == .doubleClick)
    }

    @Test func learningAbsorbsBouncedEdgesWithoutSkippingTheDoubleClickStep() {
        var learner = RemoteButtonGestureLearner()
        learner.start(model: .rc003)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_000)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_284)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_300)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_400)

        // 一次按压被报告层拆成两对边沿，两对都要被吸收，不能推进到长按。
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_401)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_405)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_410)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_415)
        #expect(learner.status.doubleClickMilliseconds == nil)
        #expect(learner.status.discardedDoubleClickEdges == 2)
        #expect(learner.status.step == .doubleClick)

        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_515)
        #expect(learner.status.doubleClickMilliseconds == 115)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_560)
        #expect(learner.status.step == .longPress)
    }

    @Test func learningIgnoresBouncedEdgesThatLandOnTheLongPressStep() {
        var learner = RemoteButtonGestureLearner()
        learner.start(model: .rc003)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_000)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_200)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_300)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_350)
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_450)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_500)
        #expect(learner.status.doubleClickMilliseconds == 100)
        #expect(learner.status.step == .longPress)

        // 第二下之后跟着的重复边沿：它不是用户的长按，不能结束学习。
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_501)
        _ = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 1_502)
        #expect(learner.status.longPressMilliseconds == nil)
        #expect(learner.status.step == .longPress)
        #expect(learner.status.discardedLongPressEdges == 1)

        // 用户照常做一次长按即可完成，不需要从头重新学习。
        _ = learner.handle(.press, button: .ok, model: .rc003, timestampMilliseconds: 1_700)
        let result = learner.handle(.release, button: .ok, model: .rc003, timestampMilliseconds: 2_450)
        #expect(result?.longPressMilliseconds == 750)
        #expect(learner.status.step == .complete)
    }

    @Test func doubleClickWindowAllowsFiftyMilliseconds() {
        #expect(RemoteButtonGestureTiming(doubleClickMilliseconds: 50, longPressMilliseconds: 550).isValid)
        #expect(RemoteButtonGestureTiming(doubleClickMilliseconds: 500, longPressMilliseconds: 550).isValid)
        #expect(!RemoteButtonGestureTiming(doubleClickMilliseconds: 0, longPressMilliseconds: 550).isValid)
        #expect(!RemoteButtonGestureTiming(doubleClickMilliseconds: 25, longPressMilliseconds: 550).isValid)
    }

    @Test func holdBlockersNameTheActionThatBlocksEachMode() {
        // Repeatable click plus a long press that never recorded keys: the power-button case.
        let power = RemoteButtonInteractionSnapshot(
            settings: .init(),
            mode: .once,
            single: .init(action: .deleteBackward, shortcut: nil),
            double: .disabled,
            long: .init(action: .customShortcut, shortcut: nil)
        )
        #expect(power.blockers(for: .repeatSingle)
            == [.longPressConfigured(.init(action: .customShortcut, shortcut: nil))])
        #expect(power.blockers(for: .repeatLong) == [.actionUnset])
        #expect(power.blockers(for: .once).isEmpty)

        // A click that launches an app cannot repeat, and no long press is set: the home-button case.
        let home = RemoteButtonInteractionSnapshot(
            settings: .init(),
            mode: .once,
            single: .init(action: .openCustomApplication, shortcut: nil),
            double: .disabled,
            long: .disabled
        )
        #expect(home.blockers(for: .repeatSingle)
            == [.actionNotRepeatable(.init(action: .openCustomApplication, shortcut: nil))])
        #expect(home.blockers(for: .repeatLong) == [.actionUnset])
    }

    @Test func holdBlockersAgreeWithTheRuntimeAvailabilityGate() {
        let power = RemoteButtonInteractionSnapshot(
            settings: .init(), mode: .once,
            single: .init(action: .deleteBackward, shortcut: nil),
            double: .disabled,
            long: .init(action: .customShortcut, shortcut: nil)
        )
        var opaque = snapshot()
        opaque.hasOpaqueBinding = true
        let cases = [snapshot(), snapshot(long: true), snapshot(single: .appSwitcher), power, opaque]
        for config in cases {
            for mode in RemoteButtonHoldMode.selectableCases {
                let candidate = config.withMode(mode)
                #expect(candidate.blockers(for: mode).isEmpty
                    == (candidate.unavailableReason == nil))
            }
        }
        #expect(opaque.blockers(for: .repeatLong) == [.profileOwned])
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
