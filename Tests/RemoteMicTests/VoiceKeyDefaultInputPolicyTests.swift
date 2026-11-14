import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice key default input policy and coordinator")
struct VoiceKeyDefaultInputPolicyTests {
    private let k33Mic = AudioDeviceInfo(id: 1, uid: "K33_USB_UID", name: "K33")
    private let builtInMic = AudioDeviceInfo(id: 2, uid: "BuiltInMicrophoneDevice", name: "MacBook Air 麦克风")
    private let miRemote = AudioDeviceInfo(id: 3, uid: "MiRemoteV2ch_UID", name: "SayAll")
    private let blackHole = AudioDeviceInfo(id: 4, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")

    @Test func targetDevicePrefersSelectedAudioDeviceUID() {
        let available = [k33Mic, builtInMic, miRemote, blackHole]
        let target = VoiceKeyDefaultInputPolicy.resolveTargetDeviceUID(
            selectedAudioDeviceUID: blackHole.uid,
            availableInputs: available
        )
        #expect(target == blackHole.uid)
    }

    @Test func targetDeviceFallsBackToAvailableVirtualInputWhenSelectedEmpty() {
        let available = [k33Mic, builtInMic, miRemote]
        let target = VoiceKeyDefaultInputPolicy.resolveTargetDeviceUID(
            selectedAudioDeviceUID: "",
            availableInputs: available
        )
        #expect(target == miRemote.uid)
    }

    @Test func targetDeviceReturnsNilWhenNoVirtualInputExists() {
        let available = [k33Mic, builtInMic]
        let target = VoiceKeyDefaultInputPolicy.resolveTargetDeviceUID(
            selectedAudioDeviceUID: "",
            availableInputs: available
        )
        #expect(target == nil)
    }

    @Test func evaluateBorrowSwitchesWhenDifferentFromCurrent() {
        let decision = VoiceKeyDefaultInputPolicy.evaluateBorrow(
            isEnabled: true,
            currentDefaultUID: k33Mic.uid,
            targetUID: miRemote.uid,
            activeBorrow: nil
        )
        #expect(decision == .switchInput(fromUID: k33Mic.uid, toUID: miRemote.uid))
    }

    @Test func evaluateBorrowDoesNothingWhenAlreadyTarget() {
        let decision = VoiceKeyDefaultInputPolicy.evaluateBorrow(
            isEnabled: true,
            currentDefaultUID: miRemote.uid,
            targetUID: miRemote.uid,
            activeBorrow: nil
        )
        #expect(decision == .noChange)
    }

    @Test func evaluateBorrowDoesNothingWhenDisabled() {
        let decision = VoiceKeyDefaultInputPolicy.evaluateBorrow(
            isEnabled: false,
            currentDefaultUID: k33Mic.uid,
            targetUID: miRemote.uid,
            activeBorrow: nil
        )
        #expect(decision == .noChange)
    }

    @Test func evaluateBorrowDoesNothingWhenAlreadyBorrowed() {
        let borrow = VoiceKeyDefaultInputBorrow(
            originalUID: k33Mic.uid,
            targetUID: miRemote.uid,
            sessionID: UUID(),
            switchedAt: Date()
        )
        let decision = VoiceKeyDefaultInputPolicy.evaluateBorrow(
            isEnabled: true,
            currentDefaultUID: miRemote.uid,
            targetUID: miRemote.uid,
            activeBorrow: borrow
        )
        #expect(decision == .noChange)
    }

    @Test func evaluateRestoreRestoresWhenTargetRemainsDefault() {
        let borrow = VoiceKeyDefaultInputBorrow(
            originalUID: k33Mic.uid,
            targetUID: miRemote.uid,
            sessionID: UUID(),
            switchedAt: Date()
        )
        let decision = VoiceKeyDefaultInputPolicy.evaluateRestore(
            activeBorrow: borrow,
            currentDefaultUID: miRemote.uid
        )
        #expect(decision == .restoreInput(fromUID: miRemote.uid, toUID: k33Mic.uid))
    }

    @Test func evaluateRestoreClearsWithoutRestoringIfUserManuallyChangedInput() {
        let borrow = VoiceKeyDefaultInputBorrow(
            originalUID: k33Mic.uid,
            targetUID: miRemote.uid,
            sessionID: UUID(),
            switchedAt: Date()
        )
        let decision = VoiceKeyDefaultInputPolicy.evaluateRestore(
            activeBorrow: borrow,
            currentDefaultUID: builtInMic.uid
        )
        #expect(decision == .clearWithoutRestore)
    }

    @Test func coordinatorSwitchesAndRestoresImmediatelyWhenForced() {
        var currentDevice = k33Mic
        var setCalls: [String] = []

        let coordinator = VoiceKeyDefaultInputCoordinator(
            isEnabled: { true },
            selectedAudioDeviceUID: { self.miRemote.uid },
            defaultInputDevice: { currentDevice },
            availableInputDevices: { [self.k33Mic, self.miRemote] },
            setDefaultInputDevice: { device in
                currentDevice = device
                setCalls.append(device.uid)
                return noErr
            },
            log: { _ in },
            mainQueueAsyncAfter: { _, block in block() }
        )

        let sessionID = UUID()
        coordinator.borrowInputDeviceIfNeeded(sessionID: sessionID)

        #expect(setCalls == [miRemote.uid])
        #expect(currentDevice.uid == miRemote.uid)
        #expect(coordinator.activeBorrow?.originalUID == k33Mic.uid)

        coordinator.forceRestoreImmediate(reason: "test_finish")

        #expect(setCalls == [miRemote.uid, k33Mic.uid])
        #expect(currentDevice.uid == k33Mic.uid)
        #expect(coordinator.activeBorrow == nil)
    }

    @Test func coordinatorRapidPressCancelsPendingRestore() {
        var currentDevice = k33Mic
        var scheduledBlocks: [() -> Void] = []

        let coordinator = VoiceKeyDefaultInputCoordinator(
            isEnabled: { true },
            selectedAudioDeviceUID: { self.miRemote.uid },
            defaultInputDevice: { currentDevice },
            availableInputDevices: { [self.k33Mic, self.miRemote] },
            setDefaultInputDevice: { device in
                currentDevice = device
                return noErr
            },
            log: { _ in },
            mainQueueAsyncAfter: { _, block in
                scheduledBlocks.append(block)
            }
        )

        coordinator.borrowInputDeviceIfNeeded(sessionID: UUID())
        #expect(currentDevice.uid == miRemote.uid)

        coordinator.restoreInputDeviceIfNeeded(reason: "release")
        #expect(scheduledBlocks.count == 1)

        coordinator.borrowInputDeviceIfNeeded(sessionID: UUID())

        scheduledBlocks[0]()
        #expect(currentDevice.uid == miRemote.uid)
        #expect(coordinator.activeBorrow != nil)
    }
}
