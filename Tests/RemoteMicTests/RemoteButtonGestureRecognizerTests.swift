import Testing
@testable import RemoteMic

@Suite("Remote button gestures")
struct RemoteButtonGestureRecognizerTests {
    @Test func singleClickWithoutSecondaryActionsTriggersOnRelease() {
        var recognizer = RemoteButtonGestureRecognizer()

        #expect(recognizer.press(
            .ok,
            recognizesDoubleClick: false,
            recognizesLongPress: false
        ).isEmpty)
        #expect(recognizer.release(.ok) == [.trigger(.ok, .singleClick)])
        #expect(!recognizer.isTracking(.ok))
    }

    @Test func doubleClickCancelsPendingSingleClick() {
        var recognizer = RemoteButtonGestureRecognizer()

        #expect(recognizer.press(
            .tv,
            recognizesDoubleClick: true,
            recognizesLongPress: false
        ).isEmpty)
        #expect(recognizer.release(.tv) == [.scheduleDoubleClickTimeout(.tv)])
        #expect(recognizer.press(
            .tv,
            recognizesDoubleClick: true,
            recognizesLongPress: false
        ) == [.cancelDoubleClickTimeout(.tv)])
        #expect(recognizer.release(.tv) == [.trigger(.tv, .doubleClick)])
        #expect(recognizer.doubleClickTimedOut(.tv).isEmpty)
    }

    @Test func doubleClickTimeoutFallsBackToSingleClick() {
        var recognizer = RemoteButtonGestureRecognizer()

        _ = recognizer.press(
            .home,
            recognizesDoubleClick: true,
            recognizesLongPress: false
        )
        _ = recognizer.release(.home)

        #expect(recognizer.doubleClickTimedOut(.home) == [.trigger(.home, .singleClick)])
        #expect(!recognizer.isTracking(.home))
    }

    @Test func shortPressWithLongPressActionStillTriggersSingleClick() {
        var recognizer = RemoteButtonGestureRecognizer()

        #expect(recognizer.press(
            .menu,
            recognizesDoubleClick: false,
            recognizesLongPress: true
        ) == [.scheduleLongPressTimeout(.menu)])
        #expect(recognizer.release(.menu) == [
            .cancelLongPressTimeout(.menu),
            .trigger(.menu, .singleClick),
        ])
        #expect(recognizer.longPressTimedOut(.menu).isEmpty)
    }

    @Test func longPressSuppressesSingleClick() {
        var recognizer = RemoteButtonGestureRecognizer()

        _ = recognizer.press(
            .power,
            recognizesDoubleClick: false,
            recognizesLongPress: true
        )
        #expect(recognizer.longPressTimedOut(.power) == [.trigger(.power, .longPress)])
        #expect(recognizer.release(.power) == [.cancelLongPressTimeout(.power)])
        #expect(!recognizer.isTracking(.power))
    }

    @Test func secondPressCanBecomeLongPressInsteadOfDoubleClick() {
        var recognizer = RemoteButtonGestureRecognizer()

        _ = recognizer.press(
            .back,
            recognizesDoubleClick: true,
            recognizesLongPress: true
        )
        _ = recognizer.release(.back)
        #expect(recognizer.press(
            .back,
            recognizesDoubleClick: true,
            recognizesLongPress: true
        ) == [
            .cancelDoubleClickTimeout(.back),
            .scheduleLongPressTimeout(.back),
        ])
        #expect(recognizer.longPressTimedOut(.back) == [.trigger(.back, .longPress)])
        #expect(recognizer.release(.back) == [.cancelLongPressTimeout(.back)])
    }

    @Test func tracksDifferentButtonsIndependentlyAndResetClearsThem() {
        var recognizer = RemoteButtonGestureRecognizer()

        _ = recognizer.press(
            .left,
            recognizesDoubleClick: true,
            recognizesLongPress: false
        )
        _ = recognizer.press(
            .right,
            recognizesDoubleClick: false,
            recognizesLongPress: true
        )
        #expect(recognizer.isTracking(.left))
        #expect(recognizer.isTracking(.right))

        recognizer.reset()

        #expect(!recognizer.isTracking(.left))
        #expect(!recognizer.isTracking(.right))
        #expect(recognizer.release(.left).isEmpty)
    }
}
