import AVFoundation
import CoreAudio
import Foundation
import SayAllMacRemoteCore
import Testing
@testable import RemoteMic

/// The idle audio rebind loop.
///
/// Field log, one cycle, repeating roughly once a second with `engine_running=false` throughout
/// and the device correctly bound the whole time:
///
/// ```
/// AUDIO RECOVERY begin id=2028 reason=engine_configuration_change ... bound_to_selected=true
/// AUDIO REBIND begin reason=recovery_engine_configuration_change
/// AUDIO CONFIGURE begin target={name=MiRemoteV 2ch id=88}
/// AUDIO READY target={name=MiRemoteV 2ch id=88}
/// AUDIO REBIND finished success=true
/// AUDIO RECOVERY completed id=2028
/// AUDIO ENGINE configuration_changed generation=4013   <- the rebind's own doing
/// AUDIO RECOVERY scheduled id=2029 reason=engine_configuration_change
/// ```
///
/// The suppression that should have stopped this required the engine to be *running*
/// (`isReadyForTestTone`), so it was unavailable exactly while idle — which is when the
/// self-inflicted changes happen and when there is nothing to recover. 48 cycles per minute,
/// indefinitely, rotating a 4 MB runtime log every 20 minutes.
@Suite("Audio engine configuration change policy")
struct AudioConfigurationChangeRecoveryTests {
    /// The regression: a bound, idle, empty output must be ignored even if the engine is not
    /// currently running. Under the old condition this returned "recover", which is the loop.
    @Test func aBoundIdleChangeWithNoQueuedAudioNeedsNoRecovery() {
        #expect(!AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: true,
            configurationHealthy: false,
            hasActiveAudioSource: false,
            pendingVoiceBufferCount: 0
        ))
    }

    /// The positive control, without which the fix could be "never recover from anything".
    @Test func aChangeThatMovedTheEngineOffTheSelectedDeviceNeedsRecovery() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: false,
            configurationHealthy: false,
            hasActiveAudioSource: false,
            pendingVoiceBufferCount: 0
        ))
    }

    /// Unknown state has to fail towards recovery: it is not evidence that the binding is fine.
    @Test func anUnknownBindingNeedsRecovery() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: nil,
            configurationHealthy: false,
            hasActiveAudioSource: false,
            pendingVoiceBufferCount: 0
        ))
    }

    /// A healthy output needs no recovery even if a source is active; this prevents a delayed
    /// self-notification from disrupting the session that triggered a successful rebind.
    @Test func aHealthyBoundOutputNeedsNoRecovery() {
        #expect(!AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: true,
            configurationHealthy: true,
            hasActiveAudioSource: true,
            pendingVoiceBufferCount: 1
        ))
    }

    /// Current main deliberately recovers a stopped player during live voice delivery. The idle
    /// loop fix must not replace that newer protection with a binding-only decision.
    @Test func anUnhealthyActiveOutputStillNeedsRecovery() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: true,
            configurationHealthy: false,
            hasActiveAudioSource: true,
            pendingVoiceBufferCount: 0
        ))
    }

    /// A source may already have released while its final audio is still queued. Pending tail
    /// audio keeps recovery enabled so the fix cannot trade the loop for dropped final words.
    @Test func queuedTailAudioStillNeedsRecovery() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: true,
            configurationHealthy: false,
            hasActiveAudioSource: false,
            pendingVoiceBufferCount: 1
        ))
    }

    /// The loop shape itself: feeding the policy what a self-inflicted rebind produces must not
    /// ask for another rebind, or the cycle restarts.
    ///
    /// A real `AVAudioEngine` is not driven here — an engine bound to a device in a test process
    /// is what made other suites crash — so this replays the state transition the field log
    /// recorded rather than the CoreAudio machinery that produced it.
    @Test func replayingTheFieldLogCycleTerminates() {
        let selected: AudioDeviceID = 88
        var boundTo: AudioDeviceID? = selected
        var rebinds = 0

        // Each iteration is one notification. A rebind rebinds to the selected device and emits
        // the next notification, which is exactly how the loop sustained itself.
        for _ in 0 ..< 10 where AudioEngineConfigurationChangePolicy.needsRecovery(
            boundToSelectedDevice: boundTo == selected,
            configurationHealthy: false,
            hasActiveAudioSource: false,
            pendingVoiceBufferCount: 0
        ) {
            rebinds += 1
            boundTo = selected
        }

        #expect(rebinds == 0)
    }

    /// A rebind may return "configured" from the audio queue and still stop before the main-thread
    /// completion observes it. Callers may only treat it as ready when both values are true;
    /// otherwise the voice start path drains buffered audio into a stopped engine and every batch
    /// is rejected as `playback_not_ready` (issue #1035).
    @Test func configurationCompletionRequiresConfigurationAndCurrentReadiness() {
        #expect(!AudioConfigurationCompletionPolicy.reportsReady(
            configured: true,
            readyNow: false
        ))
        #expect(!AudioConfigurationCompletionPolicy.reportsReady(
            configured: false,
            readyNow: true
        ))
        #expect(AudioConfigurationCompletionPolicy.reportsReady(
            configured: true,
            readyNow: true
        ))
    }

    /// A failed rebind during an active session must not schedule the next attempt at the same
    /// one-second cadence forever. The backoff is bounded and resets after a healthy output.
    @Test func audioRecoveryBackoffEscalatesAndExhausts() {
        #expect(AudioRecoveryBackoffPolicy.retryDelay(forRetry: -1) == nil)
        #expect(AudioRecoveryBackoffPolicy.retryDelay(forRetry: 3) == nil)

        var state = AudioRecoveryBackoffState()
        #expect(state.nextRetryDelay() == 2)
        #expect(state.nextRetryDelay() == 4)
        #expect(state.nextRetryDelay() == 8)
        #expect(state.nextRetryDelay() == nil)
        #expect(state.exhausted)

        state.reset()
        #expect(!state.exhausted)
        #expect(state.nextRetryDelay() == 2)
    }

    /// Replaying repeated active failures now consumes a finite number of retries instead of
    /// sustaining the field-log loop.
    @Test func repeatedActiveFailuresExhaustTheRetryBudget() {
        var state = AudioRecoveryBackoffState()
        var attempts = 0
        while state.nextRetryDelay() != nil {
            attempts += 1
        }
        #expect(attempts == AudioRecoveryBackoffPolicy.retryDelays.count)
        #expect(state.exhausted)
    }

    /// The policy test above only proves the decision function. This keeps the production
    /// completion wired to that decision instead of the old `completion(configured)` path.
    @Test func rebindCompletionUsesCurrentReadiness() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("AudioConfigurationCompletionPolicy.reportsReady("))
        #expect(source.contains("completion(reportsReady)"))
        #expect(!source.contains("completion(configured)"))
        #expect(source.contains("invalidatePendingAudioRecovery()"))
        #expect(source.contains("scheduleAudioRecoveryRetry(reason: effectiveReason)"))
        #expect(source.contains("recovery_in_flight"))
        #expect(source.contains("retry_pending"))
        #expect(source.contains("AUDIO RECOVERY retry_exhausted"))
    }
}
