import Testing
@testable import RemoteMic

@Suite("Remote hardware input contract")
struct RemoteHardwareInputTests {
    private let firstDevice = RemoteHardwareDeviceIdentity(
        adapterID: "builtin.test",
        instanceID: "first"
    )
    private let secondDevice = RemoteHardwareDeviceIdentity(
        adapterID: "builtin.test",
        instanceID: "second"
    )

    @Test func beganAndEndedEdgesAreEmittedSynchronouslyWithoutTimers() {
        let router = RemoteHardwareControlLifecycleRouter()

        let began = router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "voice",
            isPressed: true,
            timestampUptime: 10
        ))
        let ended = router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "voice",
            isPressed: false,
            timestampUptime: 10.01
        ))

        #expect(began == .emitted(RemoteHardwareControlEvent(
            device: firstDevice,
            controlID: "voice",
            phase: .began,
            timestampUptime: 10,
            sequence: 1,
            cancellationReason: nil
        )))
        #expect(ended == .emitted(RemoteHardwareControlEvent(
            device: firstDevice,
            controlID: "voice",
            phase: .ended,
            timestampUptime: 10.01,
            sequence: 2,
            cancellationReason: nil
        )))
    }

    @Test func duplicateBeginsAndUnmatchedEndsAreIgnored() {
        let router = RemoteHardwareControlLifecycleRouter()
        let down = RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "select",
            isPressed: true,
            timestampUptime: 1
        )

        _ = router.route(down)

        #expect(router.route(down) == .ignored(.duplicateBegin))
        _ = router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "select",
            isPressed: false,
            timestampUptime: 2
        ))
        #expect(router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "select",
            isPressed: false,
            timestampUptime: 3
        )) == .ignored(.unmatchedEnd))
    }

    @Test func identicalControlsRemainIsolatedAcrossDevices() {
        let router = RemoteHardwareControlLifecycleRouter()

        _ = router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "menu",
            isPressed: true,
            timestampUptime: 1
        ))
        _ = router.route(RemoteHardwareRawControlEvent(
            device: secondDevice,
            controlID: "menu",
            isPressed: true,
            timestampUptime: 2
        ))

        #expect(router.isActive(device: firstDevice, controlID: "menu"))
        #expect(router.isActive(device: secondDevice, controlID: "menu"))

        _ = router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "menu",
            isPressed: false,
            timestampUptime: 3
        ))

        #expect(!router.isActive(device: firstDevice, controlID: "menu"))
        #expect(router.isActive(device: secondDevice, controlID: "menu"))
    }

    @Test func disconnectCancelsOnlyTheAffectedDevice() {
        let router = RemoteHardwareControlLifecycleRouter()
        for device in [firstDevice, secondDevice] {
            _ = router.route(RemoteHardwareRawControlEvent(
                device: device,
                controlID: "voice",
                isPressed: true,
                timestampUptime: 1
            ))
        }

        let cancelled = router.cancel(
            device: firstDevice,
            reason: .deviceDisconnected,
            timestampUptime: 2,
            suppressNextRelease: false
        )

        #expect(cancelled.count == 1)
        #expect(cancelled[0].phase == .cancelled)
        #expect(cancelled[0].cancellationReason == .deviceDisconnected)
        #expect(!router.isActive(device: firstDevice, controlID: "voice"))
        #expect(router.isActive(device: secondDevice, controlID: "voice"))
    }

    @Test func configurationChangeSuppressesTheCancelledPhysicalRelease() {
        let router = RemoteHardwareControlLifecycleRouter()
        _ = router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "tv",
            isPressed: true,
            timestampUptime: 1
        ))

        let cancelled = router.cancel(
            device: firstDevice,
            reason: .configurationChanged,
            timestampUptime: 2,
            suppressNextRelease: true
        )

        #expect(cancelled.count == 1)
        #expect(router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "tv",
            isPressed: true,
            timestampUptime: 2.1
        )) == .ignored(.awaitingCancelledEnd))
        #expect(router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "tv",
            isPressed: false,
            timestampUptime: 2.2
        )) == .ignored(.suppressedLateEnd))
        #expect(router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "tv",
            isPressed: true,
            timestampUptime: 3
        )) == .emitted(RemoteHardwareControlEvent(
            device: firstDevice,
            controlID: "tv",
            phase: .began,
            timestampUptime: 3,
            sequence: 3,
            cancellationReason: nil
        )))
    }

    @Test func disconnectClearsAnUnreceivedSuppressedReleaseForTheNextConnection() {
        let router = RemoteHardwareControlLifecycleRouter()
        _ = router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "tv",
            isPressed: true,
            timestampUptime: 1
        ))
        _ = router.cancel(
            device: firstDevice,
            reason: .configurationChanged,
            timestampUptime: 2,
            suppressNextRelease: true
        )

        _ = router.cancel(
            device: firstDevice,
            reason: .deviceDisconnected,
            timestampUptime: 3,
            suppressNextRelease: false
        )

        #expect(router.route(RemoteHardwareRawControlEvent(
            device: firstDevice,
            controlID: "tv",
            isPressed: true,
            timestampUptime: 4
        )) == .emitted(RemoteHardwareControlEvent(
            device: firstDevice,
            controlID: "tv",
            phase: .began,
            timestampUptime: 4,
            sequence: 3,
            cancellationReason: nil
        )))
    }

    @Test func cancelAllProducesDeterministicMonotonicEvents() {
        let router = RemoteHardwareControlLifecycleRouter()
        for (device, controlID) in [
            (secondDevice, "right"),
            (firstDevice, "voice"),
            (firstDevice, "left"),
        ] {
            _ = router.route(RemoteHardwareRawControlEvent(
                device: device,
                controlID: controlID,
                isPressed: true,
                timestampUptime: 1
            ))
        }

        let events = router.cancelAll(
            reason: .applicationSuspended,
            timestampUptime: 2,
            suppressNextRelease: false
        )

        #expect(events.map(\.controlID) == ["left", "voice", "right"])
        #expect(events.map(\.sequence) == [4, 5, 6])
        #expect(events.allSatisfy { $0.phase == .cancelled })
        #expect(events.allSatisfy { $0.cancellationReason == .applicationSuspended })
    }

    @Test func a2854ExperimentalTouchTuningMatchesTheHardwareResearchBaseline() {
        let tuning = RemoteHardwareTouchTuning.appleSiriRemoteA2854Experimental

        #expect(tuning.isValid)
        #expect(tuning.minimumCircularRadius == 0.35)
        #expect(tuning.circularScrollStartThreshold == 0.2)
        #expect(tuning.circularScrollPixelsPerRadian == 30)
        #expect(tuning.scrollEase == 0.3)
        #expect(tuning.minimumAcceleration == 1.0)
        #expect(tuning.maximumAcceleration == 1.3)
        #expect(tuning.isScrollInverted)
    }
}
