import Foundation
import IOKit.hid
import IOKit.hidsystem

struct HIDUsageMapping: Equatable {
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
    // RC003 exposes its microphone button as keyboard F5 (usage page 7,
    // usage 0x3e). macOS represents the laptop Fn/Globe key as the Apple
    // vendor top-case usage (usage page 0xff, usage 3).
    static let remoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0000_00FF_0000_0003
    )

    // Typeless 等点按式语音工具会被 Fn 长按干扰；此模式下彻底丢弃语音键的
    // 按键事件（目标 usage 0），Fn 点按改由软件注入，避免物理按键按住时干扰注入。
    static let neutralRemoteVoiceKey = HIDUsageMapping(
        source: 0x0000_0007_0000_003E,
        destination: 0x0
    )

    // RC003 exposes its power button as keyboard Power (usage 0x66).
    // Remap it to harmless F20 before macOS can turn it into a sleep event.
    static let suppressedRemotePowerKey = HIDUsageMapping(
        source: 0x0000_0007_0000_0066,
        destination: 0x0000_0007_0000_006F
    )

    static func applying(
        to existing: [HIDUsageMapping],
        voiceMapping: HIDUsageMapping = remoteVoiceKey,
        powerMapping: HIDUsageMapping? = nil
    ) -> [HIDUsageMapping] {
        var desired = existing.filter {
            $0.source != remoteVoiceKey.source &&
                $0.source != suppressedRemotePowerKey.source
        } + [voiceMapping]
        if let powerMapping {
            desired.append(powerMapping)
        }
        return desired
    }

    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        originalPowerMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        var restored = current.filter {
            $0.source != remoteVoiceKey.source &&
                $0.source != suppressedRemotePowerKey.source
        }
        if let originalVoiceMapping {
            restored.append(originalVoiceMapping)
        }
        if let originalPowerMapping {
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
        let voice: HIDUsageMapping?
        let power: HIDUsageMapping?
    }

    private let serviceProvider: ServiceProvider
    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private(set) var isApplied = false
    private(set) var isPowerKeySuppressed = false
    private(set) var powerSuppressedLocationIDs: Set<UInt32>?
    private(set) var isVoiceKeyNeutralized = false

    init(serviceProvider: @escaping ServiceProvider = RemoteVoiceFunctionMapper.systemServices) {
        self.serviceProvider = serviceProvider
    }

    @discardableResult
    func apply(
        suppressPowerKey: Bool = false,
        neutralizeVoiceKey: Bool = false
    ) -> Bool {
        let services = serviceProvider()
        let matchedCount = services.count
        guard matchedCount > 0 else {
            resetAppliedState()
            AppLogger.shared.write(
                "VOICE FN MAPPING applied=false neutralized=false power_suppressed=false matched=0"
            )
            return false
        }

        var snapshots: [Int: [HIDUsageMapping]] = [:]
        var appliedIndices: [Int] = []
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
                    voice: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
                    },
                    power: currentPower == RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                        ? nil
                        : currentPower
                )
                newlyStoredRegistryIDs.insert(registryID)
            }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(
                to: current,
                voiceMapping: neutralizeVoiceKey
                    ? RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
                    : RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                powerMapping: suppressPowerKey
                    ? RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                    : originalMappings[registryID]?.power
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
            if let locationID = service.locationID {
                appliedCountsByLocation[locationID, default: 0] += 1
            }
        }

        let appliedCount = appliedIndices.count
        let allTargetsApplied = appliedCount == matchedCount
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
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) neutralized=\(isVoiceKeyNeutralized) " +
                "power_suppressed=\(isPowerKeySuppressed) suppression_scope=\(suppressionScope) " +
                "matched=\(matchedCount) applied=\(appliedCount)"
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
                originalVoiceMapping: original.voice,
                originalPowerMapping: original.power,
                in: service.readMappings()
            )
            if service.setMappings(restored) {
                restoredCount += 1
            }
        }

        originalMappings.removeAll()
        resetAppliedState()
        AppLogger.shared.write("VOICE FN MAPPING restored=\(restoredCount)")
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
        AppLogger.shared.write(
            "VOICE FN MAPPING rollback matched=\(matchedCount) applied=\(appliedIndices.count) " +
                "restored=\(rollbackCount)"
        )
    }

    private func resetAppliedState() {
        isApplied = false
        isPowerKeySuppressed = false
        powerSuppressedLocationIDs = nil
        isVoiceKeyNeutralized = false
    }

    private static func systemServices() -> [RemoteVoiceMappingService] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter(isTarget).map { service in
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

    private static func isTarget(_ service: IOHIDServiceClient) -> Bool {
        let vendor = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDVendorIDKey as CFString
        ) as? NSNumber
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductIDKey as CFString
        ) as? NSNumber
        return vendor?.intValue == vendorID && product?.intValue == productID
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
