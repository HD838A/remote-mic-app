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

    static func remoteVoiceKey(
        for modifier: StandaloneKeyboardModifier
    ) -> HIDUsageMapping {
        // Keyboard usage page 0x07 reserves 0xE0...0xE7 for the eight
        // left/right modifier keys. Mapping the RC003 service here produces
        // a hardware-level modifier edge that strict global hotkey listeners
        // accept, unlike a synthesized CGEvent.
        let destination: UInt64
        switch modifier {
        case .leftControl: destination = 0x0000_0007_0000_00E0
        case .leftShift: destination = 0x0000_0007_0000_00E1
        case .leftOption: destination = 0x0000_0007_0000_00E2
        case .leftCommand: destination = 0x0000_0007_0000_00E3
        case .rightControl: destination = 0x0000_0007_0000_00E4
        case .rightShift: destination = 0x0000_0007_0000_00E5
        case .rightOption: destination = 0x0000_0007_0000_00E6
        case .rightCommand: destination = 0x0000_0007_0000_00E7
        case .function: destination = remoteVoiceKey.destination
        }
        return HIDUsageMapping(source: remoteVoiceKey.source, destination: destination)
    }

    // RC003 also exposes every physical button through its keyboard HID
    // interface. Those native events must be discarded while custom mapping
    // is enabled; otherwise macOS and third-party global hotkey listeners can
    // act on the original key in addition to SayAll's configured action.
    static let neutralRemoteButtonMappings: [HIDUsageMapping] = RemoteButton.allCases.map {
        HIDUsageMapping(
            source: 0x0000_0007_0000_0000 | UInt64($0.hidUsage),
            destination: 0x0
        )
    }

    static let nativeButtonSources = Set(neutralRemoteButtonMappings.map(\.source))
    static let managedSources = nativeButtonSources.union([remoteVoiceKey.source])

    static func applying(
        to existing: [HIDUsageMapping],
        voiceMapping: HIDUsageMapping = remoteVoiceKey,
        nativeButtonMappings: [HIDUsageMapping] = []
    ) -> [HIDUsageMapping] {
        existing.filter { !managedSources.contains($0.source) }
            + [voiceMapping]
            + nativeButtonMappings
    }

    static func restoring(
        originalVoiceMapping: HIDUsageMapping?,
        originalNativeButtonMappings: [HIDUsageMapping],
        in current: [HIDUsageMapping]
    ) -> [HIDUsageMapping] {
        var restored = current.filter { !managedSources.contains($0.source) }
        if let originalVoiceMapping {
            restored.append(originalVoiceMapping)
        }
        restored.append(contentsOf: originalNativeButtonMappings)
        return restored
    }

    static func managedMappingsMatch(
        _ expected: [HIDUsageMapping],
        in actual: [HIDUsageMapping]
    ) -> Bool {
        func sortedManaged(_ mappings: [HIDUsageMapping]) -> [HIDUsageMapping] {
            mappings
                .filter { managedSources.contains($0.source) }
                .sorted {
                    $0.source == $1.source
                        ? $0.destination < $1.destination
                        : $0.source < $1.source
                }
        }
        return sortedManaged(expected) == sortedManaged(actual)
    }
}

enum RemoteVoiceKeyMappingMode: Equatable {
    case function
    case neutralized
    case standaloneModifier(StandaloneKeyboardModifier)

    var mapping: HIDUsageMapping {
        switch self {
        case .function:
            return RemoteVoiceFunctionMappingPolicy.remoteVoiceKey
        case .neutralized:
            return RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
        case let .standaloneModifier(modifier):
            return RemoteVoiceFunctionMappingPolicy.remoteVoiceKey(for: modifier)
        }
    }

    var requiresCompleteApplication: Bool {
        self != .function
    }

    var logName: String {
        switch self {
        case .function: return "function"
        case .neutralized: return "neutralized"
        case let .standaloneModifier(modifier): return "modifier_\(modifier.rawValue)"
        }
    }
}

struct RemoteHIDMappingAudit: Equatable {
    let matchedServiceCount: Int
    let correctlyMappedServiceCount: Int
    let nativeButtonSuppressedLocationIDs: Set<UInt32>?

    var isComplete: Bool {
        matchedServiceCount > 0 && correctlyMappedServiceCount == matchedServiceCount
    }

    var areNativeButtonEventsSuppressed: Bool {
        isComplete && nativeButtonSuppressedLocationIDs?.isEmpty == false
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
        let nativeButtons: [HIDUsageMapping]
    }

    private let serviceProvider: ServiceProvider
    private var originalMappings: [UInt64: OriginalMappings] = [:]
    private(set) var isApplied = false
    private(set) var areNativeButtonEventsSuppressed = false
    private(set) var nativeButtonSuppressedLocationIDs: Set<UInt32>?
    private(set) var isVoiceKeyNeutralized = false
    private(set) var matchedServiceCount = 0

    var hasMatchingServices: Bool {
        matchedServiceCount > 0
    }
    private(set) var isVoiceKeyMappingComplete = false
    private(set) var appliedVoiceKeyMappingMode: RemoteVoiceKeyMappingMode?

    init(serviceProvider: @escaping ServiceProvider = RemoteVoiceFunctionMapper.systemServices) {
        self.serviceProvider = serviceProvider
    }

    @discardableResult
    func apply(
        suppressNativeButtonEvents: Bool = false,
        voiceKeyMappingMode: RemoteVoiceKeyMappingMode = .function
    ) -> Bool {
        let voiceMapping = voiceKeyMappingMode.mapping
        let requiresCompleteVoiceMapping = voiceKeyMappingMode.requiresCompleteApplication
        let services = serviceProvider()
        let matchedCount = services.count
        matchedServiceCount = matchedCount
        guard matchedCount > 0 else {
            resetAppliedState()
            AppLogger.shared.write(
                "VOICE FN MAPPING applied=false mode=\(voiceKeyMappingMode.logName) " +
                    "native_buttons_suppressed=false matched=0"
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
                if requiresCompleteVoiceMapping {
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
                originalMappings[registryID] = OriginalMappings(
                    voice: current.first {
                        $0.source == RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source
                    },
                    nativeButtons: current.filter {
                        RemoteVoiceFunctionMappingPolicy.nativeButtonSources.contains($0.source) &&
                            $0.destination != 0
                    }
                )
                newlyStoredRegistryIDs.insert(registryID)
            }
            let nativeButtonMappings = suppressNativeButtonEvents
                ? RemoteVoiceFunctionMappingPolicy.neutralRemoteButtonMappings
                : originalMappings[registryID]?.nativeButtons ?? []
            let desired = RemoteVoiceFunctionMappingPolicy.applying(
                to: current,
                voiceMapping: voiceMapping,
                nativeButtonMappings: nativeButtonMappings
            )
            guard service.setMappings(desired) else {
                if requiresCompleteVoiceMapping {
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
            guard RemoteVoiceFunctionMappingPolicy.managedMappingsMatch(
                desired,
                in: service.readMappings()
            ) else {
                let restored = service.setMappings(current) &&
                    RemoteVoiceFunctionMappingPolicy.managedMappingsMatch(
                        current,
                        in: service.readMappings()
                    )
                if requiresCompleteVoiceMapping {
                    var registryIDsNeedingRestore = Set<UInt64>()
                    if !restored {
                        registryIDsNeedingRestore.insert(registryID)
                    }
                    rollback(
                        services: services,
                        snapshots: snapshots,
                        appliedIndices: appliedIndices,
                        newlyStoredRegistryIDs: newlyStoredRegistryIDs,
                        registryIDsNeedingRestore: registryIDsNeedingRestore,
                        matchedCount: matchedCount
                    )
                    return false
                }
                if restored {
                    originalMappings.removeValue(forKey: registryID)
                    newlyStoredRegistryIDs.remove(registryID)
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
        isApplied = requiresCompleteVoiceMapping ? allTargetsApplied : appliedCount > 0
        isVoiceKeyMappingComplete = allTargetsApplied
        appliedVoiceKeyMappingMode = isApplied ? voiceKeyMappingMode : nil
        isVoiceKeyNeutralized = appliedVoiceKeyMappingMode == .neutralized
        if suppressNativeButtonEvents, !fullySuppressedLocations.isEmpty {
            areNativeButtonEventsSuppressed = true
            nativeButtonSuppressedLocationIDs = fullySuppressedLocations
        } else {
            areNativeButtonEventsSuppressed = false
            nativeButtonSuppressedLocationIDs = nil
        }
        let suppressionScope = areNativeButtonEventsSuppressed
            ? "locations=\(nativeButtonSuppressedLocationIDs?.count ?? 0)"
            : "none"
        AppLogger.shared.write(
            "VOICE FN MAPPING applied=\(isApplied) mode=\(voiceKeyMappingMode.logName) " +
                "destination=0x\(String(voiceMapping.destination, radix: 16)) " +
                "complete=\(isVoiceKeyMappingComplete) neutralized=\(isVoiceKeyNeutralized) " +
                "native_buttons_suppressed=\(areNativeButtonEventsSuppressed) " +
                "native_button_mappings=\(suppressNativeButtonEvents ? RemoteVoiceFunctionMappingPolicy.neutralRemoteButtonMappings.count : 0) " +
                "suppression_scope=\(suppressionScope) " +
                "matched=\(matchedCount) applied=\(appliedCount)"
        )
        return isApplied
    }

    /// Verifies the live HID registry without mutating it. A delayed keyboard
    /// service can appear after the first successful write, so cached apply
    /// state alone is not sufficient to decide that every physical button is
    /// safely mapped.
    func audit(
        suppressNativeButtonEvents: Bool = false,
        voiceKeyMappingMode: RemoteVoiceKeyMappingMode = .function
    ) -> RemoteHIDMappingAudit {
        let services = serviceProvider()
        let matchedCountsByLocation = services.reduce(into: [UInt32: Int]()) { counts, service in
            guard let locationID = service.locationID else { return }
            counts[locationID, default: 0] += 1
        }
        var correctCountsByLocation: [UInt32: Int] = [:]
        var correctlyMappedServiceCount = 0

        for service in services {
            guard service.registryID != nil else { continue }
            let actual = service.readMappings()
            let expected = RemoteVoiceFunctionMappingPolicy.applying(
                to: actual,
                voiceMapping: voiceKeyMappingMode.mapping,
                nativeButtonMappings: suppressNativeButtonEvents
                    ? RemoteVoiceFunctionMappingPolicy.neutralRemoteButtonMappings
                    : []
            )
            guard RemoteVoiceFunctionMappingPolicy.managedMappingsMatch(expected, in: actual) else {
                continue
            }
            correctlyMappedServiceCount += 1
            if let locationID = service.locationID {
                correctCountsByLocation[locationID, default: 0] += 1
            }
        }

        let fullySuppressedLocations = Set(matchedCountsByLocation.compactMap { locationID, count in
            correctCountsByLocation[locationID] == count ? locationID : nil
        })
        return RemoteHIDMappingAudit(
            matchedServiceCount: services.count,
            correctlyMappedServiceCount: correctlyMappedServiceCount,
            nativeButtonSuppressedLocationIDs: suppressNativeButtonEvents && !fullySuppressedLocations.isEmpty
                ? fullySuppressedLocations
                : nil
        )
    }

    func adoptVerifiedAudit(
        _ audit: RemoteHIDMappingAudit,
        voiceKeyMappingMode: RemoteVoiceKeyMappingMode
    ) {
        guard audit.isComplete else { return }
        isApplied = true
        isVoiceKeyMappingComplete = true
        appliedVoiceKeyMappingMode = voiceKeyMappingMode
        isVoiceKeyNeutralized = voiceKeyMappingMode == .neutralized
        areNativeButtonEventsSuppressed = audit.areNativeButtonEventsSuppressed
        nativeButtonSuppressedLocationIDs = audit.nativeButtonSuppressedLocationIDs
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
                originalNativeButtonMappings: original.nativeButtons,
                in: service.readMappings()
            )
            if service.setMappings(restored),
               RemoteVoiceFunctionMappingPolicy.managedMappingsMatch(
                   restored,
                   in: service.readMappings()
               )
            {
                restoredCount += 1
                originalMappings.removeValue(forKey: registryID)
            }
        }

        resetAppliedState()
        AppLogger.shared.write(
            "VOICE FN MAPPING restored=\(restoredCount) pending=\(originalMappings.count)"
        )
    }

    private func rollback(
        services: [RemoteVoiceMappingService],
        snapshots: [Int: [HIDUsageMapping]],
        appliedIndices: [Int],
        newlyStoredRegistryIDs: Set<UInt64>,
        registryIDsNeedingRestore initialRegistryIDsNeedingRestore: Set<UInt64> = [],
        matchedCount: Int
    ) {
        var rollbackCount = 0
        var registryIDsNeedingRestore = initialRegistryIDsNeedingRestore
        for index in appliedIndices {
            guard let snapshot = snapshots[index] else { continue }
            if services[index].setMappings(snapshot),
               RemoteVoiceFunctionMappingPolicy.managedMappingsMatch(
                   snapshot,
                   in: services[index].readMappings()
               )
            {
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
        areNativeButtonEventsSuppressed = false
        nativeButtonSuppressedLocationIDs = nil
        isVoiceKeyNeutralized = false
        isVoiceKeyMappingComplete = false
        appliedVoiceKeyMappingMode = nil
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
