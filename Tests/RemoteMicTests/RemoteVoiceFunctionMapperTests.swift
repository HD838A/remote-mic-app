import Testing
@testable import RemoteMic

@Suite("RC003 hardware Fn mapping")
struct RemoteVoiceFunctionMapperTests {
    @Test func commandBluetoothStreamRequiresCompleteCurrentNeutralization() {
        let original = [HIDUsageMapping(source: 0x0000_0007_0000_0004, destination: 5)]
        let first = MappingServiceBox(registryID: 1, mappings: original)
        let second = MappingServiceBox(registryID: 2, mappings: original, acceptsWrites: false)
        var services: [RemoteVoiceMappingService] = []
        let mapper = RemoteVoiceFunctionMapper { services }

        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .leftCommand,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))
        #expect(BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceFnTapModeEnabled: true,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))

        services = [first.service, second.service]
        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .rightCommand,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))

        second.acceptsWrites = true
        #expect(mapper.apply(neutralizeVoiceKey: true))
        #expect(BridgeAppModel.canStartBluetoothVoice(
            mode: .leftCommand,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))
        #expect(BridgeAppModel.canStartBluetoothVoice(
            mode: .rightCommand,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))
        #expect(BridgeAppModel.canStartBluetoothVoice(
            mode: .function,
            voiceFnTapModeEnabled: true,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))

        let newlyEnumeratedFailure = MappingServiceBox(
            registryID: 3,
            mappings: original,
            acceptsWrites: false
        )
        services.append(newlyEnumeratedFailure.service)
        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(!BridgeAppModel.canStartBluetoothVoice(
            mode: .rightCommand,
            isVoiceKeyNeutralized: mapper.isVoiceKeyNeutralized
        ))
    }

    @Test func replacesOnlyTheRemoteF5Mapping() {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        let stale = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )

        #expect(
            RemoteVoiceFunctionMappingPolicy.applying(to: [unrelated, stale]) == [
                unrelated,
                RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
            ]
        )
    }

    @Test func isIdempotentAndRoundTripsItsProperty() {
        let mapping = RemoteVoiceFunctionMappingPolicy.remoteVoiceKey
        #expect(RemoteVoiceFunctionMappingPolicy.applying(to: [mapping]) == [mapping])
        #expect(HIDUsageMapping(property: mapping.property) == mapping)
    }

    @Test func neutralizesEveryNativeRemoteButtonWithoutChangingOtherMappings() {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        let staleTV = HIDUsageMapping(
            source: 0x0000_0007_0000_0035,
            destination: 0x0000_0007_0000_0036
        )

        let neutralMappings = RemoteVoiceFunctionMappingPolicy.neutralRemoteButtonMappings
        #expect(neutralMappings.count == RemoteButton.allCases.count)
        #expect(Set(neutralMappings.map(\.source)).count == RemoteButton.allCases.count)
        #expect(neutralMappings.allSatisfy { $0.destination == 0 })
        #expect(neutralMappings.contains(HIDUsageMapping(
            source: 0x0000_0007_0000_0035,
            destination: 0
        )))
        #expect(RemoteVoiceFunctionMappingPolicy.applying(
            to: [unrelated, staleTV],
            nativeButtonMappings: neutralMappings
        ) == [unrelated, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey] + neutralMappings)
    }

    @Test func restorePreservesUnrelatedChangesMadeWhileRunning() {
        let originalVoice = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.remoteVoiceKey.source,
            destination: 0x0000_0007_0000_00E1
        )
        let changedUnrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0006
        )
        let originalTV = HIDUsageMapping(
            source: 0x0000_0007_0000_0035,
            destination: 0x0000_0007_0000_006D
        )
        let neutralMappings = RemoteVoiceFunctionMappingPolicy.neutralRemoteButtonMappings

        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: originalVoice,
                originalNativeButtonMappings: [originalTV],
                in: [
                    changedUnrelated,
                    RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                ] + neutralMappings
            ) == [changedUnrelated, originalVoice, originalTV]
        )
        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: nil,
                originalNativeButtonMappings: [],
                in: [
                    changedUnrelated,
                    RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                ] + neutralMappings
            ) == [changedUnrelated]
        )
    }

    @Test func rejectsAWriteThatIsNotVisibleInTheServiceReadback() {
        let original = [HIDUsageMapping(source: 0x0000_0007_0000_0004, destination: 5)]
        var writeCount = 0
        let service = RemoteVoiceMappingService(
            registryID: 1,
            locationID: 101,
            readMappings: { original },
            setMappings: { _ in
                writeCount += 1
                return true
            }
        )
        let mapper = RemoteVoiceFunctionMapper { [service] }

        #expect(!mapper.apply(
            suppressNativeButtonEvents: true,
            neutralizeVoiceKey: true
        ))
        #expect(!mapper.isApplied)
        #expect(!mapper.areNativeButtonEventsSuppressed)
        #expect(writeCount == 2)
    }

    @Test func neutralizationRequiresEveryTargetAndRollsBackPartialSuccess() {
        let original = [HIDUsageMapping(source: 0x0000_0007_0000_0004, destination: 5)]
        let first = MappingServiceBox(registryID: 1, mappings: original)
        let second = MappingServiceBox(registryID: 2, mappings: original, acceptsWrites: false)
        let mapper = RemoteVoiceFunctionMapper { [first.service, second.service] }

        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(!mapper.isVoiceKeyNeutralized)
        #expect(first.mappings == original)
        #expect(first.writeCount == 2)
        #expect(second.writeCount == 1)
    }

    @Test func neutralizationFailsWhenThereIsNoCompleteTargetService() {
        let missingID = MappingServiceBox(registryID: nil, mappings: [])
        let mapper = RemoteVoiceFunctionMapper { [missingID.service] }

        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(mapper.hasMatchingServices)
        #expect(!mapper.isApplied)
        #expect(!mapper.isVoiceKeyNeutralized)
        #expect(missingID.writeCount == 0)
    }

    @Test func reportsWhenNoMatchingRemoteServiceIsPresent() {
        let mapper = RemoteVoiceFunctionMapper { [] }

        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(!mapper.hasMatchingServices)
        #expect(mapper.matchedServiceCount == 0)
        #expect(!mapper.isVoiceKeyNeutralized)
    }

    @Test func failedRollbackKeepsTheOriginalMappingForLaterRestore() {
        let original = [HIDUsageMapping(source: 0x0000_0007_0000_0004, destination: 5)]
        var firstMappings = original
        var firstWriteResults = [true, false, true]
        let first = RemoteVoiceMappingService(
            registryID: 1,
            readMappings: { firstMappings },
            setMappings: { mappings in
                guard !firstWriteResults.isEmpty else { return false }
                guard firstWriteResults.removeFirst() else { return false }
                firstMappings = mappings
                return true
            }
        )
        let second = MappingServiceBox(registryID: 2, mappings: original, acceptsWrites: false)
        let mapper = RemoteVoiceFunctionMapper { [first, second.service] }

        #expect(!mapper.apply(neutralizeVoiceKey: true))
        #expect(firstMappings == [
            original[0],
            RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey,
        ])

        mapper.restore()

        #expect(firstMappings == original)
    }

    @Test func partialNativeButtonSuppressionOnlyAllowsFullyMappedDeviceLocations() {
        let first = MappingServiceBox(registryID: 1, locationID: 101, mappings: [])
        let duplicateFailure = MappingServiceBox(
            registryID: 2,
            locationID: 101,
            mappings: [],
            acceptsWrites: false
        )
        let safe = MappingServiceBox(registryID: 3, locationID: 202, mappings: [])
        let unknown = MappingServiceBox(registryID: 4, locationID: nil, mappings: [])
        let mapper = RemoteVoiceFunctionMapper {
            [first.service, duplicateFailure.service, safe.service, unknown.service]
        }

        #expect(mapper.apply(suppressNativeButtonEvents: true))
        #expect(mapper.areNativeButtonEventsSuppressed)
        #expect(mapper.nativeButtonSuppressedLocationIDs == Set([202]))
    }

    @Test func nativeButtonSuppressionWithoutADeviceLocationFailsClosed() {
        let unknown = MappingServiceBox(registryID: 1, locationID: nil, mappings: [])
        let mapper = RemoteVoiceFunctionMapper { [unknown.service] }

        #expect(mapper.apply(suppressNativeButtonEvents: true))
        #expect(!mapper.areNativeButtonEventsSuppressed)
        #expect(mapper.nativeButtonSuppressedLocationIDs == nil)
    }

    @Test func mappingServiceRetainsItsHIDClientOwnerForItsLifetime() {
        var owner: MappingServiceOwner? = MappingServiceOwner()
        let ownerReference = WeakMappingServiceOwnerReference(owner)
        var service: RemoteVoiceMappingService? = RemoteVoiceMappingService(
            registryID: 1,
            retainedOwner: owner,
            readMappings: { [] },
            setMappings: { _ in true }
        )

        owner = nil

        #expect(service?.registryID == 1)
        #expect(ownerReference.value != nil)

        service = nil

        #expect(ownerReference.value == nil)
    }
}

private final class MappingServiceOwner {}

private final class WeakMappingServiceOwnerReference {
    weak var value: MappingServiceOwner?

    init(_ value: MappingServiceOwner?) {
        self.value = value
    }
}

private final class MappingServiceBox {
    let registryID: UInt64?
    let locationID: UInt32?
    var mappings: [HIDUsageMapping]
    var acceptsWrites: Bool
    var writeCount = 0

    init(
        registryID: UInt64?,
        locationID: UInt32? = nil,
        mappings: [HIDUsageMapping],
        acceptsWrites: Bool = true
    ) {
        self.registryID = registryID
        self.locationID = locationID
        self.mappings = mappings
        self.acceptsWrites = acceptsWrites
    }

    lazy var service = RemoteVoiceMappingService(
        registryID: registryID,
        locationID: locationID,
        readMappings: { [unowned self] in mappings },
        setMappings: { [unowned self] mappings in
            writeCount += 1
            guard acceptsWrites else { return false }
            self.mappings = mappings
            return true
        }
    )
}
