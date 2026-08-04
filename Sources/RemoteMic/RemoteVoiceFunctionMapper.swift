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

    // RC003 exposes its power button as keyboard Power (usage 0x66).
    // Remap it to harmless F20 before macOS can turn it into a sleep event.
    static let suppressedRemotePowerKey = HIDUsageMapping(
        source: 0x0000_0007_0000_0066,
        destination: 0x0000_0007_0000_006F
    )

    static func applying(
        to existing: [HIDUsageMapping],
        powerMapping: HIDUsageMapping? = nil
    ) -> [HIDUsageMapping] {
        var desired = existing.filter {
            $0.source != remoteVoiceKey.source &&
                $0.source != suppressedRemotePowerKey.source
        } + [remoteVoiceKey]
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

final class RemoteVoiceFunctionMapper {
    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalMappings {
        let voice: HIDUsageMapping?
        let power: HIDUsageMapping?
    }

    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private(set) var isApplied = false
    private(set) var isPowerKeySuppressed = false

    @discardableResult
    func apply(suppressPowerKey: Bool = false) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var matchedCount = 0
        var appliedCount = 0

        for service in services where Self.isTarget(service) {
            matchedCount += 1
            guard let registryID = Self.registryID(service) else { continue }
            let current = Self.readMappings(service)
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
            }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(
                to: current,
                powerMapping: suppressPowerKey
                    ? RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
                    : originalMappings[registryID]?.power
            )
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                desired.map(\.property) as CFArray
            ) {
                appliedCount += 1
            }
        }

        isApplied = appliedCount > 0
        isPowerKeySuppressed = suppressPowerKey && matchedCount > 0 && appliedCount == matchedCount
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) power_suppressed=\(isPowerKeySuppressed) " +
                "matched=\(matchedCount)"
        )
        return isApplied
    }

    func restore() {
        guard !originalMappings.isEmpty else {
            isApplied = false
            return
        }

        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var restoredCount = 0

        for service in services where Self.isTarget(service) {
            guard let registryID = Self.registryID(service),
                  let original = originalMappings[registryID]
            else { continue }
            let restored = RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: original.voice,
                originalPowerMapping: original.power,
                in: Self.readMappings(service)
            )
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                restored.map(\.property) as CFArray
            ) {
                restoredCount += 1
            }
        }

        originalMappings.removeAll()
        isApplied = false
        isPowerKeySuppressed = false
        AppLogger.shared.write("VOICE FN MAPPING restored=\(restoredCount)")
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

    private static func readMappings(_ service: IOHIDServiceClient) -> [HIDUsageMapping] {
        let properties = IOHIDServiceClientCopyProperty(
            service,
            mappingProperty
        ) as? [[String: NSNumber]] ?? []
        return properties.compactMap(HIDUsageMapping.init(property:))
    }
}
