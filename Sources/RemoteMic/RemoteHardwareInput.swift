import Foundation

/// Stable, non-localized capabilities declared by a hardware adapter.
enum RemoteHardwareCapability: String, Codable, CaseIterable, Hashable {
    case controlEdges = "control_edges"
    case touchSurface = "touch_surface"
    case continuousScroll = "continuous_scroll"
    case voiceStream = "voice_stream"
    case batteryLevel = "battery_level"
    case powerState = "power_state"
}

/// Identifies an adapter-owned device instance without assigning meaning to its transport ID.
/// `instanceID` is for in-process routing and persistence only and must not be written to logs.
struct RemoteHardwareDeviceIdentity: Codable, Equatable, Hashable {
    let adapterID: String
    let instanceID: String
}

struct RemoteHardwareDescriptor: Codable, Equatable {
    let adapterID: String
    let modelID: String
    let capabilities: Set<RemoteHardwareCapability>
}

enum RemoteHardwareControlPhase: String, Codable, Equatable {
    case began
    case ended
    case cancelled
}

enum RemoteHardwareLifecycleCancellationReason: String, Codable, Equatable {
    case deviceDisconnected = "device_disconnected"
    case adapterStopped = "adapter_stopped"
    case configurationChanged = "configuration_changed"
    case permissionRevoked = "permission_revoked"
    case applicationSuspended = "application_suspended"
    case superseded
}

struct RemoteHardwareRawControlEvent: Equatable {
    let device: RemoteHardwareDeviceIdentity
    let controlID: String
    let isPressed: Bool
    let timestampUptime: TimeInterval
}

struct RemoteHardwareControlEvent: Equatable {
    let device: RemoteHardwareDeviceIdentity
    let controlID: String
    let phase: RemoteHardwareControlPhase
    let timestampUptime: TimeInterval
    let sequence: UInt64
    let cancellationReason: RemoteHardwareLifecycleCancellationReason?
}

enum RemoteHardwareControlIgnoreReason: String, Equatable {
    case duplicateBegin = "duplicate_begin"
    case unmatchedEnd = "unmatched_end"
    case suppressedLateEnd = "suppressed_late_end"
    case awaitingCancelledEnd = "awaiting_cancelled_end"
}

enum RemoteHardwareControlRoutingResult: Equatable {
    case emitted(RemoteHardwareControlEvent)
    case ignored(RemoteHardwareControlIgnoreReason)
}

enum RemoteHardwareTouchPhase: String, Codable, Equatable {
    case began
    case changed
    case ended
    case cancelled
}

struct RemoteHardwareTouchContact: Codable, Equatable {
    let identifier: Int
    let normalizedX: Double
    let normalizedY: Double
    let contactSize: Double?
}

struct RemoteHardwareTouchEvent: Equatable {
    let device: RemoteHardwareDeviceIdentity
    let phase: RemoteHardwareTouchPhase
    let contacts: [RemoteHardwareTouchContact]
    let timestampUptime: TimeInterval
    let sequence: UInt64
}

/// Transport-independent tuning values. Device-specific values are explicitly named as
/// experimental baselines until a signed SayAll build completes the documented hardware matrix.
struct RemoteHardwareTouchTuning: Codable, Equatable {
    let minimumCircularRadius: Double
    let circularScrollStartThreshold: Double
    let circularScrollPixelsPerRadian: Double
    let scrollEase: Double
    let minimumAcceleration: Double
    let maximumAcceleration: Double
    let isScrollInverted: Bool

    var isValid: Bool {
        (0...1).contains(minimumCircularRadius)
            && circularScrollStartThreshold >= 0
            && circularScrollPixelsPerRadian > 0
            && (0...1).contains(scrollEase)
            && minimumAcceleration > 0
            && maximumAcceleration >= minimumAcceleration
    }

    /// Starting point derived from partial A2854 hardware tuning in codex-siri-remote.
    /// This is not a compatibility or release claim.
    static let appleSiriRemoteA2854Experimental = RemoteHardwareTouchTuning(
        minimumCircularRadius: 0.35,
        circularScrollStartThreshold: 0.2,
        circularScrollPixelsPerRadian: 30,
        scrollEase: 0.3,
        minimumAcceleration: 1.0,
        maximumAcceleration: 1.3,
        isScrollInverted: true
    )
}

/// Normalizes raw button-like edges before gesture recognition or action routing.
///
/// The router is intentionally timer-free: a physical down edge is emitted synchronously so the
/// voice key can preserve its low-latency press/release contract. Double-click and long-press
/// interpretation remain separate, downstream concerns.
final class RemoteHardwareControlLifecycleRouter {
    private struct ControlKey: Hashable {
        let device: RemoteHardwareDeviceIdentity
        let controlID: String
    }

    private let lock = NSLock()
    private var activeControls = Set<ControlKey>()
    private var suppressedReleases = Set<ControlKey>()
    private var nextSequence: UInt64 = 0

    func route(_ rawEvent: RemoteHardwareRawControlEvent) -> RemoteHardwareControlRoutingResult {
        lock.lock()
        defer { lock.unlock() }
        let key = ControlKey(device: rawEvent.device, controlID: rawEvent.controlID)
        if rawEvent.isPressed {
            guard !suppressedReleases.contains(key) else {
                return .ignored(.awaitingCancelledEnd)
            }
            guard activeControls.insert(key).inserted else {
                return .ignored(.duplicateBegin)
            }
            return .emitted(makeEvent(
                key: key,
                phase: .began,
                timestampUptime: rawEvent.timestampUptime,
                cancellationReason: nil
            ))
        }

        if suppressedReleases.remove(key) != nil {
            return .ignored(.suppressedLateEnd)
        }
        guard activeControls.remove(key) != nil else {
            return .ignored(.unmatchedEnd)
        }
        return .emitted(makeEvent(
            key: key,
            phase: .ended,
            timestampUptime: rawEvent.timestampUptime,
            cancellationReason: nil
        ))
    }

    func cancel(
        device: RemoteHardwareDeviceIdentity,
        reason: RemoteHardwareLifecycleCancellationReason,
        timestampUptime: TimeInterval,
        suppressNextRelease: Bool
    ) -> [RemoteHardwareControlEvent] {
        lock.lock()
        defer { lock.unlock() }
        return cancel(
            matching: { $0.device == device },
            reason: reason,
            timestampUptime: timestampUptime,
            suppressNextRelease: suppressNextRelease
        )
    }

    func cancelAll(
        reason: RemoteHardwareLifecycleCancellationReason,
        timestampUptime: TimeInterval,
        suppressNextRelease: Bool
    ) -> [RemoteHardwareControlEvent] {
        lock.lock()
        defer { lock.unlock() }
        return cancel(
            matching: { _ in true },
            reason: reason,
            timestampUptime: timestampUptime,
            suppressNextRelease: suppressNextRelease
        )
    }

    func isActive(device: RemoteHardwareDeviceIdentity, controlID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeControls.contains(ControlKey(device: device, controlID: controlID))
    }

    private func cancel(
        matching predicate: (ControlKey) -> Bool,
        reason: RemoteHardwareLifecycleCancellationReason,
        timestampUptime: TimeInterval,
        suppressNextRelease: Bool
    ) -> [RemoteHardwareControlEvent] {
        let keys = activeControls
            .filter(predicate)
            .sorted(by: Self.isOrderedBefore)
        for key in keys {
            activeControls.remove(key)
            if suppressNextRelease {
                suppressedReleases.insert(key)
            }
        }
        if !suppressNextRelease {
            suppressedReleases = Set(suppressedReleases.filter { !predicate($0) })
        }
        return keys.map { key in
            makeEvent(
                key: key,
                phase: .cancelled,
                timestampUptime: timestampUptime,
                cancellationReason: reason
            )
        }
    }

    private func makeEvent(
        key: ControlKey,
        phase: RemoteHardwareControlPhase,
        timestampUptime: TimeInterval,
        cancellationReason: RemoteHardwareLifecycleCancellationReason?
    ) -> RemoteHardwareControlEvent {
        nextSequence &+= 1
        return RemoteHardwareControlEvent(
            device: key.device,
            controlID: key.controlID,
            phase: phase,
            timestampUptime: timestampUptime,
            sequence: nextSequence,
            cancellationReason: cancellationReason
        )
    }

    private static func isOrderedBefore(_ lhs: ControlKey, _ rhs: ControlKey) -> Bool {
        let left = (lhs.device.adapterID, lhs.device.instanceID, lhs.controlID)
        let right = (rhs.device.adapterID, rhs.device.instanceID, rhs.controlID)
        return left < right
    }
}
