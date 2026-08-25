import Foundation

enum HIDMappingRecoveryPolicy {
    static let delays: [TimeInterval] = [0.5, 1, 2, 4, 8]
    static let verificationDelays: [TimeInterval] = [0.75, 2, 5, 10]

    static func requestedVoiceMappingMode(
        shortcut: CustomKeyboardShortcut?,
        fnTapModeEnabled: Bool,
        voiceKeyMode: VoiceKeyMode = .function,
        accessibilityGranted: Bool
    ) -> RemoteVoiceKeyMappingMode {
        if let modifier = shortcut?.standaloneModifier {
            return .standaloneModifier(modifier)
        }
        if voiceKeyMode.requiresAccessibility ||
            ((shortcut != nil || fnTapModeEnabled) && accessibilityGranted) {
            return .neutralized
        }
        return .function
    }

    static func isMappingReady(
        expectedMode: RemoteVoiceKeyMappingMode,
        appliedMode: RemoteVoiceKeyMappingMode?,
        voiceMappingComplete: Bool,
        nativeButtonsSuppressed: Bool
    ) -> Bool {
        appliedMode == expectedMode &&
            voiceMappingComplete &&
            nativeButtonsSuppressed
    }

    static func nextDelay(
        afterFailedAttempt attempt: Int,
        started: Bool,
        customMappingEnabled: Bool,
        mappingReady: Bool
    ) -> TimeInterval? {
        guard started,
              customMappingEnabled,
              !mappingReady,
              delays.indices.contains(attempt)
        else { return nil }
        return delays[attempt]
    }
}
