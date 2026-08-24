import Foundation
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Voice key modes")
struct VoiceKeyModeTests {
    @Test func keepsFnAsTheLegacyDefaultAndUsesDistinctCommandCodes() {
        #expect(VoiceKeyMode(rawValue: "") == nil)
        #expect(VoiceKeyMode.function.rawValue == "fn")
        #expect(VoiceKeyMode.function.keyCode == 63)
        #expect(VoiceKeyMode.leftCommand.keyCode == 55)
        #expect(VoiceKeyMode.rightCommand.keyCode == 54)
        #expect(!VoiceKeyMode.function.requiresAccessibility)
        #expect(VoiceKeyMode.leftCommand.requiresAccessibility)
        #expect(VoiceKeyMode.rightCommand.requiresAccessibility)
        #expect(VoiceKeyMode.function.usesHardwareMapping)
        #expect(!VoiceKeyMode.leftCommand.usesHardwareMapping)
        #expect(VoiceKeyMode.function.localizationKey == "connection.voice_key.mode.fn")
    }

    @Test func voiceKeyInjectionPreservesSideAndReleasesWithEmptyFlags() {
        for mode in [VoiceKeyMode.leftCommand, .rightCommand] {
            var posted: [(CGKeyCode, Bool, CGEventFlags)] = []
            let poster: KeyboardInjector.KeyStatePoster = { code, isDown, flags in
                posted.append((code, isDown, flags))
                return true
            }

            #expect(KeyboardInjector.setVoiceKeyPressed(
                mode,
                isPressed: true,
                accessibilityTrusted: { true },
                keyStatePoster: poster
            ))
            #expect(KeyboardInjector.setVoiceKeyPressed(
                mode,
                isPressed: false,
                accessibilityTrusted: { true },
                keyStatePoster: poster
            ))

            #expect(posted.count == 2)
            #expect(posted[0].0 == mode.keyCode)
            #expect(posted[0].1)
            #expect(posted[0].2 == .maskCommand)
            #expect(posted[1].0 == mode.keyCode)
            #expect(!posted[1].1)
            #expect(posted[1].2.isEmpty)
        }
    }

    @Test func commandModeRequiresAccessibilityButFnDoesNot() {
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: false,
            voiceKeyMode: .function,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .none)
        #expect(HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: false,
            voiceKeyMode: .leftCommand,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ) == .accessibility)
    }

    @Test func commandPermissionChangesTriggerRuntimeRecoveryEvenWithoutButtonMapping() {
        let before = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: false)
        let after = HIDPermissionSnapshot(inputMonitoringGranted: true, accessibilityGranted: true)
        #expect(HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            voiceKeyMode: .leftCommand,
            previous: before,
            current: after
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            previous: before,
            current: after
        ))
    }

    @Test func explicitCommandVoiceSessionDoesNotReactToOrdinaryFunctionEdges() {
        var prepared = 0
        var restored = 0
        var currentInputSource = "com.apple.keylayout.US"
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                prepared += 1
                currentInputSource = OnboardingVoiceTool.doubao.preferredInputSourceID ?? ""
                return .selected
            },
            currentInputSourceID: { currentInputSource },
            restoreInputSource: { _ in
                restored += 1
                currentInputSource = "com.apple.keylayout.US"
                return .selected
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.beginVoiceSession()
        monitor.beginVoiceSession()
        monitor.handleFunctionKeyPressed(true)
        monitor.endVoiceSession()
        monitor.handleFunctionKeyPressed(false)
        monitor.endVoiceSession()

        #expect(prepared == 1)
        #expect(restored == 1)
        #expect(!monitor.functionKeyIsPressedForDiagnostics)
    }

    @Test func configurationDefaultsLegacyAndRoundTripsCommandMode() throws {
        let sourceSuite = "RemoteMicTests.voice-key-source.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let source = AppSettings(defaults: sourceDefaults)
        #expect(source.voiceKeyMode == .function)
        source.voiceKeyMode = .rightCommand
        source.voiceFnTapModeEnabled = true
        let exported = try source.exportedConfigurationData()

        let object = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        #expect(object["voiceKeyMode"] as? String == VoiceKeyMode.rightCommand.rawValue)

        let targetSuite = "RemoteMicTests.voice-key-target.\(UUID().uuidString)"
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        let target = AppSettings(defaults: targetDefaults)
        try target.importConfiguration(from: exported)
        #expect(target.voiceKeyMode == .rightCommand)
        #expect(!target.voiceFnTapModeEnabled)

        var legacy = object
        legacy.removeValue(forKey: "voiceKeyMode")
        try target.importConfiguration(from: try JSONSerialization.data(withJSONObject: legacy))
        #expect(target.voiceKeyMode == .function)
    }
}
