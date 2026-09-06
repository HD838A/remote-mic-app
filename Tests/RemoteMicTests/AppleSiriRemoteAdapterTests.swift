import AppKit
import CoreGraphics
#if SAYALL_SIRI_REMOTE_ENABLED
import Foundation
import Testing
@testable import RemoteMic

@Suite("Apple Siri Remote A2854 adapter")
struct AppleSiriRemoteAdapterTests {
    private let device = RemoteHardwareDeviceIdentity(
        adapterID: "apple_siri_remote",
        instanceID: "test-device"
    )

    @Test func acceptsOnlyA2854ApprovedInterfaces() {
        for usagePage in [0x01, 0x0C, 0x0D, 0xFF00] {
            #expect(AppleSiriRemoteDeviceMatch.accepts(
                vendorID: 0x004C,
                productID: 0x0315,
                primaryUsagePage: usagePage
            ))
        }
        #expect(!AppleSiriRemoteDeviceMatch.accepts(
            vendorID: 0x004C,
            productID: 0x0314,
            primaryUsagePage: 0x0C
        ))
        #expect(!AppleSiriRemoteDeviceMatch.accepts(
            vendorID: 0x004C,
            productID: 0x0315,
            primaryUsagePage: 0x20
        ))
    }

    @Test func mapsKnownA2854Usages() {
        let expected: [((UInt32, UInt32), AppleSiriRemoteControl)] = [
            ((0x0C, 0x42), .up),
            ((0x0C, 0x43), .down),
            ((0x0C, 0x44), .left),
            ((0x0C, 0x45), .right),
            ((0x0C, 0x80), .select),
            ((0x0C, 0x224), .back),
            ((0x0C, 0x60), .tv),
            ((0x0C, 0x04), .siri),
            ((0x0C, 0xCD), .playPause),
            ((0x0C, 0xE9), .volumeUp),
            ((0x0C, 0xEA), .volumeDown),
            ((0x0C, 0xE2), .mute),
            ((0x0C, 0x30), .power),
        ]
        for entry in expected {
            #expect(AppleSiriRemoteControl.identify(
                usagePage: entry.0.0,
                usage: entry.0.1
            ) == entry.1)
        }
        #expect(AppleSiriRemoteControl.identify(usagePage: 0x20, usage: 0x01) == nil)
    }

    @Test func configurableMediaAndPowerControlsUseGenericButtonMappings() {
        #expect(AppleSiriRemoteControl.select.remoteButton == .ok)
        #expect(AppleSiriRemoteControl.playPause.remoteButton == .playPause)
        #expect(AppleSiriRemoteControl.mute.remoteButton == .mute)
        #expect(AppleSiriRemoteControl.power.remoteButton == .power)
        #expect(AppleSiriRemoteControl.siri.remoteButton == nil)
    }

    @Test func configurableSystemControlsExposeAllNativeEventsForSuppression() {
        #expect(AppleSiriRemoteControl.volumeDown.nativeEvents.contains(.systemKey(type: 1)))
        #expect(AppleSiriRemoteControl.playPause.nativeEvents.contains(.systemKey(type: 2)))
        #expect(AppleSiriRemoteControl.playPause.nativeEvents.contains(.systemKey(type: 16)))
        #expect(AppleSiriRemoteControl.mute.nativeEvents.contains(.systemKey(type: 3)))
        #expect(AppleSiriRemoteControl.mute.nativeEvents.contains(.systemKey(type: 7)))
        #expect(AppleSiriRemoteControl.power.nativeEvents.contains(.keyboard(keyCode: 90)))
        #expect(AppleSiriRemoteControl.power.nativeEvents.contains(.systemKey(type: 6)))
    }

    @Test func appleControlCandidatesSuppressTheirObservedNativeEdges() throws {
        for (control, nativeEvent) in [
            (AppleSiriRemoteControl.volumeDown, RemoteNativeEvent.systemKey(type: 1)),
            (.playPause, .systemKey(type: 16)),
            (.mute, .systemKey(type: 7)),
            (.power, .keyboard(keyCode: 90)),
        ] {
            let suppressor = KeyboardEventSuppressor()
            let down = try nativeEventValue(nativeEvent, edge: .down)
            let up = try nativeEventValue(nativeEvent, edge: .up)

            suppressor.arm(nativeEvents: control.nativeEvents, edge: .down)
            #expect(suppressor.handle(type: down.type, event: down.event))
            suppressor.arm(nativeEvents: control.nativeEvents, edge: .up)
            #expect(suppressor.handle(type: up.type, event: up.event))
        }
    }

    @Test func runtimeUsesPhysicalControlIDsForHighlightAndSuppressesNativeEvents() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(modelSource.contains(
            "hidEventSuppressor.arm(nativeEvents: control.nativeEvents, edge: nativeEdge)"
        ))
        #expect(!modelSource.contains("APPLE REMOTE SYSTEM_ACTION"))
        #expect(settingsSource.contains(
            "activeControlIDs: model.activeAppleRemoteControlIDs"
        ))
        #expect(settingsSource.contains(
            "voiceActive: model.activeAppleRemoteControlIDs.contains(\"siri\")"
        ))
    }

    @Test func treatsEveryNonzeroHIDValueAsPressed() {
        #expect(!AppleSiriRemoteAdapter.isPressed(integerValue: 0))
        #expect(AppleSiriRemoteAdapter.isPressed(integerValue: 1))
        #expect(AppleSiriRemoteAdapter.isPressed(integerValue: 2))
        #expect(AppleSiriRemoteAdapter.isPressed(integerValue: -1))
    }

    @Test func centralTouchMovesPointer() {
        var interpreter = AppleSiriRemoteTouchInterpreter()
        #expect(interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 1)).isEmpty)
        let outputs = interpreter.handle(event(.changed, x: 0.54, y: 0.52, time: 1.05))
        guard case let .move(deltaX, deltaY) = outputs.first else {
            Issue.record("Expected central touch movement")
            return
        }
        #expect(deltaX > 0)
        #expect(deltaY < 0)
    }

    @Test func circularTouchWaitsForThresholdAndUsesInitialInversion() {
        var interpreter = AppleSiriRemoteTouchInterpreter()
        #expect(interpreter.handle(circularEvent(.began, angle: 0, time: 1)).isEmpty)
        #expect(interpreter.handle(circularEvent(.changed, angle: 0.08, time: 1.02)).isEmpty)
        let outputs = interpreter.handle(circularEvent(.changed, angle: 0.28, time: 1.04))
        guard case let .scroll(pixels) = outputs.first else {
            Issue.record("Expected circular scroll after threshold")
            return
        }
        #expect(pixels < 0)
    }

    @Test func shortStationaryTouchClicks() {
        var interpreter = AppleSiriRemoteTouchInterpreter()
        #expect(interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 1)).isEmpty)
        #expect(interpreter.handle(event(.ended, contacts: [], time: 1.15)) == [.click])
    }

    @Test func physicalSurfacePressSuppressesTouchOutputUntilContactEnds() {
        var interpreter = AppleSiriRemoteTouchInterpreter()
        #expect(interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 1)).isEmpty)
        interpreter.suppressCurrentContact()
        #expect(interpreter.handle(event(.changed, x: 0.58, y: 0.5, time: 1.04)).isEmpty)
        #expect(interpreter.handle(event(.ended, contacts: [], time: 1.1)).isEmpty)

        #expect(interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 2)).isEmpty)
        #expect(interpreter.handle(event(.ended, contacts: [], time: 2.1)) == [.click])
    }

    @Test func voiceSessionSuppressesTheCurrentTouchContactUntilItEnds() {
        var interpreter = AppleSiriRemoteTouchInterpreter()
        #expect(interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 1)).isEmpty)
        interpreter.suppressCurrentContact()
        #expect(interpreter.handle(event(.changed, x: 0.62, y: 0.5, time: 1.04)).isEmpty)
        #expect(interpreter.handle(event(.ended, contacts: [], time: 1.1)).isEmpty)

        #expect(interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 2)).isEmpty)
        #expect(interpreter.handle(event(.ended, contacts: [], time: 2.1)) == [.click])
    }

    @Test func voiceAndTailDrainBothBlockTouch() {
        #expect(!AppleRemoteInteractionPolicy.blocksTouch(
            activeVoiceDeviceCount: 0,
            voiceStopping: false
        ))
        #expect(AppleRemoteInteractionPolicy.blocksTouch(
            activeVoiceDeviceCount: 1,
            voiceStopping: false
        ))
        #expect(AppleRemoteInteractionPolicy.blocksTouch(
            activeVoiceDeviceCount: 0,
            voiceStopping: true
        ))
    }

    @Test func holdRepeatMatchesRC001AndRC003TimingAndGestureRules() {
        let otherApp = PresetApplication.codex.bundleIdentifier
        #expect(AppleRemoteInteractionPolicy.repeatIntervalMilliseconds(
            for: .back,
            action: .deleteBackward,
            hasSecondaryAction: false,
            hasSingleActionOverride: false,
            frontmostBundleIdentifier: otherApp
        ) == 50)
        #expect(AppleRemoteInteractionPolicy.repeatIntervalMilliseconds(
            for: .left,
            action: .arrowLeft,
            hasSecondaryAction: false,
            hasSingleActionOverride: false,
            frontmostBundleIdentifier: otherApp
        ) == 100)
        #expect(AppleRemoteInteractionPolicy.repeatIntervalMilliseconds(
            for: .volumeDown,
            action: .volumeDown,
            hasSecondaryAction: false,
            hasSingleActionOverride: false,
            frontmostBundleIdentifier: otherApp
        ) == 100)
        #expect(AppleRemoteInteractionPolicy.repeatIntervalMilliseconds(
            for: .back,
            action: .deleteBackward,
            hasSecondaryAction: true,
            hasSingleActionOverride: false,
            frontmostBundleIdentifier: otherApp
        ) == nil)
        #expect(AppleRemoteInteractionPolicy.repeatIntervalMilliseconds(
            for: .back,
            action: .customShortcut,
            hasSecondaryAction: false,
            hasSingleActionOverride: false,
            frontmostBundleIdentifier: otherApp
        ) == nil)
        #expect(AppleRemoteInteractionPolicy.repeatIntervalMilliseconds(
            for: .back,
            action: .deleteBackward,
            hasSecondaryAction: false,
            hasSingleActionOverride: true,
            frontmostBundleIdentifier: otherApp
        ) == nil)
        #expect(AppleRemoteInteractionPolicy.repeatIntervalMilliseconds(
            for: .back,
            action: .deleteBackward,
            hasSecondaryAction: false,
            hasSingleActionOverride: false,
            frontmostBundleIdentifier: PresetApplication.remoteMic.bundleIdentifier
        ) == nil)
    }

    @Test func cancellationResetsTouchState() {
        var interpreter = AppleSiriRemoteTouchInterpreter()
        _ = interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 1))
        _ = interpreter.handle(event(.changed, x: 0.6, y: 0.5, time: 1.05))
        #expect(interpreter.handle(event(.cancelled, contacts: [], time: 1.1)).isEmpty)
        #expect(interpreter.handle(event(.began, x: 0.5, y: 0.5, time: 2)).isEmpty)
        #expect(interpreter.handle(event(.ended, contacts: [], time: 2.1)) == [.click])
    }

    @Test func profileModelKeepsRawValueCodableCompatibility() throws {
        let encoded = try JSONEncoder().encode(XiaomiRemoteModel.appleSiriRemoteA2854)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"apple_siri_remote_a2854\"")
        #expect(try JSONDecoder().decode(XiaomiRemoteModel.self, from: encoded)
            == .appleSiriRemoteA2854)
        #expect(try JSONDecoder().decode(
            XiaomiRemoteModel.self,
            from: Data("\"rc003\"".utf8)
        ) == .rc003)
    }

    @Test func appleRegistrationDoesNotReuseBluetoothRemoteProfile() throws {
        let suiteName = "AppleSiriRemoteAdapterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let bluetoothIdentifier = UUID()
        let bluetoothProfileID = settings.registerBluetoothRemote(
            identifier: bluetoothIdentifier
        )

        let appleProfileID = settings.registerAppleSiriRemote(fingerprint: "apple-test")

        #expect(appleProfileID != bluetoothProfileID)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == bluetoothProfileID })?
            .bluetoothIdentifier == bluetoothIdentifier)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == bluetoothProfileID })?
            .model == .unknown)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == appleProfileID })?
            .model == .appleSiriRemoteA2854)
    }

    private func event(
        _ phase: RemoteHardwareTouchPhase,
        x: Double = 0,
        y: Double = 0,
        contacts: [RemoteHardwareTouchContact]? = nil,
        time: TimeInterval
    ) -> RemoteHardwareTouchEvent {
        RemoteHardwareTouchEvent(
            device: device,
            phase: phase,
            contacts: contacts ?? [RemoteHardwareTouchContact(
                identifier: 1,
                normalizedX: x,
                normalizedY: y,
                contactSize: nil
            )],
            timestampUptime: time,
            sequence: UInt64(time * 100)
        )
    }

    private func circularEvent(
        _ phase: RemoteHardwareTouchPhase,
        angle: Double,
        time: TimeInterval
    ) -> RemoteHardwareTouchEvent {
        let radius = 0.4
        return event(
            phase,
            x: 0.5 + radius * cos(angle),
            y: 0.5 + radius * sin(angle),
            time: time
        )
    }

    private func nativeEventValue(
        _ nativeEvent: RemoteNativeEvent,
        edge: RemoteEventEdge
    ) throws -> (type: CGEventType, event: CGEvent) {
        switch nativeEvent {
        case let .keyboard(keyCode):
            let isDown = edge == .down
            let event = try #require(CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: isDown
            ))
            return (isDown ? .keyDown : .keyUp, event)
        case let .systemKey(systemKeyType):
            let keyState: Int32 = edge == .down ? 0xA : 0xB
            let data1 = Int((systemKeyType << 16) | (keyState << 8))
            let event = try #require(NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent)
            return (try #require(CGEventType(rawValue: 14)), event)
        }
    }
}
#endif
