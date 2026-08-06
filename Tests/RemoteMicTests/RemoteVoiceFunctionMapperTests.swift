import Testing
@testable import RemoteMic

@Suite("RC003 hardware Fn mapping")
struct RemoteVoiceFunctionMapperTests {
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

    @Test func suppressesRemotePowerAsHarmlessF20WithoutChangingOtherMappings() {
        let unrelated = HIDUsageMapping(
            source: 0x0000_0007_0000_0004,
            destination: 0x0000_0007_0000_0005
        )
        let stalePower = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey.source,
            destination: 0x0000_0007_0000_006E
        )

        #expect(RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey == HIDUsageMapping(
            source: 0x0000_0007_0000_0066,
            destination: 0x0000_0007_0000_006F
        ))
        #expect(RemoteVoiceFunctionMappingPolicy.applying(
            to: [unrelated, stalePower],
            powerMapping: RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey
        ) == [
            unrelated,
            RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
            RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey,
        ])
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
        let originalPower = HIDUsageMapping(
            source: RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey.source,
            destination: 0x0000_0007_0000_006D
        )

        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: originalVoice,
                originalPowerMapping: originalPower,
                in: [
                    changedUnrelated,
                    RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                    RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey,
                ]
            ) == [changedUnrelated, originalVoice, originalPower]
        )
        #expect(
            RemoteVoiceFunctionMappingPolicy.restoring(
                originalVoiceMapping: nil,
                originalPowerMapping: nil,
                in: [
                    changedUnrelated,
                    RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                    RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey,
                ]
            ) == [changedUnrelated]
        )
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
        #expect(!mapper.isApplied)
        #expect(!mapper.isVoiceKeyNeutralized)
        #expect(missingID.writeCount == 0)
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
    var mappings: [HIDUsageMapping]
    var acceptsWrites: Bool
    var writeCount = 0

    init(registryID: UInt64?, mappings: [HIDUsageMapping], acceptsWrites: Bool = true) {
        self.registryID = registryID
        self.mappings = mappings
        self.acceptsWrites = acceptsWrites
    }

    lazy var service = RemoteVoiceMappingService(
        registryID: registryID,
        readMappings: { [unowned self] in mappings },
        setMappings: { [unowned self] mappings in
            writeCount += 1
            guard acceptsWrites else { return false }
            self.mappings = mappings
            return true
        }
    )
}
