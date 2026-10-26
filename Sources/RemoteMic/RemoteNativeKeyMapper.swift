import Darwin
import Foundation

/// Applies service-local TV/volume mappings before accepting raw HID input.
/// Does not change the raw-report callback or the separate voice/power mappings.
final class RemoteNativeKeyMapper {
    static let mappings = [
        HIDUsageMapping(source: 0x0000_0007_0000_0035, destination: 0),
        HIDUsageMapping(source: 0x0000_0007_0000_0080, destination: 0),
        HIDUsageMapping(source: 0x0000_0007_0000_0081, destination: 0),
    ]
    private static let sources = Set(mappings.map(\.source))
    private static let recoveryKey = "sayall.native-key-mapping-recovery.v1"

    private struct RecoveryState: Codable {
        let bootSession: String
        var originals: [UInt64: [HIDUsageMapping]]
    }

    private let services: RemoteVoiceFunctionMapper.ServiceProvider
    private let bootSession: String?
    private let writeState: (Data) -> Bool
    private let logger: (String) -> Void
    private var originals: [UInt64: [HIDUsageMapping]] = [:]
    private var recoveryAvailable = true

    init(
        serviceProvider: @escaping RemoteVoiceFunctionMapper.ServiceProvider = RemoteVoiceFunctionMapper.systemServices,
        defaults: UserDefaults = .standard,
        bootSession: String? = RemoteNativeKeyMapper.systemBootSession(),
        writeState: ((Data) -> Bool)? = nil,
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        services = serviceProvider
        self.bootSession = bootSession
        self.logger = logger
        self.writeState = writeState ?? { data in
            defaults.set(data, forKey: Self.recoveryKey)
            // Persist the recovery record before modifying the system service.
            return defaults.synchronize() && defaults.data(forKey: Self.recoveryKey) == data
        }
        if let data = defaults.data(forKey: Self.recoveryKey) {
            if let state = try? JSONDecoder().decode(RecoveryState.self, from: data) {
                // Registry IDs identify services only within the same system boot.
                if state.bootSession == bootSession { originals = state.originals }
            } else {
                recoveryAvailable = false
            }
        }
    }

    /// Re-enumerate for each device activation; never reuse a global readiness bit.
    @discardableResult
    func prepare() -> Bool {
        guard recoveryAvailable, bootSession != nil else {
            log("prepare", result: "failed", reason: "recovery_unavailable")
            return false
        }
        let targets = services()
        guard !targets.isEmpty else {
            log("prepare", result: "pending", reason: "no_service")
            return false
        }
        var before: [UInt64: [HIDUsageMapping]] = [:]
        for service in targets {
            guard let id = service.registryID, before[id] == nil else {
                log("prepare", result: "failed", reason: "service_identity_unavailable")
                return false
            }
            let current = nativeMappings(in: service.readMappings())
            before[id] = current
            if let previous = originals[id] {
                // Preserve a new external mapping rather than restoring over it later.
                originals[id] = Self.mappings.compactMap { mapping in
                    let now = current.first { $0.source == mapping.source }
                    return now == mapping
                        ? previous.first { $0.source == mapping.source }
                        : now
                }
            } else {
                originals[id] = current
            }
        }
        guard persist() else {
            log("prepare", result: "failed", reason: "recovery_write_failed")
            return false
        }
        var attempted: [RemoteVoiceMappingService] = []
        for service in targets {
            let current = service.readMappings()
            if matches(nativeMappings(in: current), Self.mappings) { continue }
            attempted.append(service)
            let desired = replacingNativeMappings(in: current, with: Self.mappings)
            guard service.setMappings(desired),
                  matches(nativeMappings(in: service.readMappings()), Self.mappings) else {
                var restored = 0
                for target in attempted.reversed() {
                    guard let id = target.registryID, let snapshot = before[id] else { continue }
                    let current = target.readMappings()
                    let desiredNative = restoringOwnedMappings(in: current, original: snapshot)
                    let rollback = replacingNativeMappings(in: current, with: desiredNative)
                    if matches(nativeMappings(in: current), desiredNative) || (
                        target.setMappings(rollback) &&
                            matches(nativeMappings(in: target.readMappings()), desiredNative)
                    ) { restored += 1 }
                }
                log("prepare", result: "failed", reason: "mapping_not_verified",
                    detail: "attempted=\(attempted.count) restored=\(restored)")
                return false
            }
        }
        log("prepare", result: "verified", reason: "mapping_readback",
            detail: "services=\(targets.count) native_delivery=unobserved")
        return true
    }

    /// Restore only our three mappings, retaining voice/power and external edits.
    func restore() {
        guard recoveryAvailable, bootSession != nil else {
            log("restore", result: "failed", reason: "recovery_unavailable")
            return
        }
        guard !originals.isEmpty else { return }
        var restored = 0
        var failed = 0
        for service in services() {
            guard let id = service.registryID, let original = originals[id] else { continue }
            let current = service.readMappings()
            let native = nativeMappings(in: current)
            let desiredNative = restoringOwnedMappings(in: current, original: original)
            let desired = replacingNativeMappings(in: current, with: desiredNative)
            if matches(native, desiredNative) || (
                service.setMappings(desired) &&
                    matches(nativeMappings(in: service.readMappings()), desiredNative)
            ) {
                originals.removeValue(forKey: id)
                restored += 1
            } else {
                failed += 1
            }
        }
        let saved = persist()
        log("restore", result: failed == 0 && saved ? "verified" : "failed",
            reason: saved ? "mapping_readback" : "recovery_write_failed",
            detail: "restored=\(restored) failed=\(failed) pending=\(originals.count)")
    }

    private func persist() -> Bool {
        guard let bootSession,
              let data = try? JSONEncoder().encode(RecoveryState(
                  bootSession: bootSession, originals: originals
              )) else { return false }
        return writeState(data)
    }

    private func nativeMappings(in mappings: [HIDUsageMapping]) -> [HIDUsageMapping] {
        mappings.filter { Self.sources.contains($0.source) }
    }

    private func replacingNativeMappings(
        in current: [HIDUsageMapping], with replacement: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        current.filter { !Self.sources.contains($0.source) } + replacement
    }

    private func restoringOwnedMappings(
        in current: [HIDUsageMapping], original: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        Self.mappings.compactMap { mapping in
            let now = current.first { $0.source == mapping.source }
            return now == mapping ? original.first { $0.source == mapping.source } : now
        }
    }

    private func matches(_ lhs: [HIDUsageMapping], _ rhs: [HIDUsageMapping]) -> Bool {
        lhs.sorted { $0.source < $1.source } == rhs.sorted { $0.source < $1.source }
    }

    private func log(_ phase: String, result: String, reason: String, detail: String = "") {
        logger("HID NATIVE MAPPING phase=\(phase) result=\(result) reason=\(reason) \(detail)")
    }

    static func systemBootSession() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
