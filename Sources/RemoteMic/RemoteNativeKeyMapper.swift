import Darwin
import Foundation

/// Neutralizes service-local ordinary keys before accepting raw HID input.
/// Raw reports and the separate voice-key mapping retain their lifecycle.
final class RemoteNativeKeyMapper {
    static let mappings = [
        HIDUsageMapping(source: 0x0000_0007_0000_0035, destination: 0),
        HIDUsageMapping(source: 0x0000_0007_0000_0080, destination: 0),
        HIDUsageMapping(source: 0x0000_0007_0000_0081, destination: 0),
    ] + [UInt64(0x28), 0x4a, 0x4f, 0x50, 0x51, 0x52, 0x65, 0x66].map {
        HIDUsageMapping(source: UInt64(7) << 32 | $0, destination: 0)
    }
    private static let recoveryKey = "sayall.native-key-mapping-recovery.v1"

    private struct RecoveryState: Codable {
        let bootSession: String
        var originals: [UInt64: [HIDUsageMapping]]
        var sources: Set<UInt64>?
    }

    private var sources: Set<UInt64>
    private var recordedSources: Set<UInt64>
    private var desiredMappings: [HIDUsageMapping] { sources.sorted().map { HIDUsageMapping(source: $0, destination: 0) } }
    private let services: RemoteVoiceFunctionMapper.ServiceProvider
    private let bootSession: String?
    private let writeState: (Data) -> Bool
    private let logger: (String) -> Void
    private var originals: [UInt64: [HIDUsageMapping]] = [:]
    private var recoveryAvailable = true
    private(set) var isPrepared = false

    init(
        family: String = "xiaomi",
        mappings: [HIDUsageMapping] = RemoteNativeKeyMapper.mappings,
        recoveryKey: String = RemoteNativeKeyMapper.recoveryKey,
        serviceProvider: @escaping RemoteVoiceFunctionMapper.ServiceProvider = RemoteVoiceFunctionMapper.systemServices,
        defaults: UserDefaults = .standard,
        bootSession: String? = RemoteNativeKeyMapper.systemBootSession(),
        writeState: ((Data) -> Bool)? = nil,
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        sources = Set(mappings.map(\.source))
        recordedSources = sources
        services = serviceProvider
        self.bootSession = bootSession
        self.logger = { logger("\($0) family=\(family)") }
        self.writeState = writeState ?? { data in
            defaults.set(data, forKey: recoveryKey)
            // Persist the recovery record before modifying the system service.
            return defaults.synchronize() && defaults.data(forKey: recoveryKey) == data
        }
        if let data = defaults.data(forKey: recoveryKey) {
            if let state = try? JSONDecoder().decode(RecoveryState.self, from: data) {
                // Registry IDs identify services only within the same system boot.
                if state.bootSession == bootSession {
                    originals = state.originals
                    recordedSources = state.sources ?? Set([UInt64(0x0000_0007_0000_0035), 0x0000_0007_0000_0080, 0x0000_0007_0000_0081])
                    sources.formUnion(recordedSources)
                }
            } else {
                recoveryAvailable = false
            }
        }
    }

    /// Re-enumerate for each device activation; never reuse a global readiness bit.
    @discardableResult
    func prepare(additionalSources: [UInt64] = []) -> Bool {
        isPrepared = false
        sources.formUnion(additionalSources)
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
                originals[id] = desiredMappings.compactMap { mapping in
                    let now = current.first { $0.source == mapping.source }
                    return recordedSources.contains(mapping.source) && now == mapping
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
        recordedSources = sources
        var attempted: [RemoteVoiceMappingService] = []
        for service in targets {
            let current = service.readMappings()
            if matches(nativeMappings(in: current), desiredMappings) { continue }
            attempted.append(service)
            let desired = replacingNativeMappings(in: current, with: desiredMappings)
            guard service.setMappings(desired),
                  matches(nativeMappings(in: service.readMappings()), desiredMappings) else {
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
        isPrepared = true
        log("prepare", result: "verified", reason: "mapping_readback",
            detail: "services=\(targets.count) native_delivery=unobserved")
        return true
    }

    /// Restore owned ordinary-key mappings, retaining voice and external edits.
    func restore() {
        isPrepared = false
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
                  bootSession: bootSession, originals: originals, sources: sources
              )) else { return false }
        return writeState(data)
    }

    private func nativeMappings(in mappings: [HIDUsageMapping]) -> [HIDUsageMapping] {
        mappings.filter { sources.contains($0.source) }
    }

    private func replacingNativeMappings(
        in current: [HIDUsageMapping], with replacement: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        current.filter { !sources.contains($0.source) } + replacement
    }

    private func restoringOwnedMappings(
        in current: [HIDUsageMapping], original: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        desiredMappings.compactMap { mapping in
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
