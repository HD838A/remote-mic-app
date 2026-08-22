import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Mouse mode controller")
struct MouseModeControllerTests {
    @Test func idleControllerIgnoresEdgesUntilActivated() {
        let harness = Harness()

        #expect(!harness.controller.isActive)
        #expect(!harness.controller.handle(button: .right, edge: .down))
        #expect(!harness.controller.handle(button: .ok, edge: .down))
        #expect(harness.moves.isEmpty)
        #expect(harness.clicks.isEmpty)

        #expect(harness.controller.toggle())
        #expect(harness.controller.isActive)
        #expect(harness.states == [true])

        #expect(harness.controller.toggle())
        #expect(!harness.controller.isActive)
        #expect(harness.states == [true, false])
    }

    @Test func activationRequiresAccessibilityPermission() {
        let harness = Harness(trusted: false)

        #expect(!harness.controller.activate())
        #expect(!harness.controller.isActive)
        #expect(harness.states.isEmpty)
        #expect(harness.tickHandler == nil)
    }

    @Test func directionDownStartsMovementAndDirectionUpStopsIt() {
        let harness = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .right, edge: .down))
        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        let firstMove = harness.moves.last
        #expect(firstMove != nil)
        // speed(1/60) ≈ 160.24 px/s, one tick of 1/60 s moves about 2.6707 px.
        #expect(abs((firstMove?.x ?? 0) - 502.67) < 0.01)
        #expect(firstMove?.y == 400)

        #expect(harness.controller.handle(button: .right, edge: .up))
        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(harness.moves.count == 1)
    }

    @Test func movementAcceleratesWithQuadraticEaseIn() {
        #expect(MouseModeController.speed(afterHoldingFor: 0) == 160)
        #expect(MouseModeController.speed(afterHoldingFor: 0.6) == 470)
        #expect(MouseModeController.speed(afterHoldingFor: 1.2) == 1400)
        #expect(MouseModeController.speed(afterHoldingFor: 5) == 1400)

        let harness = Harness(
            cursor: CGPoint(x: 500, y: 400),
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 4000)
        )
        #expect(harness.controller.activate())
        #expect(harness.controller.handle(button: .down, edge: .down))

        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        let slow = harness.moves.last
        #expect(slow != nil)
        // speed(1/60) ≈ 160.24 px/s, one tick of 1/60 s moves about 2.6707 px.
        #expect(abs((slow?.y ?? 0) - 402.67) < 0.01)

        for _ in 0 ..< 59 {
            harness.advance(by: MouseModeController.tickInterval)
            harness.tick()
        }
        #expect(harness.moves.count == 60)
        // At t = 1 s: progress = 1/1.2, speed ≈ 1021.1 px/s, ≈ 17.02 px per tick.
        let fast = harness.moves.last
        let previous = harness.moves.dropLast().last
        #expect(abs(((fast?.y ?? 0) - (previous?.y ?? 0)) - 17.02) < 0.01)
    }

    @Test func diagonalMovementNormalizesTheDirectionVector() {
        let harness = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(harness.controller.activate())
        #expect(harness.controller.handle(button: .right, edge: .down))
        #expect(harness.controller.handle(button: .down, edge: .down))

        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        let move = harness.moves.last
        #expect(move != nil)
        // One tick at ≈160.24 px/s travels about 2.6707 px split across both axes.
        let axis = 2.6707 / 2.squareRoot()
        #expect(abs((move?.x ?? 0) - (500 + axis)) < 0.01)
        #expect(abs((move?.y ?? 0) - (400 + axis)) < 0.01)
    }

    @Test func movementClampsToTheScreenBounds() {
        let harness = Harness(
            cursor: CGPoint(x: 1439, y: 450),
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        #expect(harness.controller.activate())
        #expect(harness.controller.handle(button: .right, edge: .down))

        harness.advance(by: 1)
        harness.tick()
        #expect(harness.moves.last == CGPoint(x: 1439, y: 450))

        #expect(MouseModeController.clamped(
            CGPoint(x: -50, y: 1000),
            to: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ) == CGPoint(x: 0, y: 899))
        #expect(MouseModeController.clamped(
            CGPoint(x: 10, y: 10),
            to: .null
        ) == CGPoint(x: 10, y: 10))
    }

    @Test func tickDeltaIsCappedSoRunLoopStallsPauseMovement() {
        let harness = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(harness.controller.activate())
        #expect(harness.controller.handle(button: .right, edge: .down))

        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(harness.moves.count == 1)

        // One second passes without a tick (stalled run loop).
        harness.advance(by: 1)
        harness.tick()
        #expect(harness.moves.count == 2)
        // At t ≈ 1.017 s the quadratic curve gives ≈ 1050.1 px/s, but the
        // delta is capped at 0.05 s: the cursor pauses (≈52.5 px) instead of
        // jumping a full second's worth.
        let jump = (harness.moves.last?.x ?? 0) - (harness.moves.first?.x ?? 0)
        #expect(abs(jump - 52.5) < 0.01)
    }

    @Test func missingCursorPositionSkipsMovementAndClicks() {
        let harness = Harness(cursor: nil)
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .right, edge: .down))
        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(harness.moves.isEmpty)

        #expect(harness.controller.handle(button: .ok, edge: .down))
        #expect(harness.controller.handle(button: .ok, edge: .up))
        harness.advance(by: MouseModeController.doubleTapWindow)
        harness.firePendingOperations()
        #expect(harness.clicks.isEmpty)
    }

    @Test func hidMonitorFlushClearsPhantomGestureRepeatAndNonRepeatableState() throws {
        let suiteName = "MouseModeControllerTests.flush.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let profileID = UUID()
        settings.setAction(.escape, for: .home, trigger: .longPress)

        let scheduler = FakeHIDScheduler()
        var performed: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { _, _, configured in
                performed.append(configured.action)
                return true
            },
            frontmostBundleIdentifier: { "com.example.other" },
            diagnosticLogger: { _ in }
        )
        monitor.connectSimulatedDevice(fingerprint: "sim", profileID: profileID)

        // Holding .home starts long-press tracking; holding .up (arrowUp)
        // performs immediately and starts a repeat timer.
        monitor.handleSimulatedReport(
            reportID: 1,
            data: Data([0x4A, 0x00, 0x52, 0x00, 0, 0])
        )
        #expect(performed == [.arrowUp])
        #expect(!scheduler.tasks.isEmpty)

        // Mouse mode activates: in-flight state is flushed.
        monitor.flushInFlightInputState()

        // Firing everything the fake scheduler ever captured must not produce
        // phantom long-press, double-click or repeat actions.
        scheduler.fireAll()
        #expect(performed == [.arrowUp])

        // The release after the flush must not trigger any phantom click.
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0, 0, 0, 0, 0]))
        scheduler.fireAll()
        #expect(performed == [.arrowUp])

        // Non-repeatable latches are cleared as well.
        #expect(monitor.shouldAcceptRawPress(
            button: .menu,
            action: .customShortcut,
            frontmostBundleIdentifier: "com.example.other"
        ))
        #expect(!monitor.shouldAcceptRawPress(
            button: .menu,
            action: .customShortcut,
            frontmostBundleIdentifier: "com.example.other"
        ))
        monitor.flushInFlightInputState()
        #expect(monitor.shouldAcceptRawPress(
            button: .menu,
            action: .customShortcut,
            frontmostBundleIdentifier: "com.example.other"
        ))
    }

    @Test func doubleTapUpPostsPageUpAndBouncesBack() {
        assertDoubleTap(button: .up, expectedCode: 116, expectedFlags: [])
    }

    @Test func doubleTapDownPostsPageDownAndBouncesBack() {
        assertDoubleTap(button: .down, expectedCode: 121, expectedFlags: [])
    }

    @Test func doubleTapLeftPostsCommandOpenBracketAndBouncesBack() {
        assertDoubleTap(button: .left, expectedCode: 33, expectedFlags: .maskCommand)
    }

    @Test func doubleTapRightPostsCommandWAndBouncesBack() {
        assertDoubleTap(button: .right, expectedCode: 13, expectedFlags: .maskCommand)
    }

    @Test func secondPressInsideTheWindowFiresAndOutsideDoesNot() {
        // Gap 0.25 s (<= 0.3 s window): double-tap fires.
        let inside = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(inside.controller.activate())
        #expect(inside.controller.handle(button: .up, edge: .down))
        inside.advance(by: 0.125)
        #expect(inside.controller.handle(button: .up, edge: .up))
        inside.advance(by: 0.25)
        #expect(inside.controller.handle(button: .up, edge: .down))
        #expect(inside.keys.map(\.0) == [116])
        #expect(inside.controller.handle(button: .up, edge: .up))

        // Gap 0.3125 s (> 0.3 s window): the second press is a fresh press.
        let outside = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(outside.controller.activate())
        #expect(outside.controller.handle(button: .up, edge: .down))
        outside.advance(by: 0.125)
        #expect(outside.controller.handle(button: .up, edge: .up))
        outside.advance(by: 0.3125)
        #expect(outside.controller.handle(button: .up, edge: .down))
        #expect(outside.keys.isEmpty)
        // The fresh press moves normally.
        outside.advance(by: MouseModeController.tickInterval)
        outside.tick()
        #expect(!outside.moves.isEmpty)
        #expect(outside.controller.handle(button: .up, edge: .up))
    }

    @Test func aLongFirstPressDoesNotCountAsATap() {
        let harness = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(harness.controller.activate())

        // First press held for 0.375 s (>= 0.3 s): a normal move, not a tap.
        #expect(harness.controller.handle(button: .down, edge: .down))
        harness.advance(by: 0.375)
        #expect(harness.controller.handle(button: .down, edge: .up))

        // A quick second press right after must not fire the double-tap key.
        harness.advance(by: 0.0625)
        #expect(harness.controller.handle(button: .down, edge: .down))
        #expect(harness.keys.isEmpty)
        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(!harness.moves.isEmpty)
        #expect(harness.controller.handle(button: .down, edge: .up))
    }

    @Test func aSingleTapWithoutASecondPressFiresNothing() {
        let harness = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .right, edge: .down))
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .right, edge: .up))
        harness.advance(by: 1)
        harness.tick()
        #expect(harness.keys.isEmpty)
    }

    @Test func doubleTapIsIgnoredOutsideMouseMode() {
        let harness = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(!harness.controller.handle(button: .left, edge: .down))
        harness.advance(by: 0.125)
        #expect(!harness.controller.handle(button: .left, edge: .up))
        harness.advance(by: 0.125)
        #expect(!harness.controller.handle(button: .left, edge: .down))
        #expect(harness.keys.isEmpty)
        #expect(harness.moves.isEmpty)
    }

    private func assertDoubleTap(
        button: RemoteButton,
        expectedCode: CGKeyCode,
        expectedFlags: CGEventFlags
    ) {
        let harness = Harness(cursor: CGPoint(x: 500, y: 400))
        #expect(harness.controller.activate())
        let positionBeforeFirstPress = harness.cursor

        // First tap: press, move briefly, release within 300 ms.
        #expect(harness.controller.handle(button: button, edge: .down))
        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(!harness.moves.isEmpty)
        #expect(harness.cursor != positionBeforeFirstPress)
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: button, edge: .up))
        #expect(harness.keys.isEmpty)

        // Second press lands inside the window (gap 0.125 s).
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: button, edge: .down))
        #expect(harness.keys.count == 1)
        #expect(harness.keys.first?.0 == expectedCode)
        #expect(harness.keys.first?.1 == expectedFlags)
        // Bounce-back: the cursor returns to the pre-first-press position.
        #expect(harness.moves.last == positionBeforeFirstPress)
        #expect(harness.cursor == positionBeforeFirstPress)

        // The suppressed second press produces no movement.
        let moveCount = harness.moves.count
        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(harness.moves.count == moveCount)
        #expect(harness.controller.handle(button: button, edge: .up))

        // Afterwards the direction works normally again.
        harness.advance(by: 1)
        #expect(harness.controller.handle(button: button, edge: .down))
        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(harness.moves.count > moveCount)
        #expect(harness.keys.count == 1)
        #expect(harness.controller.handle(button: button, edge: .up))
    }

    @Test func menuAndBackFallThroughAndOnlyTheToggleExits() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        // Menu and back keep their normal bindings: not consumed, no clicks.
        #expect(!harness.controller.handle(button: .menu, edge: .down))
        #expect(!harness.controller.handle(button: .menu, edge: .up))
        #expect(!harness.controller.handle(button: .back, edge: .down))
        #expect(!harness.controller.handle(button: .back, edge: .up))
        #expect(harness.clicks.isEmpty)
        #expect(harness.controller.isActive)

        // Only the toggle binding exits the mode.
        #expect(harness.controller.toggle())
        #expect(!harness.controller.isActive)
        #expect(harness.states == [true, false])
        #expect(harness.tickCancelled)
    }

    @Test func shortPressOkClicksOnReleaseAtTheReleasePosition() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .ok, edge: .down))
        // Pressing OK alone never clicks immediately.
        #expect(harness.clicks.isEmpty)

        // The cursor may move while OK is held; the pending click remembers
        // where the cursor was at release time.
        harness.cursor = CGPoint(x: 700, y: 500)
        harness.advance(by: 0.125) // well below the 550 ms long-press duration
        #expect(harness.controller.handle(button: .ok, edge: .up))
        // The click stays pending for the double-tap window.
        #expect(harness.clicks.isEmpty)

        harness.advance(by: MouseModeController.doubleTapWindow)
        harness.firePendingOperations()
        #expect(harness.clicks.map(\.0) == [.left])
        #expect(harness.clicks.map(\.1) == [CGPoint(x: 700, y: 500)])
        #expect(harness.keys.isEmpty)
    }

    @Test func doubleTapOkPostsRightClickWithoutLeftClick() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        // First quick tap arms the pending left click.
        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .up))
        #expect(harness.clicks.isEmpty)

        // Second press inside the window cancels the left click.
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .up))
        #expect(harness.clicks.map(\.0) == [.right])
        #expect(harness.keys.isEmpty)

        // Nothing else fires later (no leftover pending left click).
        harness.advance(by: MouseModeController.doubleTapWindow)
        harness.firePendingOperations()
        #expect(harness.clicks.map(\.0) == [.right])
    }

    @Test func secondPressHeldToLongPressSendsWithoutRightClick() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        // First quick tap.
        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .up))

        // Second press inside the window, held to the long-press duration.
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: MouseModeController.okLongPressDuration)
        harness.firePendingOperations()
        #expect(harness.keys.map(\.0) == [MouseModeController.returnKeyCode])
        #expect(harness.clicks.isEmpty)

        // Release after send: no right click, no further keys.
        #expect(harness.controller.handle(button: .ok, edge: .up))
        #expect(harness.clicks.isEmpty)
        #expect(harness.keys.count == 1)
    }

    @Test func secondPressOutsideTheWindowIsAnotherSingleClick() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .up))
        // Let the window expire: the pending left click fires.
        harness.advance(by: MouseModeController.doubleTapWindow)
        harness.firePendingOperations()
        #expect(harness.clicks.map(\.0) == [.left])

        // A later quick tap is a fresh single click, not a double-tap.
        harness.advance(by: 0.5)
        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .up))
        harness.advance(by: MouseModeController.doubleTapWindow)
        harness.firePendingOperations()
        #expect(harness.clicks.map(\.0) == [.left, .left])
        #expect(harness.keys.isEmpty)
    }

    @Test func deactivateCancelsAPendingOkClick() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: 0.125)
        #expect(harness.controller.handle(button: .ok, edge: .up))
        harness.controller.deactivate(reason: "toggle_button")
        harness.advance(by: MouseModeController.doubleTapWindow)
        harness.firePendingOperations()
        #expect(harness.clicks.isEmpty)
        #expect(harness.keys.isEmpty)
    }

    @Test func longPressOkPostsReturnAndSuppressesClick() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: MouseModeController.okLongPressDuration)
        harness.firePendingOperations()
        #expect(harness.keys.map(\.0) == [MouseModeController.returnKeyCode])
        #expect(harness.keys.first?.1 == [])
        #expect(harness.clicks.isEmpty)

        // Releasing after the long press fired must not produce a click.
        #expect(harness.controller.handle(button: .ok, edge: .up))
        #expect(harness.clicks.isEmpty)
        #expect(harness.keys.count == 1)
    }

    @Test func deactivateCancelsAPendingOkLongPress() {
        let harness = Harness(cursor: CGPoint(x: 640, y: 360))
        #expect(harness.controller.activate())

        #expect(harness.controller.handle(button: .ok, edge: .down))
        harness.advance(by: 0.125)
        harness.controller.deactivate(reason: "back_button")
        harness.advance(by: MouseModeController.okLongPressDuration)
        harness.firePendingOperations()
        #expect(harness.keys.isEmpty)
        #expect(harness.clicks.isEmpty)
    }

    @Test func unmanagedButtonsFallThroughWhileActive() {
        let harness = Harness()
        #expect(harness.controller.activate())

        #expect(!harness.controller.handle(button: .home, edge: .down))
        #expect(!harness.controller.handle(button: .volumeUp, edge: .down))
        #expect(!harness.controller.handle(button: .tv, edge: .up))
        #expect(harness.moves.isEmpty)
        #expect(harness.clicks.isEmpty)
    }

    @Test func deactivateCancelsMovementAndTicking() {
        let harness = Harness()
        #expect(harness.controller.activate())
        #expect(harness.controller.handle(button: .left, edge: .down))

        harness.controller.deactivate(reason: "remote_disconnected")
        #expect(!harness.controller.isActive)
        #expect(harness.tickCancelled)

        harness.advance(by: MouseModeController.tickInterval)
        harness.tick()
        #expect(harness.moves.isEmpty)
    }

    @Test func keyboardInjectorPostsMouseClicksAtTheCurrentPosition() {
        var posted: [KeyboardInjector.MouseClickButton] = []
        let poster: KeyboardInjector.MouseClickPoster = { posted.append($0) }

        #expect(KeyboardInjector.send(
            .mouseLeftClick,
            accessibilityTrusted: { true },
            keyPoster: { _, _ in },
            mouseClickPoster: poster
        ))
        #expect(KeyboardInjector.send(
            .mouseRightClick,
            accessibilityTrusted: { true },
            keyPoster: { _, _ in },
            mouseClickPoster: poster
        ))
        #expect(KeyboardInjector.send(
            .mouseMiddleClick,
            accessibilityTrusted: { true },
            keyPoster: { _, _ in },
            mouseClickPoster: poster
        ))
        #expect(posted == [.left, .right, .middle])

        #expect(!KeyboardInjector.send(
            .mouseLeftClick,
            accessibilityTrusted: { false },
            keyPoster: { _, _ in },
            mouseClickPoster: poster
        ))
        #expect(posted.count == 3)
    }

    @Test func mouseModeToggleStaysAnAppInternalAction() {
        var posted: [KeyboardInjector.MouseClickButton] = []
        #expect(KeyboardInjector.send(
            .toggleMouseMode,
            accessibilityTrusted: { false },
            keyPoster: { _, _ in },
            mouseClickPoster: { posted.append($0) }
        ))
        #expect(posted.isEmpty)
        #expect(ButtonAction.toggleMouseMode.isAppInternal)
        #expect(!ButtonAction.toggleMouseMode.allowsRepeat)
    }

    @Test func newActionsHaveCategoriesDisplayNamesAndCodableRoundTrips() throws {
        #expect(ButtonAction.mouseLeftClick.category == .systemAndMedia)
        #expect(ButtonAction.mouseRightClick.category == .systemAndMedia)
        #expect(ButtonAction.mouseMiddleClick.category == .systemAndMedia)
        #expect(ButtonAction.toggleMouseMode.category == .custom)

        let localization = LocalizationStore(settings: AppSettings())
        for action in [
            ButtonAction.mouseLeftClick,
            .mouseRightClick,
            .mouseMiddleClick,
            .toggleMouseMode,
        ] {
            #expect(!action.displayName(using: localization).isEmpty)
        }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for action in [
            ButtonAction.mouseLeftClick,
            .mouseRightClick,
            .mouseMiddleClick,
            .toggleMouseMode,
        ] {
            let data = try encoder.encode(action)
            #expect(try decoder.decode(ButtonAction.self, from: data) == action)
        }
    }

    private final class PendingOperation {
        var cancelled = false
        let operation: () -> Void

        init(_ operation: @escaping () -> Void) {
            self.operation = operation
        }

        func fire() {
            guard !cancelled else { return }
            operation()
        }
    }

    private final class Harness {
        var time: TimeInterval = 0
        var cursor: CGPoint?
        var bounds: CGRect
        var trusted: Bool
        var tickHandler: (() -> Void)?
        var tickCancelled = false
        var pendingOperations: [PendingOperation] = []
        var moves: [CGPoint] = []
        var clicks: [(KeyboardInjector.MouseClickButton, CGPoint)] = []
        var keys: [(CGKeyCode, CGEventFlags)] = []
        var states: [Bool] = []
        var controller: MouseModeController!

        init(
            cursor: CGPoint? = CGPoint(x: 500, y: 400),
            bounds: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900),
            trusted: Bool = true
        ) {
            self.cursor = cursor
            self.bounds = bounds
            self.trusted = trusted
            controller = MouseModeController(
                now: { [unowned self] in self.time },
                schedule: { [unowned self] _, operation in
                    // The first scheduled task is the 60Hz movement tick;
                    // later ones (e.g. the OK long-press timer) are pending ops.
                    if self.tickHandler == nil {
                        self.tickHandler = operation
                        self.tickCancelled = false
                        return MouseModeScheduledTask { [unowned self] in
                            self.tickCancelled = true
                        }
                    }
                    let pending = PendingOperation(operation)
                    self.pendingOperations.append(pending)
                    return MouseModeScheduledTask { pending.cancelled = true }
                },
                postMove: { [unowned self] point in
                    self.moves.append(point)
                    self.cursor = point
                },
                postClick: { [unowned self] button, point in
                    self.clicks.append((button, point))
                },
                keyPoster: { [unowned self] code, flags in
                    self.keys.append((code, flags))
                },
                cursorPosition: { [unowned self] in self.cursor },
                screenBounds: { [unowned self] in self.bounds },
                accessibilityTrusted: { [unowned self] in self.trusted },
                logger: { _ in }
            )
            controller.onStateChange = { [unowned self] in
                self.states.append($0)
            }
        }

        func advance(by delta: TimeInterval) {
            time += delta
        }

        func tick() {
            tickHandler?()
        }

        func firePendingOperations() {
            pendingOperations.forEach { $0.fire() }
        }
    }

    private final class FakeHIDTask: HIDRemoteScheduledTask {
        private(set) var isCancelled = false
        private let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }

        func fire() {
            guard !isCancelled else { return }
            action()
        }
    }

    private final class FakeHIDScheduler: HIDRemoteScheduling {
        private(set) var tasks: [FakeHIDTask] = []

        func schedule(
            afterMilliseconds: UInt64,
            repeatingEveryMilliseconds: UInt64?,
            _ action: @escaping () -> Void
        ) -> HIDRemoteScheduledTask {
            let task = FakeHIDTask(action: action)
            tasks.append(task)
            return task
        }

        func fireAll() {
            tasks.forEach { $0.fire() }
        }
    }
}
