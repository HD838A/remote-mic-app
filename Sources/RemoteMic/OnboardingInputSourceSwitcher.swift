import Carbon
import Foundation

enum OnboardingInputSourceSwitchResult: String, Equatable {
    case notApplicable
    case selected
    case unavailable
    case failed
}

enum OnboardingSystemFunctionKeyUsage: Equatable {
    case available
    case assigned
    case unknown

    static var current: Self {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox"),
              let value = defaults.object(forKey: "AppleFnUsageType") as? NSNumber
        else {
            return .unknown
        }
        return value.intValue == 0 ? .available : .assigned
    }
}

enum OnboardingInputSourceSwitcher {
    static func selectIfNeeded(
        _ voiceTool: OnboardingVoiceTool
    ) -> OnboardingInputSourceSwitchResult {
        guard voiceTool.preferredInputSourceID != nil else { return .notApplicable }
        return isSelected(voiceTool) ? .selected : select(voiceTool)
    }

    static func prepareForVoiceSession(
        _ voiceTool: OnboardingVoiceTool
    ) -> OnboardingInputSourceSwitchResult {
        guard let targetID = voiceTool.preferredInputSourceID else { return .notApplicable }
        guard !isSelected(voiceTool) else { return .selected }
        guard let source = inputSource(withID: targetID, includeAllInstalled: false) else {
            return .unavailable
        }

        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    static func currentInputSourceID() -> String? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return stringProperty(kTISPropertyInputSourceID, from: current)
    }

    static func selectEnabledInputSource(
        withID targetID: String
    ) -> OnboardingInputSourceSwitchResult {
        guard let source = inputSource(withID: targetID, includeAllInstalled: false) else {
            return .unavailable
        }
        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    static func select(_ voiceTool: OnboardingVoiceTool) -> OnboardingInputSourceSwitchResult {
        guard let targetID = voiceTool.preferredInputSourceID else { return .notApplicable }
        guard let source = inputSource(withID: targetID, includeAllInstalled: true) else {
            return .unavailable
        }

        let enableStatus = TISEnableInputSource(source)
        guard enableStatus == noErr else { return .failed }

        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    static func isSelected(_ voiceTool: OnboardingVoiceTool) -> Bool {
        guard let targetID = voiceTool.preferredInputSourceID else { return false }
        return currentInputSourceID() == targetID
    }

    private static func inputSource(
        withID targetID: String,
        includeAllInstalled: Bool
    ) -> TISInputSource? {
        let sources = TISCreateInputSourceList(nil, includeAllInstalled).takeRetainedValue() as NSArray
        for sourceObject in sources {
            let source = sourceObject as! TISInputSource
            if stringProperty(kTISPropertyInputSourceID, from: source) == targetID {
                return source
            }
        }
        return nil
    }

    private static func stringProperty(
        _ key: CFString,
        from source: TISInputSource
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>
            .fromOpaque(pointer)
            .takeUnretainedValue() as? String
    }
}
