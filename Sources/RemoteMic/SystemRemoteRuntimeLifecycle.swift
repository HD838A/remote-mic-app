import Foundation

enum SystemRemoteRuntimePhase: String, Equatable {
    case active
    case sleeping
    case wakePending = "wake_pending"
}

enum SystemRemoteRuntimeEvent: Equatable {
    case systemWillSleep
    case systemDidWake
    case sessionDidBecomeActive
    case unrelated
}

enum SystemRemoteRuntimeAction: Equatable {
    case none
    case suspend
    case scheduleResume(generation: UInt64)
    case cancelPendingResume
    case resume
}

struct SystemRemoteRuntimeLifecycleState {
    private(set) var phase: SystemRemoteRuntimePhase = .active
    private(set) var generation: UInt64 = 0

    var isActive: Bool {
        phase == .active
    }

    @discardableResult
    mutating func handle(_ event: SystemRemoteRuntimeEvent) -> SystemRemoteRuntimeAction {
        switch event {
        case .systemWillSleep:
            switch phase {
            case .active:
                generation &+= 1
                phase = .sleeping
                return .suspend
            case .wakePending:
                generation &+= 1
                phase = .sleeping
                return .cancelPendingResume
            case .sleeping:
                return .none
            }

        case .systemDidWake:
            guard phase == .sleeping else { return .none }
            generation &+= 1
            phase = .wakePending
            return .scheduleResume(generation: generation)

        case .sessionDidBecomeActive:
            guard phase == .wakePending else { return .none }
            generation &+= 1
            phase = .active
            return .resume

        case .unrelated:
            return .none
        }
    }

    @discardableResult
    mutating func confirmUserVisibleWake() -> SystemRemoteRuntimeAction {
        guard phase == .wakePending else { return .none }
        generation &+= 1
        phase = .active
        return .resume
    }

    @discardableResult
    mutating func wakeGraceElapsed(generation expectedGeneration: UInt64) -> SystemRemoteRuntimeAction {
        guard phase == .wakePending, generation == expectedGeneration else { return .none }
        generation &+= 1
        phase = .active
        return .resume
    }

    mutating func reset() {
        generation &+= 1
        phase = .active
    }
}
