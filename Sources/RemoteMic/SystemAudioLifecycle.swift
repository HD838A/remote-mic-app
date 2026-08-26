enum SystemAudioSuspensionReason: String, Hashable {
    case screenSleeping = "screen_sleeping"
    case sessionInactive = "session_inactive"
    case systemSleeping = "system_sleeping"
}

enum SystemAudioLifecycleEvent: String, Equatable {
    case screenDidSleep = "screen_did_sleep"
    case screenDidWake = "screen_did_wake"
    case sessionDidResignActive = "session_did_resign_active"
    case sessionDidBecomeActive = "session_did_become_active"
    case systemWillSleep = "system_will_sleep"
    case systemDidWake = "system_did_wake"

    var suspensionReason: SystemAudioSuspensionReason {
        switch self {
        case .screenDidSleep, .screenDidWake:
            return .screenSleeping
        case .sessionDidResignActive, .sessionDidBecomeActive:
            return .sessionInactive
        case .systemWillSleep, .systemDidWake:
            return .systemSleeping
        }
    }

    var isSuspending: Bool {
        switch self {
        case .screenDidSleep, .sessionDidResignActive, .systemWillSleep:
            return true
        case .screenDidWake, .sessionDidBecomeActive, .systemDidWake:
            return false
        }
    }
}
