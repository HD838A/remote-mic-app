import Foundation
import Testing
@testable import RemoteMic

@Suite("System remote runtime lifecycle")
struct SystemRemoteRuntimeLifecycleTests {
    @Test func darkWakeThatReturnsToSleepNeverResumesRemoteRuntime() throws {
        var state = SystemRemoteRuntimeLifecycleState()

        #expect(state.handle(.systemWillSleep) == .suspend)
        let generation = try #require(state.handle(.systemDidWake).resumeGeneration)
        #expect(state.phase == .wakePending)
        #expect(state.handle(.systemWillSleep) == .cancelPendingResume)
        #expect(state.phase == .sleeping)
        #expect(state.wakeGraceElapsed(generation: generation) == .none)
        #expect(!state.isActive)
    }

    @Test func stableWakeResumesExactlyOnceAfterGrace() throws {
        var state = SystemRemoteRuntimeLifecycleState()

        #expect(state.handle(.systemWillSleep) == .suspend)
        let generation = try #require(state.handle(.systemDidWake).resumeGeneration)
        #expect(state.wakeGraceElapsed(generation: generation) == .resume)
        #expect(state.isActive)
        #expect(state.wakeGraceElapsed(generation: generation) == .none)
    }

    @Test func userVisibleWakeResumesPendingRuntimeImmediately() throws {
        var state = SystemRemoteRuntimeLifecycleState()

        #expect(state.handle(.systemWillSleep) == .suspend)
        let generation = try #require(state.handle(.systemDidWake).resumeGeneration)
        #expect(state.confirmUserVisibleWake() == .resume)
        #expect(state.isActive)
        #expect(state.wakeGraceElapsed(generation: generation) == .none)
    }

    @Test func activeUserSessionResumesPendingWakeWithoutWaitingForGrace() throws {
        var state = SystemRemoteRuntimeLifecycleState()

        #expect(state.handle(.systemWillSleep) == .suspend)
        let generation = try #require(state.handle(.systemDidWake).resumeGeneration)
        #expect(state.handle(.sessionDidBecomeActive) == .resume)
        #expect(state.isActive)
        #expect(state.wakeGraceElapsed(generation: generation) == .none)
    }

    @Test func wakeVisibilityFailsClosedForUnknownClamshellState() {
        #expect(SystemWakeVisibilityPolicy.isUserVisible(
            displayActive: true,
            displayAsleep: false,
            clamshellClosed: false
        ))
        #expect(!SystemWakeVisibilityPolicy.isUserVisible(
            displayActive: true,
            displayAsleep: false,
            clamshellClosed: true
        ))
        #expect(!SystemWakeVisibilityPolicy.isUserVisible(
            displayActive: true,
            displayAsleep: false,
            clamshellClosed: nil
        ))
        #expect(!SystemWakeVisibilityPolicy.isUserVisible(
            displayActive: true,
            displayAsleep: true,
            clamshellClosed: false
        ))
    }

    @Test func duplicateSystemEventsAndStaleGenerationsAreIgnored() throws {
        var state = SystemRemoteRuntimeLifecycleState()

        #expect(state.handle(.systemWillSleep) == .suspend)
        #expect(state.handle(.systemWillSleep) == .none)
        let generation = try #require(state.handle(.systemDidWake).resumeGeneration)
        #expect(state.handle(.systemDidWake) == .none)
        #expect(state.wakeGraceElapsed(generation: generation &+ 1) == .none)
        #expect(state.wakeGraceElapsed(generation: generation) == .resume)
    }

    @Test func productionWiringSuspendsBLEAndHIDUntilConfirmedWake() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let bridgeSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/XiaomiBluetoothBridge.swift"),
            encoding: .utf8
        )

        #expect(modelSource.contains("handleSystemRemoteRuntimeLifecycle(event)"))
        #expect(modelSource.contains("bluetoothBridges.values.forEach { $0.suspendForSystemSleep() }"))
        #expect(modelSource.contains("discoveryBluetoothBridge?.suspendForSystemSleep()"))
        #expect(modelSource.contains("stopHIDMonitors()"))
        #expect(modelSource.contains("cancelHIDMappingRecovery(reason: \"system_sleep\")"))
        #expect(modelSource.contains("scheduleRemoteRuntimeResume(generation:"))
        #expect(modelSource.contains("if !remoteWakeManaged,"))
        #expect(modelSource.contains("guard systemRemoteRuntimeState.isActive else"))
        #expect(bridgeSource.contains("func suspendForSystemSleep()"))
        #expect(bridgeSource.contains("finishAttempt(reconnectAfter: nil)"))
    }

    @Test func hidMappingRecoveryCannotRunDuringSleepOrWakePending() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let scheduleStart = try #require(
            source.range(of: "private func scheduleHIDMappingRecoveryIfNeeded()")
        )
        let scheduleEnd = try #require(source.range(
            of: "private func completeHIDMappingRecoveryIfNeeded()",
            range: scheduleStart.upperBound..<source.endIndex
        ))
        let scheduleSource = source[scheduleStart.lowerBound..<scheduleEnd.lowerBound]

        #expect(scheduleSource.contains("guard systemRemoteRuntimeState.isActive else"))
        #expect(scheduleSource.contains("self.systemRemoteRuntimeState.isActive"))
    }

    @Test func systemSleepEndsBluetoothVoiceBeforeDetachingTheBridge() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let suspendStart = try #require(source.range(of: "private func suspendRemoteRuntime("))
        let suspendEnd = try #require(source.range(
            of: "private func scheduleRemoteRuntimeResume(",
            range: suspendStart.upperBound..<source.endIndex
        ))
        let suspendSource = source[suspendStart.lowerBound..<suspendEnd.lowerBound]
        let clearActive = try #require(suspendSource.range(of: "bluetoothVoiceActive = false"))
        let clearIdentifier = try #require(
            suspendSource.range(of: "activeBluetoothVoiceDeviceIdentifier = nil")
        )
        let detachBridge = try #require(
            suspendSource.range(of: "bluetoothBridges.values.forEach { $0.suspendForSystemSleep() }")
        )

        #expect(clearActive.lowerBound < detachBridge.lowerBound)
        #expect(clearIdentifier.lowerBound < detachBridge.lowerBound)
        #expect(suspendSource.contains("voiceFnTapSession.shutdown()"))
        #expect(suspendSource.contains("endVoiceSessionIfNeeded(flushAudio: false)"))
    }
}

private extension SystemRemoteRuntimeAction {
    var resumeGeneration: UInt64? {
        guard case let .scheduleResume(generation) = self else { return nil }
        return generation
    }
}
