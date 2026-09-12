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
    /// The regression: bound and idle must be ignored. Under the old condition this returned
    /// "recover", which is the loop.
    @Test func aChangeThatLeavesTheEngineBoundToTheSelectedDeviceNeedsNoRecovery() {
        #expect(!AudioEngineConfigurationChangePolicy.needsRecovery(
            selectedDeviceID: 88,
            currentOutputDeviceID: 88
        ))
    }

    /// The positive control, without which the fix could be "never recover from anything".
    @Test func aChangeThatMovedTheEngineOffTheSelectedDeviceNeedsRecovery() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            selectedDeviceID: 88,
            currentOutputDeviceID: 76
        ))
    }

    /// Unknown state has to fail towards recovery: an engine with no output device, or no
    /// selection yet, is not evidence that the binding is fine.
    @Test func anUnknownDeviceOnEitherSideNeedsRecovery() {
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            selectedDeviceID: nil,
            currentOutputDeviceID: 88
        ))
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            selectedDeviceID: 88,
            currentOutputDeviceID: nil
        ))
        #expect(AudioEngineConfigurationChangePolicy.needsRecovery(
            selectedDeviceID: nil,
            currentOutputDeviceID: nil
        ))
    }

    /// The decision must not consult whether audio is flowing.
    ///
    /// This is the actual defect, and it is a property of the signature: the policy cannot read
    /// `engine.isRunning` because it is never given it. A future change that reintroduces the
    /// dependency has to change this call site, which is the point.
    @Test func theDecisionDependsOnlyOnTheBinding() {
        // Same two device ids, asserted twice with nothing else supplied. Whatever the engine is
        // doing, the answer is the same, because there is nothing else to consult.
        let first = AudioEngineConfigurationChangePolicy.needsRecovery(
            selectedDeviceID: 88,
            currentOutputDeviceID: 88
        )
        let second = AudioEngineConfigurationChangePolicy.needsRecovery(
            selectedDeviceID: 88,
            currentOutputDeviceID: 88
        )
        #expect(first == second)
        #expect(!first)
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
            selectedDeviceID: selected,
            currentOutputDeviceID: boundTo
        ) {
            rebinds += 1
            boundTo = selected
        }

        #expect(rebinds == 0)
    }
}
