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

    static func applying(to existing: [HIDUsageMapping]) -> [HIDUsageMapping] {
        existing.filter { $0.source != remoteVoiceKey.source } + [remoteVoiceKey]
    }

    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        let withoutVoiceKey = current.filter { $0.source != remoteVoiceKey.source }
        guard let originalVoiceMapping else { return withoutVoiceKey }
        return withoutVoiceKey + [originalVoiceMapping]
    }
}

final class RemoteVoiceFunctionMapper {
    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let mappingProperty = "UserKeyMapping" as CFString

    private struct OriginalVoiceMapping {
        let mapping: HIDUsageMapping?
    }

    private var originalMappings: [UInt64: OriginalVoiceMapping] = [:]
    private(set) var isApplied = false

    @discardableResult
    func apply() -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        var matchedCount = 0
        var appliedCount = 0

        for service in services where Self.isTarget(service) {
            matchedCount += 1
            guard let registryID = Self.registryID(service) else { continue }
            let current = Self.readMappings(service)
            if originalMappings[registryID] == nil {
                originalMappings[registryID] = OriginalVoiceMapping(
                    mapping: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
                    }
                )
            }
            let desired = RemoteVoiceFunctionMappingPolicy.applying(to: current)
            if IOHIDServiceClientSetProperty(
                service,
                Self.mappingProperty,
                desired.map(\.property) as CFArray
            ) {
                appliedCount += 1
            }
        }

        isApplied = appliedCount > 0
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) matched=\(matchedCount)"
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
                originalVoiceMapping: original.mapping,
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
