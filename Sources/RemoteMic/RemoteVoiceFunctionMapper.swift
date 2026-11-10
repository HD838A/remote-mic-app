import Foundation
import IOKit.hid
import IOKit.hidsystem

struct HIDUsageMapping: Equatable, Codable {
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    let source: UInt64
    let destination: UInt64

    init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    init?(property: [String: NSNumber]) {
        guard let source = property[Self.sourceKey],
              let destination = property[Self.destinationKey]
        else { return nil }
        self.source = source.uint64Value
        self.destination = destination.uint64Value
    }

    var property: [String: NSNumber] {
        [
            Self.sourceKey: NSNumber(value: source),
            Self.destinationKey: NSNumber(value: destination),
        ]
    }
}

enum RemoteVoiceFunctionMappingPolicy {
    // Map RC003 F5 and the letter-i usage observed in the 2026-11-06 field report.
    // Both map to Apple vendor top-case Fn/Globe (usage page 0xff, usage 3).
    static let remoteVoiceKeySources: [UInt64] = [
        0x0000_0007_0000_003E,
        0x0000_0007_0000_000C,
    ]

    static let functionKeyDestination: UInt64 = 0x0000_00FF_0000_0003

    static let remoteVoiceKeys: [HIDUsageMapping] = remoteVoiceKeySources.map {
        HIDUsageMapping(source: $0, destination: functionKeyDestination)
    }

    // Typeless 等点按式语音工具会被 Fn 长按干扰；此模式下彻底丢弃语音键的
    // 按键事件（目标 usage 0），Fn 点按改由软件注入，避免物理按键按住时干扰注入。
    static let neutralRemoteVoiceKeys: [HIDUsageMapping] = remoteVoiceKeySources.map {
        HIDUsageMapping(source: $0, destination: 0x0)
    }

    static var remoteVoiceKey: HIDUsageMapping { remoteVoiceKeys[0] }
    static var neutralRemoteVoiceKey: HIDUsageMapping { neutralRemoteVoiceKeys[0] }

    // Xiaomi RC001 and RC003 expose the power button as keyboard Power (usage 0x66).
    // Remap it to harmless F20 before macOS can turn it into a sleep event.
    static let suppressedRemotePowerKey = HIDUsageMapping(
        source: 0x0000_0007_0000_0066,
        destination: 0x0000_0007_0000_006F
    )

    static func applying(
        to existing: [HIDUsageMapping],
        voiceMappings: [HIDUsageMapping] = RemoteVoiceFunctionMappingPolicy.remoteVoiceKeys,
        powerMapping: HIDUsageMapping? = nil,
        preservePowerKeyMapping: Bool = false
    ) -> [HIDUsageMapping] {
        var desired = existing.filter {
            !remoteVoiceKeySources.contains($0.source) &&
                (preservePowerKeyMapping || $0.source != suppressedRemotePowerKey.source)
        }
        desired.append(contentsOf: voiceMappings)
        if let powerMapping {
            desired.append(powerMapping)
        }
        return desired
    }

    static func restoring(
        originalVoiceMappings: [HIDUsageMapping],
        originalPowerMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping],
        preservePowerKeyMapping: Bool = false
    ) -> [HIDUsageMapping] {
        var restored = current.filter {
            !remoteVoiceKeySources.contains($0.source) &&
                (preservePowerKeyMapping || $0.source != suppressedRemotePowerKey.source)
        }
        restored.append(contentsOf: originalVoiceMappings)
        if !preservePowerKeyMapping, let originalPowerMapping {
            restored.append(originalPowerMapping)
        }
        return restored
    }
}

struct RemoteVoiceMappingService {
    let registryID: UInt64?
    let locationID: UInt32?
    private let retainedOwner: AnyObject?
    let readMappings: () -> [HIDUsageMapping]
    let setMappings: ([HIDUsageMapping]) -> Bool

    init(
        registryID: UInt64?,
        locationID: UInt32? = nil,
        retainedOwner: AnyObject? = nil,
        readMappings: @escaping () -> [HIDUsageMapping],
        setMappings: @escaping ([HIDUsageMapping]) -> Bool
    ) {
        self.registryID = registryID
        self.locationID = locationID
        self.retainedOwner = retainedOwner
        self.readMappings = readMappings
        self.setMappings = setMappings
    }
}

final class RemoteVoiceFunctionMapper {
    typealias ServiceProvider = () -> [RemoteVoiceMappingService]

    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalMappings {
        let voices: [HIDUsageMapping]
        let power: HIDUsageMapping?
    }

    private let serviceProvider: ServiceProvider
    private let diagnosticLogger: (String) -> Void
    private(set) var mappingOperationID: UInt64 = 0
    private(set) var voiceMappingReadbackMatched: Bool?
    private var preservesPowerKeyMapping = false
    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private(set) var isApplied = false
    private(set) var isPowerKeySuppressed = false
    private(set) var powerSuppressedLocationIDs: Set<UInt32>?
    private(set) var isVoiceKeyNeutralized = false
    private(set) var matchedServiceCount = 0

    var hasMatchingServices: Bool {
        matchedServiceCount > 0
    }

    init(
        diagnosticLogger: @escaping (String) -> Void = AppLogger.shared.write,
        serviceProvider: @escaping ServiceProvider = RemoteVoiceFunctionMapper.systemServices
    ) {
        self.diagnosticLogger = diagnosticLogger
        self.serviceProvider = serviceProvider
    }

    @discardableResult
    func apply(
        suppressPowerKey: Bool = false,
        neutralizeVoiceKey: Bool = false,
        preservePowerKeyMapping: Bool = false
    ) -> Bool {
        mappingOperationID &+= 1
        voiceMappingReadbackMatched = nil
        preservesPowerKeyMapping = preservePowerKeyMapping
        let services = serviceProvider()
        let matchedCount = services.count
        matchedServiceCount = matchedCount
        guard matchedCount > 0 else {
            resetAppliedState()
            diagnosticLogger(
                "VOICE FN MAPPING applied=false neutralized=false power_suppressed=false matched=0 " +
                    "operation_id=\(mappingOperationID) voice_readback=unknown native_delivery=unknown"
            )
            return false
        }

        var snapshots: [Int: [HIDUsageMapping]] = [:]
        var appliedIndices: [Int] = []
        var verifiedVoiceServiceCount = 0
        var newlyStoredRegistryIDs = Set<UInt64>()
        let matchedCountsByLocation = services.reduce(into: [UInt32: Int]()) { counts, service in
            guard let locationID = service.locationID else { return }
            counts[locationID, default: 0] += 1
        }
        var appliedCountsByLocation: [UInt32: Int] = [:]

        for (index, service) in services.enumerated() {
            guard let registryID = service.registryID else {
                if neutralizeVoiceKey {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            let current = service.readMappings()
            snapshots[index] = current
            if originalMappings[registryID] == nil {
                let currentPower = current.first {
                    $0.source == RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey.source
                }
                originalMappings[registryID] = OriginalMappings(
                    voices: current.filter {
                        RemoteVoiceFunctionMappingPolicy.remoteVoiceKeySources.contains($0.source)
                    },
                    power: currentPower == RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                        ? nil
                        : currentPower
                )
                newlyStoredRegistryIDs.insert(registryID)
            }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(
                to: current,
                voiceMappings: neutralizeVoiceKey
                    ? RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKeys
                    : RemoteVoiceFunctionMappingPolicy.remoteVoiceKeys,
                powerMapping: preservePowerKeyMapping ? nil : (suppressPowerKey
                    ? RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                    : originalMappings[registryID]?.power),
                preservePowerKeyMapping: preservePowerKeyMapping
            )
            guard service.setMappings(desired) else {
                if neutralizeVoiceKey {
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        matchedCount: matchedCount
                    )
                    return false
                }
                continue
            }
            appliedIndices.append(index)
            // Readback is diagnostic only. It does not prove native Fn delivery
            // and must not change the established mapping success/fallback policy.
            let source = RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
            if service.readMappings().filter({ $0.source == source }) ==
                desired.filter({ $0.source == source }) {
                verifiedVoiceServiceCount += 1
            }
            if let locationID = service.locationID {
                appliedCountsByLocation[locationID, default: 0] += 1
            }
        }

        let appliedCount = appliedIndices.count
        let allTargetsApplied = appliedCount == matchedCount
        voiceMappingReadbackMatched = allTargetsApplied && verifiedVoiceServiceCount == matchedCount
        let fullySuppressedLocations = Set(matchedCountsByLocation.compactMap { locationID, count in
            appliedCountsByLocation[locationID] == count ? locationID : nil
        })
        isApplied = neutralizeVoiceKey ? allTargetsApplied : appliedCount > 0
        isVoiceKeyNeutralized = neutralizeVoiceKey && allTargetsApplied
        if suppressPowerKey, !fullySuppressedLocations.isEmpty {
            isPowerKeySuppressed = true
            powerSuppressedLocationIDs = fullySuppressedLocations
        } else {
            isPowerKeySuppressed = false
            powerSuppressedLocationIDs = nil
        }
        let suppressionScope = isPowerKeySuppressed
            ? "locations=\(powerSuppressedLocationIDs?.count ?? 0)"
            : "none"
        diagnosticLogger(
            "VOICE FN MAPPING applied=\(isApplied) neutralized=\(isVoiceKeyNeutralized) " +
                "power_suppressed=\(isPowerKeySuppressed) suppression_scope=\(suppressionScope) " +
                "matched=\(matchedCount) applied=\(appliedCount) operation_id=\(mappingOperationID) " +
                "voice_readback=\(voiceMappingReadbackMatched == true ? "matched" : "mismatched") " +
                "voice_readback_verified_services=\(verifiedVoiceServiceCount) " +
                "voice_readback_source=f5 native_delivery=unknown"
        )
        return isApplied
    }

    func restore() {
        guard !originalMappings.isEmpty else {
            resetAppliedState()
            return
        }

        let services = serviceProvider()
        var restoredCount = 0
        for service in services {
            guard let registryID = service.registryID,
                  let original = originalMappings[registryID]
            else { continue }
            let restored = RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMappings: original.voices,
                originalPowerMapping: original.power,
                in: service.readMappings(),
                preservePowerKeyMapping: preservesPowerKeyMapping
            )
            if service.setMappings(restored) {
                restoredCount += 1
            }
        }

        originalMappings.removeAll()
        resetAppliedState()
        diagnosticLogger("VOICE FN MAPPING restored=\(restoredCount)")
    }

    private func rollback(
        services: [RemoteVoiceMappingService],
        snapshots: [Int: [HIDUsageMapping]],
        appliedIndices: [Int],
        newlyStoredRegistryIDs: Set<UInt64>,
        matchedCount: Int
    ) {
        var rollbackCount = 0
        var registryIDsNeedingRestore = Set<UInt64>()
        for index in appliedIndices {
            guard let snapshot = snapshots[index] else { continue }
            if services[index].setMappings(snapshot) {
                rollbackCount += 1
            } else if let registryID = services[index].registryID {
                registryIDsNeedingRestore.insert(registryID)
            }
        }
        newlyStoredRegistryIDs
            .subtracting(registryIDsNeedingRestore)
            .forEach { originalMappings.removeValue(forKey: $0) }
        resetAppliedState()
        diagnosticLogger(
            "VOICE FN MAPPING rollback matched=\(matchedCount) applied=\(appliedIndices.count) " +
                "restored=\(rollbackCount) operation_id=\(mappingOperationID) " +
                "voice_readback=unknown native_delivery=unknown"
        )
    }

    private func resetAppliedState() {
        voiceMappingReadbackMatched = nil
        isApplied = false
        isPowerKeySuppressed = false
        powerSuppressedLocationIDs = nil
        isVoiceKeyNeutralized = false
    }

    static func systemServices() -> [RemoteVoiceMappingService] {
        systemServices(vendor: vendorID, products: [productID])
    }

    static func systemServices(vendor: Int, products: Set<Int>) -> [RemoteVoiceMappingService] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter { isTarget($0, vendorID: vendor, productIDs: products) }.map { service in
            RemoteVoiceMappingService(
                registryID: registryID(service),
                locationID: locationID(service),
                retainedOwner: client,
                readMappings: { readMappings(service) },
                setMappings: { mappings in
                    IOHIDServiceClientSetProperty(
                        service,
                        mappingProperty,
                        mappings.map(\.property) as CFArray
                    )
                }
            )
        }
    }

    private static func isTarget(_ service: IOHIDServiceClient, vendorID: Int, productIDs: Set<Int>) -> Bool {
        let vendor = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDVendorIDKey as CFString
        ) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductIDKey as CFString
        ) as? NSNumber
        return vendor?.intValue == vendorID && product.map { productIDs.contains($0.intValue) } == true
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func locationID(_ service: IOHIDServiceClient) -> UInt32? {
        (IOHIDServiceClientCopyProperty(
            service,
            kIOHIDLocationIDKey as CFString
        ) as? NSNumber)?.uint32Value
    }

    private static func readMappings(_ service: IOHIDServiceClient) -> [HIDUsageMapping] {
        let properties = IOHIDServiceClientCopyProperty(
            service,
            mappingProperty
        ) as? [[String: NSNumber]] ?? []
        return properties.compactMap(HIDUsageMapping.init(property:))
    }
}
