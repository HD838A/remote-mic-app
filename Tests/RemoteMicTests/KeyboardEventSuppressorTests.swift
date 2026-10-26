import AppKit
import Foundation
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Keyboard event suppressor")
struct KeyboardEventSuppressorTests {
    @Test(arguments: [RemoteNativeEvent.systemKey(type: 0), .systemKey(type: 1), .systemKey(type: 16), .keyboard(keyCode: 115), .keyboard(keyCode: 36)])
    func delayedNativePairRemainsOwnedAfterRemoteRelease(_ native: RemoteNativeEvent) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.14
        #expect(suppressor.handle(type: down.type, event: down))
        now += 0.001
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func releasingRemoteDoesNotDiscardAnUnconsumedEarlyDown() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .systemKey(type: 0)
        let down = try nativeEvent(native, down: true)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.08
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.01
        #expect(suppressor.handle(type: down.type, event: down))
    }

    @Test func missingNativeEdgesExpireWithoutBlockingPhysicalInput() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .keyboard(keyCode: 115)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.501
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func overlappingClicksConsumeOnlyTheirExpectedEdges() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .systemKey(type: 1)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now = 10.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now = 10.29
        suppressor.arm(nativeEvents: [native], edge: .down)
        now = 10.30
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(suppressor.handle(type: up.type, event: up))
        now = 10.46
        suppressor.arm(nativeEvents: [native], edge: .up)
        now = 10.60
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test func nativeUpCanArriveBeforeDelayedDown() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .keyboard(keyCode: 115)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.14
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test(arguments: [RemoteNativeEvent.systemKey(type: 0), .systemKey(type: 1), .systemKey(type: 16), .keyboard(keyCode: 115)])
    func nativeReleaseBeforeHIDReleaseClosesOnlyTheOwnedPair(_ native: RemoteNativeEvent) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        now += 0.17
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: up.type, event: up))
        now += 0.013
        suppressor.arm(nativeEvents: [native], edge: .up)
        // The late raw release must not leave another native-up allowance.
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    @Test func unownedNativeReleaseIsNeverClaimedByRawHoldAlone() throws {
        let native: RemoteNativeEvent = .systemKey(type: 1)
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { _ in })
        suppressor.arm(nativeEvents: [native], edge: .down)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: up.type, event: up))
        let down = try nativeEvent(native, down: true)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.stop()
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func releasedOwnershipCannotClaimTheNextPressWithoutANativeDown() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .systemKey(type: 1)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.501
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func earlyDownDiagnosticDoesNotRetroactivelyConsumeInput() throws {
        var now: TimeInterval = 10
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        let down = try nativeEvent(.keyboard(keyCode: 115), down: true)
        #expect(!suppressor.handle(type: down.type, event: down))
        now += 0.079
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 115)], edge: .down)
        #expect(logs.contains { $0.contains("phase=arm_order") && $0.contains("source_correlation=timing_only") })
        logs.removeAll()
        now += 0.501
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 115)], edge: .down)
        #expect(!logs.contains { $0.contains("phase=arm_order") })
    }

    @Test(arguments: [Int32(0), Int32(1)], [false, true])
    func escapedVolumeDownKeepsItsReleaseAndDoesNotStealTheNextPress(
        _ keyType: Int32, _ nativeReleaseFirst: Bool
    ) throws {
        var now: TimeInterval = 10
        let native: RemoteNativeEvent = .systemKey(type: keyType)
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        // Replay the recorded native down -> HID down -> HID up -> native up.
        #expect(!suppressor.handle(type: down.type, event: down))
        now += 0.011
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.15
        if nativeReleaseFirst {
            #expect(!suppressor.handle(type: up.type, event: up))
            suppressor.arm(nativeEvents: [native], edge: .up)
        } else {
            suppressor.arm(nativeEvents: [native], edge: .up)
            #expect(!suppressor.handle(type: up.type, event: up))
        }
        #expect(logs.filter { $0.contains("phase=arm result=passthrough") }.count == 2)
        #expect(logs.contains { $0.contains("edge=up reason=escaped_native_pair") })
        // No stale expected down may consume the following physical volume key.
        now += 0.25
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func escapedVolumeHoldPassesRepeatsAndReleaseBeyondTheDeliveryWindow(_ keyType: Int32) throws {
        var now: TimeInterval = 10
        let native: RemoteNativeEvent = .systemKey(type: keyType)
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: down.type, event: down))
        now += 0.011
        suppressor.arm(nativeEvents: [native], edge: .down)
        for _ in 0..<5 {
            now += 0.2
            #expect(!suppressor.handle(type: down.type, event: down))
        }
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(!suppressor.handle(type: up.type, event: up))
        // Once the escaped pair closes, normally ordered remote input is filtered.
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [RemoteButton.volumeUp, .volumeDown, .tv], [false, true])
    func managedNativeKeysAreArmedBeforeReportDiagnosticsAndConfigurationCallbacks(
        _ button: RemoteButton, _ isSeized: Bool
    ) throws {
        let suite = "KeyboardEventSuppressorTests.earlyVolume.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.customShortcut, for: button)
        settings.setShortcut(CustomKeyboardShortcut(keyCode: 43, modifierFlags: [], keyLabel: ","), for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        let profile = try #require(settings.selectedRemoteProfileID)
        let native = try #require(button.nativeEvents.first)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var deliveredNativeDown = false
        var performed: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings, profileID: profile, eventSuppressor: suppressor,
            ownsEventSuppressor: false, runtimePermissions: { true },
            actionPerformer: { _, _, configured in performed.append(configured.action); return true },
            diagnosticLogger: { message in
                if message.contains("HID REPORT accepted"), !deliveredNativeDown {
                    deliveredNativeDown = true
                    #expect(suppressor.handle(type: down.type, event: down))
                }
            }
        )
        monitor.connectSimulatedDevice(fingerprint: "volume-early-arm", profileID: profile, isSeized: isSeized)
        defer { monitor.disconnectSimulatedDevice() }
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        #expect(deliveredNativeDown)
        #expect(performed == [.customShortcut])
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [RemoteButton.volumeUp, .volumeDown, .tv], [false, true])
    func sourceNeutralizedKeysDoNotLeaveCreditsThatConsumePhysicalKeyboardInput(
        _ button: RemoteButton, _ disconnectWhileHeld: Bool
    ) throws {
        let suite = "KeyboardEventSuppressorTests.sourceNeutralized.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.customShortcut, for: button)
        settings.setShortcut(CustomKeyboardShortcut(keyCode: 43, modifierFlags: [], keyLabel: ","), for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        settings.setAllowsRapidPress(true, for: button)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var performed = 0
        let monitor = HIDRemoteMonitor(
            settings: settings, eventSuppressor: suppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in performed += 1; return true },
            diagnosticLogger: { _ in }, prepareNativeKeys: { true }
        )
        monitor.connectSimulatedDevice(
            fingerprint: "neutralized-remote", profileID: settings.selectedRemoteProfileID
        )
        for _ in 0..<10 {
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
            for native in button.nativeEvents {
                let down = try nativeEvent(native, down: true)
                #expect(!suppressor.handle(type: down.type, event: down))
            }
            monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
            for native in button.nativeEvents {
                let up = try nativeEvent(native, down: false)
                #expect(!suppressor.handle(type: up.type, event: up))
            }
        }
        #expect(performed == 10)
        if disconnectWhileHeld {
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        }
        monitor.disconnectSimulatedDevice()
        for native in button.nativeEvents {
            let up = try nativeEvent(native, down: false)
            #expect(!suppressor.handle(type: up.type, event: up))
        }
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func stoppingClearsEscapedVolumeOwnership(_ keyType: Int32) throws {
        let native: RemoteNativeEvent = .systemKey(type: keyType)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.stop()
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    private func nativeEvent(_ native: RemoteNativeEvent, down: Bool) throws -> CGEvent {
        switch native {
        case let .keyboard(keyCode):
            return try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
        case let .systemKey(type):
            let data = Int((type << 16) | ((down ? 0xA : 0xB) << 8))
            let event = try #require(NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1
            ))
            return try #require(event.cgEvent)
        }
    }

    @Test func expiredWindowStopsOrdinaryMissLogsWithoutSuppressingInput() throws {
        var now: TimeInterval = 10
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        let ordinary = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: true))
        #expect(!suppressor.handle(type: .keyDown, event: ordinary))
        #expect(logs.filter { $0.contains("HID FILTER miss") }.count == 1)
        logs.removeAll()
        now = 11
        for _ in 0..<100 {
            #expect(!suppressor.handle(type: .keyDown, event: ordinary))
        }
        #expect(logs.isEmpty)
    }

    @Test func matchingEdgesAreFilteredAndStopClearsDiagnosticState() throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { logs.append($0) })
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: false))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        #expect(suppressor.handle(type: .keyDown, event: down))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .up)
        #expect(suppressor.handle(type: .keyUp, event: up))
        suppressor.stop()
        logs.removeAll()
        #expect(!suppressor.handle(type: .keyDown, event: down))
        #expect(logs.isEmpty)
    }

    @Test func syntheticInputBypassesFilterWithoutConsumingPendingEdge() throws {
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { _ in })
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        #expect(!suppressor.handle(type: .keyDown, event: event))
        let realEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        #expect(suppressor.handle(type: .keyDown, event: realEvent))
    }

    @Test func activeArmWindowIncludesOnlyUnexpiredEntries() {
        let event: RemoteNativeEvent = .keyboard(keyCode: 42)

        #expect(
            KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 9.999
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 10
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 11
            )
        )
    }

    @Test func activeWindowIgnoresExpiredEntriesWhenAnotherEntryRemains() {
        let expired: RemoteNativeEvent = .keyboard(keyCode: 42)
        let active: RemoteNativeEvent = .systemKey(type: 2)

        #expect(
            KeyboardEventSuppressor.hasActiveArmedWindow(
                [
                    (event: expired, until: 10),
                    (event: active, until: 12),
                ],
                now: 11
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [
                    (event: expired, until: 10),
                    (event: active, until: 12),
                ],
                now: 12
            )
        )
    }
}
