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
}
