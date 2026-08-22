import AppKit
import CoreGraphics
import Foundation

struct MouseModeScheduledTask {
    private let cancellation: () -> Void

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }

    static func repeatingOnMainRunLoop(
        interval: TimeInterval,
        operation: @escaping () -> Void
    ) -> MouseModeScheduledTask {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            operation()
        }
        RunLoop.main.add(timer, forMode: .common)
        return MouseModeScheduledTask { timer.invalidate() }
    }
}

final class MouseModeController {
    enum Phase: Equatable {
        case idle
        case active
    }

    static let tickInterval: TimeInterval = 1.0 / 60.0
    /// Caps the per-tick time delta so a stalled run loop reads as a pause
    /// instead of a multi-hundred-pixel jump.
    static let maximumTickDelta: TimeInterval = 0.05
    static let initialSpeed: Double = 160
    static let maximumSpeed: Double = 1400
    static let accelerationDuration: TimeInterval = 1.2
    /// Double-tap semantics reuse the gesture recognizer's double-click window
    /// (HIDRemoteTiming.doubleClickMilliseconds = 300): the first press must
    /// be released within this duration to count as a tap, and the second
    /// press must land within this duration after that release.
    static let doubleTapMaximumPressDuration: TimeInterval =
        Double(HIDRemoteTiming.doubleClickMilliseconds) / 1000
    static let doubleTapWindow: TimeInterval =
        Double(HIDRemoteTiming.doubleClickMilliseconds) / 1000
    /// OK long-press (send message = Return) reuses the gesture recognizer's
    /// long-press duration (HIDRemoteTiming.longPressMilliseconds = 550).
    static let okLongPressDuration: TimeInterval =
        Double(HIDRemoteTiming.longPressMilliseconds) / 1000
    static let returnKeyCode: CGKeyCode = 36

    static let directionButtons: Set<RemoteButton> = [.up, .down, .left, .right]
    /// Only directions and OK are intercepted in mouse mode; menu/back keep
    /// their normal bindings, and only the toggle binding exits the mode.
    static let managedButtons: Set<RemoteButton> = directionButtons.union([.ok])

    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> MouseModeScheduledTask
    typealias MovePoster = (CGPoint) -> Void
    typealias ClickPoster = (KeyboardInjector.MouseClickButton, CGPoint) -> Void
    typealias KeyPoster = (CGKeyCode, CGEventFlags) -> Void

    /// Per-direction double-tap tracking. A tap records the cursor position
    /// captured when its press started so a double-tap can bounce the cursor
    /// back before injecting the mapped key.
    private struct DirectionTapState {
        var pressedAt: TimeInterval?
        var positionAtPressStart: CGPoint?
        var lastTapReleasedAt: TimeInterval?
        var lastTapPosition: CGPoint?
        var suppressUntilRelease = false
    }

    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private let postMove: MovePoster
    private let postClick: ClickPoster
    private let keyPoster: KeyPoster
    private let cursorPosition: () -> CGPoint?
    private let screenBounds: () -> CGRect
    private let accessibilityTrusted: () -> Bool
    private let logger: (String) -> Void

    private(set) var phase: Phase = .idle
    private var pressedDirections = Set<RemoteButton>()
    private var directionStates: [RemoteButton: DirectionTapState] = [:]
    private var movementStartedAt: TimeInterval?
    private var lastTickAt: TimeInterval?
    private var tickTask: MouseModeScheduledTask?
    private var okLongPressTask: MouseModeScheduledTask?
    private var okLongPressFired = false
    /// Arms after a quick first OK release; fires the left click at the end of
    /// the double-tap window unless a second press cancels it first.
    private var okPendingClickTask: MouseModeScheduledTask?
    private var okIsSecondPress = false

    var onStateChange: ((Bool) -> Void)?
    var isActive: Bool { phase == .active }

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = MouseModeScheduledTask.repeatingOnMainRunLoop,
        postMove: @escaping MovePoster = { KeyboardInjector.postMouseMoved(to: $0) },
        postClick: @escaping ClickPoster = { KeyboardInjector.postMouseClick(button: $0, at: $1) },
        keyPoster: @escaping KeyPoster = { KeyboardInjector.postKey(code: $0, flags: $1) },
        cursorPosition: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
        screenBounds: @escaping () -> CGRect = { MouseModeController.quartzScreenBounds() },
        accessibilityTrusted: @escaping () -> Bool = { KeyboardInjector.isAccessibilityTrusted },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.now = now
        self.schedule = schedule
        self.postMove = postMove
        self.postClick = postClick
        self.keyPoster = keyPoster
        self.cursorPosition = cursorPosition
        self.screenBounds = screenBounds
        self.accessibilityTrusted = accessibilityTrusted
        self.logger = logger
    }

    @discardableResult
    func activate() -> Bool {
        guard phase == .idle else { return true }
        guard accessibilityTrusted() else {
            logger("MOUSE MODE activate rejected reason=accessibility_untrusted")
            return false
        }
        phase = .active
        tickTask = schedule(Self.tickInterval) { [weak self] in
            self?.tick()
        }
        logger("MOUSE MODE activated")
        onStateChange?(true)
        return true
    }

    func deactivate(reason: String = "manual") {
        guard phase == .active else { return }
        tickTask?.cancel()
        tickTask = nil
        okLongPressTask?.cancel()
        okLongPressTask = nil
        okLongPressFired = false
        okPendingClickTask?.cancel()
        okPendingClickTask = nil
        okIsSecondPress = false
        pressedDirections.removeAll()
        directionStates.removeAll()
        movementStartedAt = nil
        lastTickAt = nil
        phase = .idle
        logger("MOUSE MODE deactivated reason=\(reason)")
        onStateChange?(false)
    }

    @discardableResult
    func toggle() -> Bool {
        if phase == .active {
            deactivate(reason: "toggle_button")
            return true
        }
        return activate()
    }

    /// Returns true when the edge was consumed by mouse mode and must not reach
    /// gesture recognition or native passthrough.
    @discardableResult
    func handle(button: RemoteButton, edge: RemoteEventEdge) -> Bool {
        guard phase == .active, Self.managedButtons.contains(button) else { return false }
        switch button {
        case .up, .down, .left, .right:
            switch edge {
            case .down:
                directionPressed(button)
            case .up:
                directionReleased(button)
            }
        case .ok:
            switch edge {
            case .down:
                okPressed()
            case .up:
                okReleased()
            }
        default:
            return false
        }
        return true
    }

    /// OK three-gesture state machine: quick release arms a pending left click
    /// for the double-tap window; a second press inside the window cancels it
    /// and its quick release posts a right click; holding any press for the
    /// long-press duration injects Return (send) and suppresses all clicks.
    private func okPressed() {
        if okPendingClickTask != nil {
            okPendingClickTask?.cancel()
            okPendingClickTask = nil
            okIsSecondPress = true
        }
        okLongPressFired = false
        okLongPressTask?.cancel()
        okLongPressTask = schedule(Self.okLongPressDuration) { [weak self] in
            guard let self, self.phase == .active else { return }
            // The default scheduler repeats; make this a one-shot.
            self.okLongPressTask?.cancel()
            self.okLongPressTask = nil
            self.okLongPressFired = true
            self.keyPoster(Self.returnKeyCode, [])
            self.logger("MOUSE MODE long_press_send")
        }
    }

    private func okReleased() {
        okLongPressTask?.cancel()
        okLongPressTask = nil
        if okLongPressFired {
            okLongPressFired = false
            okIsSecondPress = false
            return
        }
        if okIsSecondPress {
            okIsSecondPress = false
            if let position = cursorPosition() {
                postClick(.right, position)
            }
            logger("MOUSE MODE double_tap_ok")
            return
        }
        // First quick release: arm the left click at the release position; a
        // second press within the window cancels it.
        let position = cursorPosition()
        okPendingClickTask?.cancel()
        okPendingClickTask = schedule(Self.doubleTapWindow) { [weak self] in
            guard let self, self.phase == .active else { return }
            // The default scheduler repeats; make this a one-shot.
            self.okPendingClickTask?.cancel()
            self.okPendingClickTask = nil
            if let position {
                self.postClick(.left, position)
            }
        }
    }

    private func directionPressed(_ button: RemoteButton) {
        let current = now()
        var state = directionStates[button] ?? DirectionTapState()
        if let releasedAt = state.lastTapReleasedAt,
           current - releasedAt <= Self.doubleTapWindow {
            // Double-tap: bounce the cursor back to where it was before the
            // first press, inject the mapped key, and suppress movement for
            // the rest of this press.
            if let position = state.lastTapPosition {
                postMove(position)
            }
            if let key = Self.doubleTapKey(for: button) {
                keyPoster(key.code, key.flags)
            }
            logger("MOUSE MODE double_tap button=\(button.rawValue)")
            state.pressedAt = nil
            state.positionAtPressStart = nil
            state.lastTapReleasedAt = nil
            state.lastTapPosition = nil
            state.suppressUntilRelease = true
            directionStates[button] = state
            return
        }
        state.pressedAt = current
        state.positionAtPressStart = cursorPosition()
        directionStates[button] = state
        if pressedDirections.isEmpty {
            movementStartedAt = current
            lastTickAt = nil
        }
        pressedDirections.insert(button)
    }

    private func directionReleased(_ button: RemoteButton) {
        let current = now()
        var state = directionStates[button] ?? DirectionTapState()
        if state.suppressUntilRelease {
            state.suppressUntilRelease = false
            state.pressedAt = nil
            state.positionAtPressStart = nil
            directionStates[button] = state
            return
        }
        pressedDirections.remove(button)
        if pressedDirections.isEmpty {
            movementStartedAt = nil
            lastTickAt = nil
        }
        if let pressedAt = state.pressedAt,
           current - pressedAt < Self.doubleTapMaximumPressDuration {
            state.lastTapReleasedAt = current
            state.lastTapPosition = state.positionAtPressStart
        } else {
            state.lastTapReleasedAt = nil
            state.lastTapPosition = nil
        }
        state.pressedAt = nil
        state.positionAtPressStart = nil
        directionStates[button] = state
    }

    /// Fixed double-tap mapping (not configurable): Page Up / Page Down /
    /// Command-[ (browser back) / Command-W (close window).
    static func doubleTapKey(for button: RemoteButton) -> (code: CGKeyCode, flags: CGEventFlags)? {
        switch button {
        case .up: return (116, [])
        case .down: return (121, [])
        case .left: return (33, .maskCommand)
        case .right: return (13, .maskCommand)
        default: return nil
        }
    }

    private func tick() {
        guard phase == .active else { return }
        guard !pressedDirections.isEmpty, let startedAt = movementStartedAt else {
            lastTickAt = nil
            return
        }
        let current = now()
        let elapsed = current - startedAt
        let delta = min(
            lastTickAt.map { current - $0 } ?? Self.tickInterval,
            Self.maximumTickDelta
        )
        lastTickAt = current
        guard delta > 0 else { return }

        let speed = Self.speed(afterHoldingFor: elapsed)
        var axisX = 0.0
        var axisY = 0.0
        if pressedDirections.contains(.left) { axisX -= 1 }
        if pressedDirections.contains(.right) { axisX += 1 }
        // CGEvent mouse locations use Quartz coordinates: +y moves down.
        if pressedDirections.contains(.up) { axisY -= 1 }
        if pressedDirections.contains(.down) { axisY += 1 }
        let length = (axisX * axisX + axisY * axisY).squareRoot()
        guard length > 0 else { return }

        let distance = speed * delta
        guard let origin = cursorPosition() else { return }
        let target = CGPoint(
            x: origin.x + axisX / length * distance,
            y: origin.y + axisY / length * distance
        )
        postMove(Self.clamped(target, to: screenBounds()))
    }

    /// Quadratic ease-in: slow enough for pixel-level aiming right after
    /// key-down (160 px/s), reaching full speed (1400 px/s) after 1.2 s.
    static func speed(afterHoldingFor elapsed: TimeInterval) -> Double {
        let progress = min(max(elapsed / accelerationDuration, 0), 1)
        return initialSpeed + (maximumSpeed - initialSpeed) * progress * progress
    }

    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        guard !bounds.isNull, !bounds.isEmpty else { return point }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    /// NSScreen frames use a bottom-left origin while CGEvent mouse locations
    /// use Quartz top-left display coordinates, so frames are flipped against
    /// the primary screen height before taking the union.
    static func quartzScreenBounds(
        screens: [NSScreen] = NSScreen.screens
    ) -> CGRect {
        guard let primaryHeight = screens.first?.frame.height else { return .null }
        return screens.reduce(CGRect.null) { partial, screen in
            let frame = screen.frame
            let quartz = CGRect(
                x: frame.origin.x,
                y: primaryHeight - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
            return partial.union(quartz)
        }
    }
}
