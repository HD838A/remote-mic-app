import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Bluetooth voice stop policy")
struct BluetoothVoiceStopPolicyTests {
    @Test func forcesSoftwareFnUpOnlyForHardwareMappedTimeout() {
        #expect(BluetoothVoiceStopPolicy.shouldForceHardwareVoiceKeyRelease(
            mode: .function,
            fnTapEnabled: false,
            isHeldByLatch: false,
            reason: .remoteTimeout
        ))
        #expect(!BluetoothVoiceStopPolicy.shouldForceHardwareVoiceKeyRelease(
            mode: .function,
            fnTapEnabled: false,
            isHeldByLatch: false,
            reason: .remoteRelease
        ))
        #expect(!BluetoothVoiceStopPolicy.shouldForceHardwareVoiceKeyRelease(
            mode: .function,
            fnTapEnabled: true,
            isHeldByLatch: false,
            reason: .remoteTimeout
        ))
        #expect(!BluetoothVoiceStopPolicy.shouldForceHardwareVoiceKeyRelease(
            mode: .function,
            fnTapEnabled: false,
            isHeldByLatch: true,
            reason: .remoteTimeout
        ))
        #expect(!BluetoothVoiceStopPolicy.shouldForceHardwareVoiceKeyRelease(
            mode: .leftCommand,
            fnTapEnabled: false,
            isHeldByLatch: false,
            reason: .remoteTimeout
        ))
        #expect(!BluetoothVoiceStopPolicy.shouldForceHardwareVoiceKeyRelease(
            mode: .function,
            fnTapEnabled: false,
            isHeldByLatch: false,
            reason: nil
        ))
    }

    @Test func remoteControlBytesDistinguishTimeoutFromRelease() {
        #expect(XiaomiBluetoothBridge.voiceStopReason(for: [0x00, 0x08]) == .remoteTimeout)
        #expect(XiaomiBluetoothBridge.voiceStopReason(for: [0x00, 0x02]) == .remoteRelease)
        #expect(XiaomiBluetoothBridge.voiceStopReason(for: [0x00]) == .remoteRelease)
    }

    @Test func forcedFnReleasePostsAnUpWithoutPriorDown() {
        var events: [(code: CGKeyCode, isPressed: Bool, flags: CGEventFlags)] = []
        let submitted = KeyboardInjector.setVoiceKeyPressed(
            .function,
            isPressed: false,
            accessibilityTrusted: { true },
            keyStatePoster: { code, isPressed, flags in
                events.append((code, isPressed, flags))
                return true
            }
        )

        #expect(submitted)
        #expect(events.count == 1)
        #expect(events.first?.code == 63)
        #expect(events.first?.isPressed == false)
        #expect(events.first?.flags.isEmpty == true)
    }
}
