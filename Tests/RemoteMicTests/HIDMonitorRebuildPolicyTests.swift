import Foundation
import Testing
@testable import RemoteMic

@Suite("HID monitor rebuild policy")
struct HIDMonitorRebuildPolicyTests {
    @Test func schedulesOnlyWhenStartedMappingEnabledAndNotStreaming() {
        #expect(HIDMonitorRebuildPolicy.shouldSchedule(
            started: true,
            customMappingEnabled: true,
            isStreaming: false
        ))
        #expect(!HIDMonitorRebuildPolicy.shouldSchedule(
            started: false,
            customMappingEnabled: true,
            isStreaming: false
        ))
        #expect(!HIDMonitorRebuildPolicy.shouldSchedule(
            started: true,
            customMappingEnabled: false,
            isStreaming: false
        ))
        #expect(!HIDMonitorRebuildPolicy.shouldSchedule(
            started: true,
            customMappingEnabled: true,
            isStreaming: true
        ))
    }

    @Test func retriesDeferredRebuildAfterVoiceStop() {
        #expect(HIDMonitorRebuildPolicy.shouldRetryAfterVoiceStop(
            wasDeferred: true,
            started: true,
            customMappingEnabled: true
        ))
        #expect(!HIDMonitorRebuildPolicy.shouldRetryAfterVoiceStop(
            wasDeferred: false,
            started: true,
            customMappingEnabled: true
        ))
        #expect(!HIDMonitorRebuildPolicy.shouldRetryAfterVoiceStop(
            wasDeferred: true,
            started: false,
            customMappingEnabled: true
        ))
        #expect(!HIDMonitorRebuildPolicy.shouldRetryAfterVoiceStop(
            wasDeferred: true,
            started: true,
            customMappingEnabled: false
        ))
    }

    @Test func discoveryAdoptionRebuildsFreshProfileMonitorInsteadOfReusingProbe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("HID MONITOR REBUILD phase=started reason=discovery_adoption"))
        #expect(source.contains("HID MONITOR REBUILD phase=completed reason=discovery_adoption"))
        #expect(source.contains("self.scheduleHIDMonitorRebuildAfterDiscoveryAdoption()"))
        #expect(source.contains("startHIDMonitors(powerKeySuppressed: self.hidPowerKeySuppressed)"))
        #expect(source.contains("hidMonitorRebuildPending"))
        #expect(source.contains("shouldRetryAfterVoiceStop("))
        #expect(!source.contains(
            "self.discoveryHIDMonitor = nil\n                    self.startHIDDiscoveryIfNeeded()"
        ))
    }
}
