import Foundation
import Testing
@testable import RemoteMic

@Suite("Bluetooth lifecycle")
struct BluetoothLifecycleTests {
    @Test func generationAndPhaseRejectStaleCallbacks() {
        let phase = BluetoothLifecyclePhase.connecting(1)
        #expect(phase.acceptsDidConnect(generation: 1))
        #expect(phase.acceptsDidFailToConnect(generation: 1))
        #expect(phase.acceptsDisconnect(generation: 1))
        #expect(!phase.acceptsDisconnect(generation: 2))
        #expect(!phase.acceptsDidConnect(generation: 2))
        #expect(BluetoothLifecyclePhase.disconnecting(1)
            .acceptsDidFailToConnect(generation: 1))
    }

    @Test func initializationCapabilitiesAndReadyAreDistinct() {
        #expect(BluetoothLifecyclePhase.discovering(1)
            .acceptsInitializationCallback(generation: 1))
        #expect(!BluetoothLifecyclePhase.discovering(1)
            .acceptsCapabilities(generation: 1))
        #expect(BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsCapabilities(generation: 1))
        #expect(!BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsProtocolData(generation: 1))
        #expect(BluetoothLifecyclePhase.ready(1)
            .acceptsProtocolData(generation: 1))
    }

    @Test func automaticReconnectBackoffDoublesAndCapsAtSixtySeconds() {
        var policy = BluetoothReconnectPolicy()

        let delays = (0 ..< 7).map { _ in
            policy.nextAutomaticDelay(
                bypassCachedTarget: false,
                jitterUnit: 0.5
            )
        }

        #expect(delays == [3, 6, 12, 24, 48, 60, 60])
        #expect(policy.consecutiveFailureCount == 7)
    }

    @Test func automaticReconnectJitterIsBoundedAndDeterministicForTests() {
        var firstLowJitterPolicy = BluetoothReconnectPolicy()
        var firstHighJitterPolicy = BluetoothReconnectPolicy()
        var lowJitterPolicy = BluetoothReconnectPolicy()
        var highJitterPolicy = BluetoothReconnectPolicy()
        var cappedLowJitterPolicy = BluetoothReconnectPolicy()
        var cappedHighJitterPolicy = BluetoothReconnectPolicy()

        let firstLowDelay = firstLowJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0
        )
        let firstHighDelay = firstHighJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 1
        )
        _ = lowJitterPolicy.nextAutomaticDelay(bypassCachedTarget: false, jitterUnit: 0.5)
        _ = highJitterPolicy.nextAutomaticDelay(bypassCachedTarget: false, jitterUnit: 0.5)

        let lowDelay = lowJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0
        )
        let highDelay = highJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 1
        )
        for _ in 0 ..< 5 {
            _ = cappedLowJitterPolicy.nextAutomaticDelay(
                bypassCachedTarget: false,
                jitterUnit: 0.5
            )
            _ = cappedHighJitterPolicy.nextAutomaticDelay(
                bypassCachedTarget: false,
                jitterUnit: 0.5
            )
        }
        let cappedLowDelay = cappedLowJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0
        )
        let cappedHighDelay = cappedHighJitterPolicy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 1
        )

        #expect(abs(firstLowDelay - 2.7) < 0.000_001)
        #expect(abs(firstHighDelay - 3.3) < 0.000_001)
        #expect(abs(lowDelay - 5.4) < 0.000_001)
        #expect(abs(highDelay - 6.6) < 0.000_001)
        #expect(abs(cappedLowDelay - 54) < 0.000_001)
        #expect(abs(cappedHighDelay - 60) < 0.000_001)
    }

    @Test func failedCachedTargetIsBypassedUntilThePolicyIsReset() {
        var policy = BluetoothReconnectPolicy()
        #expect(policy.allowsCachedTargetRetrieval)

        let delay = policy.nextAutomaticDelay(
            bypassCachedTarget: true,
            jitterUnit: 0.5
        )

        #expect(delay == 3)
        #expect(!policy.allowsCachedTargetRetrieval)
        _ = policy.nextAutomaticDelay(bypassCachedTarget: false, jitterUnit: 0.5)
        #expect(!policy.allowsCachedTargetRetrieval)

        policy.reset()

        #expect(policy.consecutiveFailureCount == 0)
        #expect(policy.allowsCachedTargetRetrieval)
        #expect(policy.nextAutomaticDelay(
            bypassCachedTarget: false,
            jitterUnit: 0.5
        ) == 3)
    }

    @Test func peripheralResetClearsAnyPrecomputedReconnectDelay() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/XiaomiBluetoothBridge.swift"
            ),
            encoding: .utf8
        )
        let resetStart = try #require(source.range(of: "private func resetPeripheral()"))
        let resetEnd = try #require(source.range(
            of: "private func isCurrent",
            range: resetStart.upperBound..<source.endIndex
        ))
        let resetSource = source[resetStart.lowerBound..<resetEnd.lowerBound]

        #expect(resetSource.contains("requestedReconnectDelay = nil"))
    }

    @Test func microphoneRequiresConfirmed16kReadySession() {
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .awaitingCapabilities(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: false,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 8_000
        ))
        #expect(ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
    }

    @Test func directRemoteStreamIsAllowedUnlessAHostOpenWasJustCancelled() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: false,
            streaming: false,
            now: now
        ) == nil)
        #expect(ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: true,
            streaming: true,
            now: now
        ) == nil)

        let cancelledAt = ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: true,
            streaming: false,
            now: now
        )
        #expect(cancelledAt == now)
        #expect(ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledAt,
            now: now.addingTimeInterval(1)
        ))
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: nil,
            now: now
        ))
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledAt,
            now: now.addingTimeInterval(2)
        ))
    }

    @Test func nameMatcherAcceptsApprovedCandidateNames() {
        #expect(XiaomiVoiceRemoteNameMatcher.matches("MI RC"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("mi rc"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("  MI RC  "))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2 Pro"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2 pro"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙语音遥控器"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches(" 小米蓝牙语音遥控器 "))
    }

    @Test func nameMatcherRejectsBlankNilAndSimilarNonTargetNames() {
        #expect(!XiaomiVoiceRemoteNameMatcher.matches(nil))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches(""))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("   "))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("Mi Mouse"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙遥控器"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("MI RC2"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("小米"))
    }
}
