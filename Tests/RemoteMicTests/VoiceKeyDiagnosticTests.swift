import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice key diagnostic boundaries")
struct VoiceKeyDiagnosticTests {
    @Test func remoteVoiceUsageDiagnosticsAreEdgeBoundedAndDoNotPerformActions() throws {
        let suite = "VoiceKeyDiagnosticTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        var lines: [String] = []
        var actionCount = 0
        let monitor = HIDRemoteMonitor(
            settings: settings,
            ownsEventSuppressor: false,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in actionCount += 1; return true },
            diagnosticLogger: { lines.append($0) }
        )
        #expect(monitor.connectSimulatedDevice(
            fingerprint: "diagnostic-fixture", profileID: settings.selectedRemoteProfileID
        ))
        for usage: UInt8 in [0x3E, 0x0C, 0x04] {
            let report = Data([usage, 0, 0, 0, 0, 0])
            monitor.handleSimulatedReport(reportID: 1, data: report)
            monitor.handleSimulatedReport(reportID: 1, data: report)
            monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        }
        let observations = lines.filter { $0.hasPrefix("HID VOICE_USAGE") }
        #expect(observations.count == 4)
        #expect(observations[0].contains("source_kind=f5 edge=down"))
        #expect(observations[1].contains("source_kind=f5 edge=up"))
        #expect(observations[2].contains("source_kind=letter_i edge=down"))
        #expect(observations[3].contains("source_kind=letter_i edge=up"))
        #expect(observations.allSatisfy { $0.contains("system_fn_delivery=unknown") })
        #expect(!observations.joined().contains("diagnostic-fixture"))
        #expect(actionCount == 0)
    }

    @Test func buildIdentityUsesOnlyValidatedPackagedMetadata() {
        let revision = String(repeating: "a", count: 40)
        let fields = AppEnvironmentSnapshot.buildIdentityFields([
            "SayAllSourceCommit": revision,
            "SayAllBuildChannel": "release",
            "SayAllPrivatePlatformVersion": "2.8.1",
            "SayAllSourceDirty": false,
            "unrelated": "private-value",
        ])
        #expect(fields == "source_revision=\(revision) build_channel=release " +
            "source_dirty=false private_platform_version=2.8.1")
        #expect(!fields.contains("private-value"))
    }

    @Test func missingOrMalformedBuildIdentityRemainsUnknown() {
        let expected = "source_revision=unknown build_channel=unknown " +
            "source_dirty=unknown private_platform_version=unknown"
        #expect(AppEnvironmentSnapshot.buildIdentityFields([:]) == expected)
        #expect(AppEnvironmentSnapshot.buildIdentityFields([
            "SayAllSourceCommit": String(repeating: "a", count: 40) + "\n",
            "SayAllBuildChannel": "release\nprivate-value",
            "SayAllPrivatePlatformVersion": "2.8.1\nprivate-value",
        ]) == expected)
    }

    @Test func writeSuccessAndReadbackMismatchRemainDistinct() {
        var lines: [String] = []
        let service = RemoteVoiceMappingService(
            registryID: 123,
            readMappings: { [] },
            setMappings: { _ in true }
        )
        let mapper = RemoteVoiceFunctionMapper(
            diagnosticLogger: { lines.append($0) },
            serviceProvider: { [service] }
        )

        #expect(mapper.apply())
        #expect(mapper.isApplied)
        #expect(mapper.voiceMappingReadbackMatched == false)
        #expect(lines.contains { $0.contains("voice_readback=mismatched") })
        #expect(lines.allSatisfy { $0.contains("native_delivery=unknown") })
        #expect(!lines.joined().contains("123"))
    }

    @Test func readbackVerificationTracksNeutralizationAndMissingServices() {
        var mappings: [HIDUsageMapping] = []
        let service = RemoteVoiceMappingService(
            registryID: 1,
            readMappings: { mappings },
            setMappings: { mappings = $0; return true }
        )
        var services = [service]
        let mapper = RemoteVoiceFunctionMapper(serviceProvider: { services })

        #expect(mapper.apply())
        #expect(mapper.voiceMappingReadbackMatched == true)
        #expect(mapper.apply(neutralizeVoiceKey: true))
        #expect(mapper.isVoiceKeyNeutralized)
        #expect(mapper.voiceMappingReadbackMatched == true)
        #expect(mapper.mappingOperationID == 2)
        services = []
        #expect(!mapper.apply())
        #expect(mapper.voiceMappingReadbackMatched == nil)
        #expect(mapper.mappingOperationID == 3)
    }

    @Test func eventTapFnObservationExcludesNavigationAndHostSyntheticEvents() throws {
        var now: TimeInterval = 10
        let state = ShortcutHardwareModifierState(uptime: { now })
        let event = try #require(CGEvent(
            keyboardEventSource: nil, virtualKey: 123, keyDown: true
        ))
        event.type = .flagsChanged
        event.flags = [.maskSecondaryFn, .maskNumericPad]
        state.observe(type: .flagsChanged, event: event)
        #expect(state.functionObservationForDiagnostics.down == nil)

        event.setIntegerValueField(.keyboardEventKeycode, value: 63)
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        state.observe(type: .flagsChanged, event: event)
        #expect(state.functionObservationForDiagnostics.down == nil)

        // A zero event field can fall back to the original source's userData.
        // Use a fresh, unmarked source for the physical-edge fixture.
        let source = try #require(CGEventSource(stateID: .privateState))
        let physicalFnEvent = try #require(CGEvent(
            keyboardEventSource: source, virtualKey: 63, keyDown: true
        ))
        physicalFnEvent.type = .flagsChanged
        physicalFnEvent.flags = .maskSecondaryFn
        state.observe(type: .flagsChanged, event: physicalFnEvent)
        #expect(state.functionObservationForDiagnostics.down == 10)
        now = 11
        physicalFnEvent.flags = []
        state.observe(type: .flagsChanged, event: physicalFnEvent)
        #expect(state.functionObservationForDiagnostics.up == 11)
        #expect(state.snapshot([]).functionState == "released")
        state.reset()
        #expect(state.functionObservationForDiagnostics.down == nil)
        #expect(state.functionObservationForDiagnostics.up == nil)
    }
}
