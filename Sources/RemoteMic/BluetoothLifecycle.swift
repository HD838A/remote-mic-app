import Foundation

enum XiaomiVoiceRemoteNameMatcher {
    private static let approvedNames: Set<String> = [
        "mi rc",
        "xiaomi bluetooth remote 2",
        "xiaomi bluetooth remote 2 pro",
        "小米蓝牙语音遥控器",
        // 蓝牙遥控器 2 / 2 Pro (model ARN9) advertise under these names.
        "小米蓝牙遥控器2",
        "小米蓝牙遥控器2 pro",
        "arn9",
    ]

    static func matches(_ rawName: String?) -> Bool {
        guard let rawName else { return false }
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return approvedNames.contains(normalized)
    }
}

enum BluetoothLifecyclePhase: Equatable {
    case stopped
    case scanning(UInt64)
    case connecting(UInt64)
    case discovering(UInt64)
    case awaitingCapabilities(UInt64)
    case ready(UInt64)
    case disconnecting(UInt64)
    case waitingReconnect(UInt64)
    case waitingBluetoothPower(UInt64)

    var generation: UInt64? {
        switch self {
        case .connecting(let value),
             .scanning(let value),
             .discovering(let value),
             .awaitingCapabilities(let value),
             .ready(let value),
             .disconnecting(let value),
             .waitingReconnect(let value),
             .waitingBluetoothPower(let value):
            return value
        case .stopped:
            return nil
        }
    }

    func acceptsDidConnect(generation: UInt64) -> Bool {
        self == .connecting(generation)
    }

    func acceptsDidFailToConnect(generation: UInt64) -> Bool {
        self == .connecting(generation) || self == .disconnecting(generation)
    }

    func acceptsInitializationCallback(generation: UInt64) -> Bool {
        self == .discovering(generation)
    }

    func acceptsNotificationUpdate(generation: UInt64) -> Bool {
        switch self {
        case .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation):
            return true
        default:
            return false
        }
    }

    func acceptsCapabilities(generation: UInt64) -> Bool {
        self == .awaitingCapabilities(generation)
    }

    func acceptsProtocolData(generation: UInt64) -> Bool {
        self == .ready(generation)
    }

    func acceptsDisconnect(generation: UInt64) -> Bool {
        switch self {
        case .connecting(generation),
             .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation),
             .disconnecting(generation):
            return true
        default:
            return false
        }
    }
}

struct BluetoothReconnectPolicy {
    static let baseDelay: TimeInterval = 3
    static let maximumDelay: TimeInterval = 60
    static let jitterRatio = 0.1

    private(set) var consecutiveFailureCount = 0
    private(set) var allowsCachedTargetRetrieval = true

    mutating func nextAutomaticDelay(
        bypassCachedTarget: Bool,
        jitterUnit: Double
    ) -> TimeInterval {
        consecutiveFailureCount += 1
        if bypassCachedTarget {
            allowsCachedTargetRetrieval = false
        }

        let exponent = min(consecutiveFailureCount - 1, 5)
        let nominalDelay = min(
            Self.maximumDelay,
            Self.baseDelay * pow(2, Double(exponent))
        )
        let normalizedJitter = min(1, max(0, jitterUnit))
        let jitterFactor = (1 - Self.jitterRatio) +
            (normalizedJitter * Self.jitterRatio * 2)
        return min(Self.maximumDelay, nominalDelay * jitterFactor)
    }

    mutating func reset() {
        consecutiveFailureCount = 0
        allowsCachedTargetRetrieval = true
    }
}

enum BluetoothCentralRecoveryEvent {
    case poweredOn
    case poweredOff
    case resetting
    case unauthorized
    case unsupported
}

struct BluetoothCentralRecoveryTransition: Equatable {
    let phase: BluetoothLifecyclePhase
    let shouldCancelScheduledReconnect: Bool
    let shouldDiscover: Bool
    let shouldStartFreshConnectionCycle: Bool
    let shouldReleaseCentral: Bool
}

enum BluetoothCentralRecoveryPolicy {
    static func transition(
        from phase: BluetoothLifecyclePhase,
        generation: UInt64,
        event: BluetoothCentralRecoveryEvent,
        shouldRun: Bool
    ) -> BluetoothCentralRecoveryTransition {
        switch event {
        case .poweredOff, .resetting:
            guard shouldRun else {
                return BluetoothCentralRecoveryTransition(
                    phase: .stopped,
                    shouldCancelScheduledReconnect: true,
                    shouldDiscover: false,
                    shouldStartFreshConnectionCycle: false,
                    shouldReleaseCentral: true
                )
            }
            return BluetoothCentralRecoveryTransition(
                phase: .waitingBluetoothPower(generation),
                shouldCancelScheduledReconnect: true,
                shouldDiscover: false,
                shouldStartFreshConnectionCycle: false,
                shouldReleaseCentral: false
            )
        case .poweredOn:
            guard shouldRun else {
                return BluetoothCentralRecoveryTransition(
                    phase: .stopped,
                    shouldCancelScheduledReconnect: true,
                    shouldDiscover: false,
                    shouldStartFreshConnectionCycle: false,
                    shouldReleaseCentral: true
                )
            }
            let requiresFreshConnectionCycle = phase == .waitingReconnect(generation) ||
                phase == .waitingBluetoothPower(generation)
            return BluetoothCentralRecoveryTransition(
                phase: requiresFreshConnectionCycle ? .stopped : phase,
                shouldCancelScheduledReconnect: requiresFreshConnectionCycle,
                shouldDiscover: !requiresFreshConnectionCycle &&
                    phase == .scanning(generation),
                shouldStartFreshConnectionCycle: requiresFreshConnectionCycle,
                shouldReleaseCentral: false
            )
        case .unauthorized, .unsupported:
            return BluetoothCentralRecoveryTransition(
                phase: .stopped,
                shouldCancelScheduledReconnect: true,
                shouldDiscover: false,
                shouldStartFreshConnectionCycle: false,
                shouldReleaseCentral: true
            )
        }
    }
}

enum ATVVSessionGate {
    static let cancelledOpenSuppressionInterval: TimeInterval = 2

    static func canOpenMicrophone(
        phase: BluetoothLifecyclePhase,
        generation: UInt64,
        capabilitiesConfirmed: Bool,
        sampleRate: Double
    ) -> Bool {
        phase.acceptsProtocolData(generation: generation) &&
            capabilitiesConfirmed &&
            ATVVProtocol.supportsAudio(sampleRate: sampleRate)
    }

    static func cancelledOpenDate(
        microphoneOpened: Bool,
        streaming: Bool,
        now: Date = Date()
    ) -> Date? {
        microphoneOpened && !streaming ? now : nil
    }

    static func shouldIgnoreStreamAfterCancelledOpen(
        cancelledAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let cancelledAt else { return false }
        return now < cancelledAt.addingTimeInterval(cancelledOpenSuppressionInterval)
    }
}
