import AppKit
import Carbon
import Foundation

enum OnboardingInputSourceSwitchResult: String, Equatable {
    case notApplicable
    case selected
    case notSelected = "not_selected"
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
    static func applicationURL(for voiceTool: OnboardingVoiceTool) -> URL? {
        if let bundleIdentifier = voiceTool.applicationBundleIdentifier {
            return NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        }

        if let launchURL = voiceTool.publicLaunchURL {
            return NSWorkspace.shared.urlForApplication(toOpen: launchURL)
        }

        return nil
    }

    static func runtimeState(
        for voiceTool: OnboardingVoiceTool
    ) -> OnboardingVoiceToolRuntimeState {
        guard OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: voiceTool) else {
            return .notApplicable
        }
        guard let applicationURL = applicationURL(for: voiceTool) else {
            return .unknown
        }

        let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
        let isRunning = NSWorkspace.shared.runningApplications.contains { application in
            if let bundleIdentifier,
               application.bundleIdentifier == bundleIdentifier {
                return true
            }
            return application.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL
        }
        return isRunning ? .running : .notRunning
    }

    static func selectionState(
        for voiceTool: OnboardingVoiceTool
    ) -> OnboardingInputSourceSwitchResult {
        guard let inputSourceID = voiceTool.preferredInputSourceID else {
            return .notApplicable
        }
        guard inputSource(withID: inputSourceID, includeAllInstalled: true) != nil else {
            return .unavailable
        }
        return isSelected(voiceTool) ? .selected : .notSelected
    }

    @discardableResult
    static func launchApplication(
        for voiceTool: OnboardingVoiceTool,
        activates: Bool,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let applicationURL = applicationURL(for: voiceTool) else {
            completion?(false)
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
            completion?(app != nil && error == nil)
        }
        return true
    }

    static func availability(
        for voiceTool: OnboardingVoiceTool
    ) -> OnboardingVoiceToolAvailability {
        let profile = VoiceToolAdapterProfile.profile(for: voiceTool)
        if let inputSourceID = voiceTool.preferredInputSourceID {
            return inputSource(withID: inputSourceID, includeAllInstalled: true) == nil
                ? .notInstalled
                : .available
        }

        if let bundleIdentifier = voiceTool.applicationBundleIdentifier {
            return NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) == nil ? .notInstalled : .available
        }

        if profile.installationProbe == .publicURLScheme {
            guard let launchURL = voiceTool.publicLaunchURL else { return .unknown }
            return NSWorkspace.shared.urlForApplication(toOpen: launchURL) == nil
                ? .notInstalled
                : .available
        }

        return profile.installationProbe == .none ? .unknown : .available
    }

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
