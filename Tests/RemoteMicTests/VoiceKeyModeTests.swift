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
        #expect(VoiceKeyMode.rightOption.rawValue == "right_option")
        #expect(VoiceKeyMode.rightOption.keyCode == 61)
        #expect(!VoiceKeyMode.function.requiresAccessibility)
        #expect(VoiceKeyMode.leftCommand.requiresAccessibility)
        #expect(VoiceKeyMode.rightCommand.requiresAccessibility)
        #expect(VoiceKeyMode.rightOption.requiresAccessibility)
        #expect(VoiceKeyMode.function.usesHardwareMapping)
        #expect(!VoiceKeyMode.leftCommand.usesHardwareMapping)
        #expect(VoiceKeyMode.function.localizationKey == "connection.voice_key.mode.fn")
    }

    @Test func voiceKeyInjectionPreservesSideAndReleasesWithEmptyFlags() {
        let expectedFlags: [VoiceKeyMode: CGEventFlags] = [
            .leftCommand: .maskCommand,
            .rightCommand: .maskCommand,
            .rightOption: .maskAlternate,
        ]
        for (mode, heldFlags) in expectedFlags {
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
            #expect(posted[0].2 == heldFlags)
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

    @Test func softwareFnVoiceHoldParticipatesInPermissionRecovery() throws {
        let granted = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )
        let denied = HIDPermissionSnapshot(
            inputMonitoringGranted: true,
            accessibilityGranted: false
        )
        #expect(HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            softwareVoiceKeyHeld: true,
            previous: granted,
            current: denied
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            softwareVoiceKeyHeld: false,
            previous: granted,
            current: denied
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            softwareVoiceKeyHeld: true,
            previous: granted,
            current: granted
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: false,
            customMappingEnabled: false,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            softwareVoiceKeyHeld: true,
            previous: granted,
            current: denied
        ))
        #expect(!HIDPermissionRecoveryPolicy.shouldReapplySettings(
            started: true,
            customMappingEnabled: false,
            voiceKeyMode: .function,
            voiceFnTapModeEnabled: false,
            softwareVoiceKeyHeld: true,
            previous: nil,
            current: denied
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let refreshStart = try #require(source.range(of: "func refreshHIDAfterPermissionChange()"))
        let refreshEnd = try #require(source.range(
            of: "func reconnect()",
            range: refreshStart.upperBound..<source.endIndex
        ))
        let refreshSource = source[refreshStart.lowerBound..<refreshEnd.lowerBound]

        #expect(refreshSource.contains("softwareVoiceKeyHeld: voiceKeyLatch.isHeld"))
    }

    @Test func inputMonitoringLossPreservesAnActiveExplicitCommandSession() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let applyStart = try #require(source.range(of: "func applyHIDSettings("))
        let applyEnd = try #require(source.range(
            of: "private func startHIDMonitors",
            range: applyStart.upperBound..<source.endIndex
        ))
        let applySource = source[applyStart.lowerBound..<applyEnd.lowerBound]

        #expect(applySource.contains("preservingExplicitVoiceSession:"))
        #expect(applySource.contains(
            "voiceKeyLatch.isHeld && heldVoiceKeyMode?.requiresAccessibility == true"
        ))
    }

    @Test func everyBridgeReadyTransitionRefreshesHIDSettings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let callbackStart = try #require(source.range(of: "func bluetoothBridge(\n        _ bridge:"))
        let callbackEnd = try #require(source.range(
            of: "func bluetoothBridgeDidStartVoice",
            range: callbackStart.upperBound..<source.endIndex
        ))
        let callbackSource = source[callbackStart.lowerBound..<callbackEnd.lowerBound]

        #expect(callbackSource.contains("let previousState"))
        #expect(callbackSource.contains("Self.shouldReapplyHIDSettings("))
        #expect(callbackSource.contains("scheduleHIDMappingRecoveryIfNeeded()"))
        #expect(callbackSource.contains(
            "cancelHIDMappingRecovery(reason: \"bluetooth_not_ready\")"
        ))
        #expect(!callbackSource.contains("let hadReadyBridge"))
    }

    @Test func hidRecoveryReappliesTheCurrentVoiceKeyModeWithoutForcingFn() throws {
        #expect(HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure(
            hasMatchingServices: false
        ))
        #expect(!HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure(
            hasMatchingServices: true
        ))

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let recoveryStart = try #require(
            source.range(of: "private func scheduleHIDMappingRecoveryIfNeeded()")
        )
        let recoveryEnd = try #require(source.range(
            of: "private func completeHIDMappingRecoveryIfNeeded()",
            range: recoveryStart.upperBound..<source.endIndex
        ))
        let recoverySource = source[recoveryStart.lowerBound..<recoveryEnd.lowerBound]

        #expect(recoverySource.contains("self.applyHIDSettings()"))
        #expect(!recoverySource.contains("settings.voiceKeyMode = .function"))

        let applyStart = try #require(source.range(of: "func applyHIDSettings("))
        let applyEnd = try #require(source.range(
            of: "private func scheduleHIDMappingRecoveryIfNeeded()",
            range: applyStart.upperBound..<source.endIndex
        ))
        let applySource = source[applyStart.lowerBound..<applyEnd.lowerBound]

        #expect(applySource.contains("let requestedVoiceKeyMode = settings.voiceKeyMode"))
        #expect(applySource.contains("requestedVoiceKeyMode != .function"))
        #expect(applySource.contains("applyVoiceFunctionMapping(neutralizeVoiceKey: true)"))
        #expect(applySource.contains("applyVoiceFunctionMapping(neutralizeVoiceKey: false)"))
        #expect(applySource.contains(
            "HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure"
        ))
        #expect(applySource.contains(
            "VOICE FN TAP mode_pending_mapping reason=no_matching_service"
        ))

        let enableStart = try #require(source.range(of: "private func enableVoiceFnTapMode()"))
        let enableEnd = try #require(source.range(
            of: "private func handleVoiceFnTapFailure",
            range: enableStart.upperBound..<source.endIndex
        ))
        let enableSource = source[enableStart.lowerBound..<enableEnd.lowerBound]
        #expect(enableSource.contains(
            "HIDMappingRecoveryPolicy.shouldPreserveFnTapPreferenceAfterMappingFailure"
        ))
        #expect(enableSource.contains("settings.voiceFnTapModeEnabled = true"))
        #expect(enableSource.contains("scheduleHIDMappingRecoveryIfNeeded()"))
    }

    @Test func bluetoothCommandVoiceRequiresNeutralizedHardwareKeyBeforeAcceptance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "func bluetoothBridgeDidStartVoice"))
        let end = try #require(source.range(
            of: "func bluetoothBridgeDidStopVoice",
            range: start.upperBound..<source.endIndex
        ))
        let startSource = source[start.lowerBound..<end.lowerBound]
        let neutralizationCheck = try #require(
            startSource.range(of: "voiceFunctionMapper.isVoiceKeyNeutralized")
        )
        let acceptedState = try #require(startSource.range(of: "bluetoothVoiceActive = true"))

        #expect(startSource.contains("applyHIDSettings(allowVoiceKeyModeFallback: false)"))
        #expect(neutralizationCheck.lowerBound < acceptedState.lowerBound)
    }

    @Test func voiceMappingFallbackIsDisabledDuringAStreamStartAttempt() {
        #expect(BridgeAppModel.canFallbackVoiceKeyMode(
            isStreaming: false,
            allowVoiceKeyModeFallback: true
        ))
        #expect(!BridgeAppModel.canFallbackVoiceKeyMode(
            isStreaming: true,
            allowVoiceKeyModeFallback: true
        ))
        #expect(!BridgeAppModel.canFallbackVoiceKeyMode(
            isStreaming: false,
            allowVoiceKeyModeFallback: false
        ))
    }

    @Test func voiceMappingFailureDoesNotChangeModeDuringAnActiveVoiceSession() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let applyStart = try #require(source.range(of: "func applyHIDSettings("))
        let applyEnd = try #require(source.range(
            of: "private func startHIDMonitors",
            range: applyStart.upperBound..<source.endIndex
        ))
        let applySource = source[applyStart.lowerBound..<applyEnd.lowerBound]
        let activeGate = try #require(applySource.range(of: "if isStreaming"))
        let fallback = try #require(applySource.range(of: "settings.voiceKeyMode = .function"))

        #expect(activeGate.lowerBound < fallback.lowerBound)
        #expect(applySource.contains("mode_preserved reason=voice_active_mapping_failed"))
        #expect(applySource.contains("VOICE FN TAP mode_preserved reason=voice_active_mapping_failed"))
    }

    @Test func configurationImportUsesModelSafetyGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let importStart = try #require(settingsSource.range(of: "private func importConfiguration()"))
        let importEnd = try #require(settingsSource.range(
            of: "private func permissionRow",
            range: importStart.upperBound..<settingsSource.endIndex
        ))
        let importSource = settingsSource[importStart.lowerBound..<importEnd.lowerBound]

        #expect(importSource.contains("try model.importConfiguration(from:"))
        #expect(!importSource.contains("try settings.importConfiguration(from:"))

        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let modelImportStart = try #require(
            modelSource.range(of: "func importConfiguration(from data: Data) throws")
        )
        let modelImportEnd = try #require(modelSource.range(
            of: "func setVoiceKeyMode",
            range: modelImportStart.upperBound..<modelSource.endIndex
        ))
        let modelImportSource = modelSource[modelImportStart.lowerBound..<modelImportEnd.lowerBound]
        #expect(modelImportSource.contains("Self.importConfiguration("))
        #expect(modelImportSource.contains("releaseVoiceKey: { releaseVoiceKeyIfNeeded() }"))
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

    @Test func configurationImportRejectsUnsafeVoiceKeyChangesBeforeMutation() throws {
        let sourceSuite = "RemoteMicTests.voice-key-preflight-source.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let source = AppSettings(defaults: sourceDefaults)
        source.gainDB = 12
        source.voiceKeyMode = .leftCommand
        let data = try source.exportedConfigurationData()

        let targetSuite = "RemoteMicTests.voice-key-preflight-target.\(UUID().uuidString)"
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        let target = AppSettings(defaults: targetDefaults)
        target.gainDB = 3
        target.voiceKeyMode = .function

        var releaseCount = 0
        #expect(throws: AppConfigurationError.self) {
            try BridgeAppModel.importConfiguration(
                from: data,
                into: target,
                isStreaming: true,
                releaseVoiceKey: {
                    releaseCount += 1
                    return true
                }
            )
        }
        #expect(releaseCount == 0)
        #expect(target.voiceKeyMode == .function)
        #expect(target.gainDB == 3)

        #expect(throws: AppConfigurationError.self) {
            try BridgeAppModel.importConfiguration(
                from: data,
                into: target,
                isStreaming: false,
                releaseVoiceKey: {
                    releaseCount += 1
                    return false
                }
            )
        }
        #expect(releaseCount == 1)
        #expect(target.voiceKeyMode == .function)
        #expect(target.gainDB == 3)

        #expect(try BridgeAppModel.importConfiguration(
            from: data,
            into: target,
            isStreaming: false,
            releaseVoiceKey: {
                releaseCount += 1
                return true
            }
        ))
        #expect(releaseCount == 2)
        #expect(target.voiceKeyMode == .leftCommand)
        #expect(target.gainDB == 12)
    }
}
