import CoreGraphics
import Foundation

/// Read-only Fn observations used to separate a stuck synthetic Fn from a
/// physical Fn event that never reached SayAll's event taps.
enum FnKeyDiagnostics {
    static let functionKeyCode: CGKeyCode = 63

    struct State {
        let fnFlag: Bool
        let key63Down: Bool
        let secureInput: Bool
        let systemFnUsage: String
    }

    /// Live HID-state snapshot. The caller must already hold Accessibility
    /// access; otherwise the synchronous CGEventSource queries can block.
    static func readState() -> State {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return State(
            fnFlag: flags.contains(.maskSecondaryFn),
            key63Down: CGEventSource.keyState(.hidSystemState, key: functionKeyCode),
            secureInput: SecureInputMonitor.isEnabled(),
            systemFnUsage: systemFnUsageValue
        )
    }

    static var systemFnUsageValue: String {
        switch OnboardingSystemFunctionKeyUsage.current {
        case .available: return "do_nothing"
        case .assigned: return "assigned"
        case .unknown: return "unknown"
        }
    }

    /// Returns a log line only for a Fn `flagsChanged` edge. Every other event
    /// is ignored so normal typing does not add log noise.
    static func eventObservation(
        source: String,
        tap: String,
        type: CGEventType,
        event: CGEvent
    ) -> String? {
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(functionKeyCode)
        else { return nil }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) ==
            KeyboardInjector.syntheticEventMarker
        return "VOICE KEY fn_observe source=\(source) tap=\(tap) phase=observed " +
            "synthetic=\(synthetic) pressed=\(event.flags.contains(.maskSecondaryFn)) " +
            "event_timestamp_ns=\(event.timestamp)"
    }

    /// Navigation and Fn-layer keys carry a pseudo-Fn bit in their raw HID
    /// snapshot. Exclude them so ordinary arrow/Home presses do not look like
    /// a user-held Fn combination.
    private static let pseudoFunctionKeyCodes: Set<CGKeyCode> = [
        114, 115, 116, 117, 119, 121, 123, 124, 125, 126,
    ]

    /// A keyDown carrying the Fn flag is the observable fallback when Fn was
    /// already down before the tap saw its edge. It never logs the key code or
    /// characters; unknown keys stay `unclassified`.
    static func combinationObservation(
        source: String,
        tap: String,
        type: CGEventType,
        event: CGEvent
    ) -> String? {
        guard type == .keyDown, event.flags.contains(.maskSecondaryFn) else { return nil }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard !pseudoFunctionKeyCodes.contains(keyCode) else { return nil }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) ==
            KeyboardInjector.syntheticEventMarker
        let kind = ShortcutEventSequence.diagnosticKind(
            keyCode,
            modifiers: event.flags
        ) ?? "unclassified"
        return "VOICE KEY fn_combo_observe source=\(source) tap=\(tap) phase=observed " +
            "synthetic=\(synthetic) primary_kind=\(kind) " +
            "event_timestamp_ns=\(event.timestamp)"
    }

    static func snapshotLine(
        source: String,
        fnFlag: Bool,
        key63Down: Bool,
        secureInput: Bool,
        systemFnUsage: String,
        voiceKeyMode: String,
        voiceFnTap: Bool,
        voiceTool: String
    ) -> String {
        "VOICE KEY fn_snapshot source=\(source) result=observed " +
            "fn_flag=\(fnFlag) key63_down=\(key63Down) " +
            "secure_input=\(secureInput) system_fn_usage=\(systemFnUsage) " +
            "voice_key_mode=\(voiceKeyMode) voice_fn_tap=\(voiceFnTap) " +
            "voice_tool=\(voiceTool)"
    }

    static func skippedSnapshotLine(
        source: String,
        secureInput: Bool,
        systemFnUsage: String,
        voiceKeyMode: String,
        voiceFnTap: Bool,
        voiceTool: String
    ) -> String {
        "VOICE KEY fn_snapshot source=\(source) result=skipped " +
            "reason=accessibility_denied secure_input=\(secureInput) " +
            "system_fn_usage=\(systemFnUsage) voice_key_mode=\(voiceKeyMode) " +
            "voice_fn_tap=\(voiceFnTap) voice_tool=\(voiceTool)"
    }

    static func logSnapshot(
        source: String,
        voiceKeyMode: String,
        voiceFnTap: Bool,
        voiceTool: String,
        accessibilityGranted: Bool = KeyboardInjector.isAccessibilityTrusted,
        logger: (String) -> Void = AppLogger.shared.write
    ) {
        guard accessibilityGranted else {
            logger(skippedSnapshotLine(
                source: source,
                secureInput: SecureInputMonitor.isEnabled(),
                systemFnUsage: systemFnUsageValue,
                voiceKeyMode: voiceKeyMode,
                voiceFnTap: voiceFnTap,
                voiceTool: voiceTool
            ))
            return
        }
        let state = readState()
        logger(snapshotLine(
            source: source,
            fnFlag: state.fnFlag,
            key63Down: state.key63Down,
            secureInput: state.secureInput,
            systemFnUsage: state.systemFnUsage,
            voiceKeyMode: voiceKeyMode,
            voiceFnTap: voiceFnTap,
            voiceTool: voiceTool
        ))
    }
}
