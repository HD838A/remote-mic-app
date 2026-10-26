import Foundation
import Testing
@testable import RemoteMic

@Suite("Remote native key mapping and recovery")
struct RemoteNativeKeyMapperTests {
    private let unrelated = HIDUsageMapping(source: 0x0000_0007_0000_0004, destination: 5)

    @Test func neutralizesOrdinaryRemoteKeysBeforeAnyReportAndIsIdempotent() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let defaults = store.defaults
        let original = [unrelated, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey,
                        RemoteVoiceFunctionMappingPolicy.suppressedRemotePowerKey]
        let device = NativeServiceBox(id: 1, mappings: original)
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: defaults, bootSession: "boot-a"
        )
        #expect(mapper.prepare())
        #expect(device.mappings == [unrelated, RemoteVoiceFunctionMappingPolicy.remoteVoiceKey] + RemoteNativeKeyMapper.mappings.sorted { $0.source < $1.source })
        #expect(mapper.prepare())
        #expect(device.writes == 1)
        mapper.restore()
        #expect(device.mappings.sorted { $0.source < $1.source } == original.sorted { $0.source < $1.source })
    }

    @Test func crashRecoveryRestoresOriginalNativeMappingsAndPreservesExternalChanges() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let defaults = store.defaults
        let tv = HIDUsageMapping(source: RemoteNativeKeyMapper.mappings[0].source, destination: 9)
        let volume = HIDUsageMapping(source: RemoteNativeKeyMapper.mappings[2].source, destination: 10)
        let device = NativeServiceBox(id: 1, mappings: [unrelated, tv, volume])
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: defaults, bootSession: "boot-a"
        )
        #expect(mapper.prepare())
        let externalVolume = HIDUsageMapping(source: volume.source, destination: 11)
        device.mappings = device.mappings.filter { $0.source != volume.source } + [externalVolume]
        device.mappings.append(RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey)
        let restarted = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: defaults, bootSession: "boot-a"
        )
        restarted.restore()
        #expect(Set(device.mappings.map(\.source)).count == 4)
        #expect(device.mappings.contains(tv))
        #expect(device.mappings.contains(externalVolume))
        #expect(device.mappings.contains(unrelated))
        #expect(device.mappings.contains(RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey))
    }

    @Test func restartedActiveMappingKeepsItsRecoveryRecord() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let defaults = store.defaults
        let tv = HIDUsageMapping(source: RemoteNativeKeyMapper.mappings[0].source, destination: 7)
        let device = NativeServiceBox(id: 1, mappings: [tv])
        #expect(RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: defaults, bootSession: "boot-a"
        ).prepare())
        let restarted = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: defaults, bootSession: "boot-a"
        )
        #expect(restarted.prepare())
        restarted.restore()
        #expect(device.mappings == [tv])
    }

    @Test func newBootAndReconnectedServiceDoNotInheritAnotherServicesOriginals() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let defaults = store.defaults
        let firstTV = HIDUsageMapping(source: RemoteNativeKeyMapper.mappings[0].source, destination: 7)
        let secondTV = HIDUsageMapping(source: firstTV.source, destination: 8)
        let first = NativeServiceBox(id: 1, mappings: [firstTV])
        var targets = [first.service]
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { targets }, defaults: defaults, bootSession: "boot-a"
        )
        #expect(mapper.prepare())
        let second = NativeServiceBox(id: 2, mappings: [secondTV])
        targets = [second.service]
        #expect(mapper.prepare())
        mapper.restore()
        #expect(second.mappings == [secondTV])

        // Registry IDs can be reused after reboot. The old snapshot must not apply.
        first.mappings = [secondTV]
        let nextBoot = RemoteNativeKeyMapper(
            serviceProvider: { [first.service] }, defaults: defaults, bootSession: "boot-b"
        )
        #expect(nextBoot.prepare())
        nextBoot.restore()
        #expect(first.mappings == [secondTV])
    }

    @Test func readbackFailureRollsBackOtherServicesWithoutClaimingSuccess() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let defaults = store.defaults
        let first = NativeServiceBox(id: 1, mappings: [unrelated])
        let second = NativeServiceBox(id: 2, mappings: [], ignoreWrites: true)
        var logs: [String] = []
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { [first.service, second.service] }, defaults: defaults,
            bootSession: "boot-a", logger: { logs.append($0) }
        )
        #expect(!mapper.prepare())
        #expect(first.mappings == [unrelated])
        #expect(second.mappings.isEmpty)
        #expect(logs.contains { $0.contains("reason=mapping_not_verified") })
        #expect(!logs.contains { $0.contains("result=verified") })
    }

    @Test func failedRestoreRemainsRecoverableByTheNextInstance() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let defaults = store.defaults
        let first = NativeServiceBox(id: 1, mappings: [unrelated])
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { [first.service] }, defaults: defaults, bootSession: "boot-a"
        )
        #expect(mapper.prepare())
        first.rejectWrites = true
        mapper.restore()
        first.rejectWrites = false
        RemoteNativeKeyMapper(
            serviceProvider: { [first.service] }, defaults: defaults, bootSession: "boot-a"
        ).restore()
        #expect(first.mappings == [unrelated])
    }

    @Test func persistenceFailureUnknownServiceOrBootCannotChangeSystemMappings() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let device = NativeServiceBox(id: 1, mappings: [unrelated])
        let unavailableStore = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: store.defaults,
            bootSession: "boot-a", writeState: { _ in false }
        )
        #expect(!unavailableStore.prepare())
        let unavailableBoot = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: store.defaults, bootSession: nil
        )
        #expect(!unavailableBoot.prepare())
        let unidentified = NativeServiceBox(id: nil, mappings: [])
        #expect(!RemoteNativeKeyMapper(
            serviceProvider: { [unidentified.service] }, defaults: store.defaults, bootSession: "boot-a"
        ).prepare())
        #expect(device.writes == 0)
        #expect(unidentified.writes == 0)
    }

    @Test func recoveryIsSavedBeforeSystemWritesAndMissingServicesAreNotReady() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let device = NativeServiceBox(id: 1, mappings: [unrelated])
        var saved = false
        var targets = [device.service]
        device.beforeWrite = { #expect(saved) }
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { targets }, defaults: store.defaults, bootSession: "boot-a",
            writeState: { _ in saved = true; return true }
        )
        #expect(mapper.prepare())
        targets = []
        #expect(!mapper.prepare())
        // A service arriving later must be configured, even after an earlier success.
        let next = NativeServiceBox(id: 2, mappings: [unrelated])
        targets = [next.service]
        #expect(mapper.prepare())
        #expect(next.mappings == [unrelated] + RemoteNativeKeyMapper.mappings.sorted { $0.source < $1.source })
        mapper.restore()
        #expect(next.mappings == [unrelated])
    }

    @Test func repreparePreservesNewExternalMappingForLaterRestore() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let device = NativeServiceBox(id: 1, mappings: [])
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: store.defaults, bootSession: "boot-a"
        )
        #expect(mapper.prepare())
        let external = HIDUsageMapping(source: RemoteNativeKeyMapper.mappings[0].source, destination: 12)
        device.mappings = device.mappings.filter { $0.source != external.source } + [external]
        #expect(mapper.prepare())
        mapper.restore()
        #expect(device.mappings == [external])
    }

    @Test func permissionRevocationRestoresMappingsWithoutStartingAnEventTap() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let device = NativeServiceBox(id: 1, mappings: [unrelated])
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { [device.service] }, defaults: store.defaults, bootSession: "boot-a"
        )
        #expect(mapper.prepare())
        let monitor = HIDRemoteMonitor(
            settings: AppSettings(defaults: store.defaults), ownsEventSuppressor: false,
            diagnosticLogger: { _ in }, restoreNativeKeys: { mapper.restore() }
        )
        monitor.releaseForRevokedPermissions()
        monitor.releaseForRevokedPermissions()
        #expect(device.mappings == [unrelated])
        // Returning permission can use the same mapper without a stale ready flag.
        #expect(mapper.prepare())
        mapper.restore()
        #expect(device.mappings == [unrelated])
    }

    @Test func everyActivationRequiresFreshVerifiedMappings() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let device = NativeServiceBox(id: 1, mappings: [])
        var targets = [device.service]
        let mapper = RemoteNativeKeyMapper(
            serviceProvider: { targets }, defaults: store.defaults, bootSession: "boot-a"
        )
        let settings = AppSettings(defaults: store.defaults)
        let monitor = HIDRemoteMonitor(
            settings: settings, ownsEventSuppressor: false, diagnosticLogger: { _ in },
            prepareNativeKeys: { mapper.prepare() }
        )
        #expect(monitor.connectSimulatedDevice(fingerprint: "first", profileID: settings.selectedRemoteProfileID))
        monitor.disconnectSimulatedDevice()
        targets = []
        #expect(!monitor.connectSimulatedDevice(fingerprint: "missing", profileID: settings.selectedRemoteProfileID))
        #expect(monitor.deviceFingerprint == nil)
        let next = NativeServiceBox(id: 2, mappings: [], ignoreWrites: true)
        targets = [next.service]
        #expect(!monitor.connectSimulatedDevice(fingerprint: "unverified", profileID: settings.selectedRemoteProfileID))
        #expect(monitor.deviceFingerprint == nil)
        next.ignoreWrites = false
        #expect(monitor.connectSimulatedDevice(fingerprint: "next", profileID: settings.selectedRemoteProfileID))
        monitor.disconnectSimulatedDevice()
        mapper.restore()
        #expect(next.mappings.isEmpty)
    }

    @Test func addingNewCollectionSourcesPreservesAnOriginalZeroMapping() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let source = UInt64(0x0000_000c_0000_00e9)
        let external = HIDUsageMapping(source: source, destination: 0)
        let device = NativeServiceBox(id: 1, mappings: [external, unrelated])
        let mapper = RemoteNativeKeyMapper(
            mappings: [], recoveryKey: "test.siri", serviceProvider: { [device.service] },
            defaults: store.defaults, bootSession: "boot-a"
        )
        #expect(mapper.prepare(additionalSources: [0x0000_000c_0000_0060]))
        #expect(mapper.prepare(additionalSources: [source]))
        mapper.restore()
        #expect(device.mappings == [unrelated, external])
    }

    @Test func hardwareFamiliesHaveIndependentRecoveryRecords() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let source = UInt64(0x0000_000c_0000_00ea)
        let siri = NativeServiceBox(id: 1, mappings: [unrelated])
        let chromecast = NativeServiceBox(id: 2, mappings: [])
        let first = RemoteNativeKeyMapper(
            mappings: [], recoveryKey: "test.siri", serviceProvider: { [siri.service] },
            defaults: store.defaults, bootSession: "boot-a"
        )
        let second = RemoteNativeKeyMapper(
            mappings: [], recoveryKey: "test.chromecast", serviceProvider: { [chromecast.service] },
            defaults: store.defaults, bootSession: "boot-a"
        )
        #expect(first.prepare(additionalSources: [source]))
        #expect(second.prepare(additionalSources: [source]))
        first.restore()
        #expect(!first.isPrepared)
        #expect(second.isPrepared)
        #expect(siri.mappings == [unrelated])
        #expect(chromecast.mappings == [HIDUsageMapping(source: source, destination: 0)])
        // A restarted owner restores the saved consumer mappings without knowing
        // which HID collection appeared before the crash.
        RemoteNativeKeyMapper(
            mappings: [], recoveryKey: "test.chromecast", serviceProvider: { [chromecast.service] },
            defaults: store.defaults, bootSession: "boot-a"
        ).restore()
        #expect(chromecast.mappings.isEmpty)
    }

    @Test func fnMappingCannotReplaceOrRestoreOverNativePowerOwnership() throws {
        let store = try testDefaults()
        defer { store.cleanup() }
        let originalPower = HIDUsageMapping(source: 0x0000_0007_0000_0066, destination: 0x0000_0007_0000_006e)
        let device = NativeServiceBox(id: 1, mappings: [unrelated, originalPower])
        let native = RemoteNativeKeyMapper(serviceProvider: { [device.service] }, defaults: store.defaults, bootSession: "boot-a")
        let voice = RemoteVoiceFunctionMapper(serviceProvider: { [device.service] })
        #expect(voice.apply(preservePowerKeyMapping: true))
        #expect(device.mappings.contains(originalPower))
        #expect(native.prepare())
        let blockedPower = HIDUsageMapping(source: originalPower.source, destination: 0)
        #expect(device.mappings.contains(blockedPower))
        #expect(voice.apply(neutralizeVoiceKey: true, preservePowerKeyMapping: true))
        #expect(device.mappings.contains(blockedPower))
        voice.restore()
        #expect(device.mappings.contains(blockedPower))
        native.restore()
        #expect(device.mappings == [unrelated, originalPower])
    }

    @Test func expandingALegacyRecordDoesNotClaimPreviouslyUnmanagedZeroMappings() throws {
        struct LegacyRecord: Encodable {
            let bootSession: String
            let originals: [UInt64: [HIDUsageMapping]]
        }
        let store = try testDefaults()
        defer { store.cleanup() }
        let tv = HIDUsageMapping(source: 0x0000_0007_0000_0035, destination: 8)
        let external = HIDUsageMapping(source: 0x0000_0007_0000_0050, destination: 0)
        let data = try JSONEncoder().encode(LegacyRecord(bootSession: "boot-a", originals: [1: [tv]]))
        store.defaults.set(data, forKey: "sayall.native-key-mapping-recovery.v1")
        let oldSources: [UInt64] = [0x0000_0007_0000_0035, 0x0000_0007_0000_0080, 0x0000_0007_0000_0081]
        let device = NativeServiceBox(id: 1, mappings: oldSources.map { HIDUsageMapping(source: $0, destination: 0) } + [external])
        let mapper = RemoteNativeKeyMapper(serviceProvider: { [device.service] }, defaults: store.defaults, bootSession: "boot-a")
        #expect(mapper.prepare())
        mapper.restore()
        #expect(device.mappings == [tv, external])
    }

    private func testDefaults() throws -> (defaults: UserDefaults, cleanup: () -> Void) {
        let suite = "RemoteNativeKeyMapperTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }
}

private final class NativeServiceBox {
    let id: UInt64?
    var mappings: [HIDUsageMapping]
    var ignoreWrites: Bool
    var rejectWrites = false
    var writes = 0
    var beforeWrite: () -> Void = {}

    init(id: UInt64?, mappings: [HIDUsageMapping], ignoreWrites: Bool = false) {
        self.id = id
        self.mappings = mappings
        self.ignoreWrites = ignoreWrites
    }

    lazy var service = RemoteVoiceMappingService(
        registryID: id,
        // Deliberately shared: location IDs must not select recovery snapshots.
        locationID: 100,
        readMappings: { [unowned self] in mappings },
        setMappings: { [unowned self] value in
            beforeWrite()
            writes += 1
            guard !rejectWrites else { return false }
            if !ignoreWrites { mappings = value }
            return true
        }
    )
}
