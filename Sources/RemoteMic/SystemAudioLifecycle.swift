import AppKit

// Adapted from upstream 7e49f00. Keep system policy independent of voice routing.
enum SystemAudioLifecycleEvent: CaseIterable {
    case screenDidSleep, screenDidWake
    case sessionDidResignActive, sessionDidBecomeActive
    case systemWillSleep, systemDidWake

    var notification: Notification.Name {
        switch self {
        case .screenDidSleep: return NSWorkspace.screensDidSleepNotification
        case .screenDidWake: return NSWorkspace.screensDidWakeNotification
        case .sessionDidResignActive: return NSWorkspace.sessionDidResignActiveNotification
        case .sessionDidBecomeActive: return NSWorkspace.sessionDidBecomeActiveNotification
        case .systemWillSleep: return NSWorkspace.willSleepNotification
        case .systemDidWake: return NSWorkspace.didWakeNotification
        }
    }

    fileprivate var reason: Int {
        switch self {
        case .screenDidSleep, .screenDidWake: return 0
        case .sessionDidResignActive, .sessionDidBecomeActive: return 1
        case .systemWillSleep, .systemDidWake: return 2
        }
    }

    fileprivate var isSuspending: Bool {
        switch self {
        case .screenDidSleep, .sessionDidResignActive, .systemWillSleep: return true
        default: return false
        }
    }
}

struct SystemAudioSuspensionState {
    private var reasons = Set<Int>()
    var isSuspended: Bool { !reasons.isEmpty }

    mutating func apply(_ event: SystemAudioLifecycleEvent) {
        if event.isSuspending { reasons.insert(event.reason) }
        else { reasons.remove(event.reason) }
    }

    func shouldKeepAudioActive(hasReadyRemote: Bool, hasActiveVoiceOrTone: Bool) -> Bool {
        hasActiveVoiceOrTone || (hasReadyRemote && !isSuspended)
    }
}
