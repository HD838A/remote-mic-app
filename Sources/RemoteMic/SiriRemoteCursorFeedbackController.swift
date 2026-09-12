import AppKit
import ApplicationServices
import Foundation

struct SiriRemoteCursorFeedbackState: Equatable {
    enum Presentation: Equatable {
        case pointer(scale: CGFloat)
        case scroll(direction: PageDirection, arrowCount: Int, scale: CGFloat)
    }

    enum PageDirection: String, Equatable {
        case up
        case down

        var reversed: PageDirection {
            self == .up ? .down : .up
        }
    }

    static let baseIndicatorDiameter: CGFloat = 36

    static func indicatorScale(forSpeed speed: Double) -> CGFloat {
        let normalized = min(1, max(0, (speed - 2.0) / 70.0))
        let smooth = normalized * normalized * (3 - 2 * normalized)
        return 1.0 + CGFloat(smooth) * 1.2
    }

    static func arrowCount(forSpeed speed: Double) -> Int {
        if speed < 8 { return 1 }
        if speed < 24 { return 2 }
        return 3
    }

    static func pageDirection(
        forScrollPixels pixels: Double,
        reversed: Bool
    ) -> PageDirection? {
        guard pixels != 0 else { return nil }
        let direction: PageDirection = pixels > 0 ? .up : .down
        return reversed ? direction.reversed : direction
    }

    static func presentation(
        for feedback: SiriRemoteTouchFeedbackKind,
        scrollArrowReversed: Bool = false
    ) -> Presentation? {
        switch feedback {
        case let .pointerMoved(_, _, speed):
            return .pointer(scale: indicatorScale(forSpeed: speed))
        case let .scrolled(pixels, speed):
            guard let direction = pageDirection(
                forScrollPixels: pixels,
                reversed: scrollArrowReversed
            ) else { return nil }
            return .scroll(
                direction: direction,
                arrowCount: arrowCount(forSpeed: speed),
                scale: indicatorScale(forSpeed: speed)
            )
        case .clicked:
            return nil
        }
    }

    static func cursorRemainsAtTarget(
        current: CGPoint,
        target: CGPoint,
        tolerance: CGFloat = 2
    ) -> Bool {
        hypot(current.x - target.x, current.y - target.y) <= tolerance
    }
}

struct SiriRemoteCursorFeedbackInteractionState {
    enum PointerIdleAction: Equatable {
        case hide
        case holdForClick(TimeInterval)
    }

    static let clickableTargetHoldDelay: TimeInterval = 2.0

    private var canConsumeOK = false

    mutating func pointerMoved() {
        canConsumeOK = false
    }

    mutating func pointerBecameIdle(hasClickableTarget: Bool) -> PointerIdleAction {
        canConsumeOK = hasClickableTarget
        return hasClickableTarget
            ? .holdForClick(Self.clickableTargetHoldDelay)
            : .hide
    }

    mutating func consumeOK() -> Bool {
        guard canConsumeOK else { return false }
        canConsumeOK = false
        return true
    }

    mutating func scrolled() {
        canConsumeOK = false
    }

    mutating func expired() {
        canConsumeOK = false
    }
}

struct SiriRemotePressableTargetResolver {
    static let maximumAncestorDepth = 4

    static func resolve<Node>(
        startingAt element: Node,
        maximumAncestorDepth: Int = maximumAncestorDepth,
        supportsPress: (Node) -> Bool,
        parent: (Node) -> Node?
    ) -> (element: Node, depth: Int)? {
        var candidate: Node? = element
        for depth in 0...maximumAncestorDepth {
            guard let current = candidate else { return nil }
            if supportsPress(current) {
                return (current, depth)
            }
            candidate = parent(current)
        }
        return nil
    }
}

struct SiriRemoteCursorFeedbackLayout: Equatable {
    enum Placement: String, Equatable {
        case centeredOnCursor = "centered_on_cursor"
    }

    let frame: NSRect
    let placement: Placement

    static func layout(
        for point: NSPoint,
        visibleFrame: NSRect,
        size: CGFloat = 104,
        cursorBodySize: NSSize = NSSize(width: 18, height: 24)
    ) -> SiriRemoteCursorFeedbackLayout {
        _ = visibleFrame
        let center = cursorBodyCenter(for: point, cursorBodySize: cursorBodySize)
        return SiriRemoteCursorFeedbackLayout(
            frame: NSRect(
                x: center.x - size / 2,
                y: center.y - size / 2,
                width: size,
                height: size
            ),
            placement: .centeredOnCursor
        )
    }

    static func cursorBodyCenter(
        for point: NSPoint,
        cursorBodySize: NSSize = NSSize(width: 18, height: 24)
    ) -> NSPoint {
        NSPoint(
            x: point.x + cursorBodySize.width / 2,
            y: point.y - cursorBodySize.height / 2
        )
    }
}

final class SiriRemoteCursorFeedbackController {
    private let view = SiriRemoteCursorFeedbackView(
        frame: NSRect(x: 0, y: 0, width: 104, height: 104)
    )
    private let logger: (String) -> Void
    private var window: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var lastRenderUptime: TimeInterval = 0
    private var isFeedbackVisible = false
    private var interactionState = SiriRemoteCursorFeedbackInteractionState()
    private var hoveredElement: AXUIElement?
    private var hoveredElementDepth = 0
    private var hoveredCursorLocation: CGPoint?

    init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    func handle(
        _ feedback: SiriRemoteTouchFeedbackKind,
        scrollArrowReversed: Bool = false
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handle(feedback, scrollArrowReversed: scrollArrowReversed)
            }
            return
        }
        switch feedback {
        case let .pointerMoved(_, _, speed):
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastRenderUptime >= 1.0 / 120.0 else { return }
            lastRenderUptime = now
            interactionState.pointerMoved()
            hoveredElement = nil
            hoveredCursorLocation = nil
            view.presentation = .pointer(scale: SiriRemoteCursorFeedbackState.indicatorScale(
                forSpeed: speed
            ))
            show(at: NSEvent.mouseLocation, mode: "pointer")
            schedulePointerIdleEvaluation(after: 0.24)
        case let .scrolled(pixels, speed):
            interactionState.scrolled()
            hoveredElement = nil
            hoveredCursorLocation = nil
            guard let direction = SiriRemoteCursorFeedbackState.pageDirection(
                forScrollPixels: pixels,
                reversed: scrollArrowReversed
            ) else { return }
            let arrowCount = SiriRemoteCursorFeedbackState.arrowCount(forSpeed: speed)
            view.presentation = .scroll(
                direction: direction,
                arrowCount: arrowCount,
                scale: SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: speed)
            )
            show(
                at: NSEvent.mouseLocation,
                mode: "scroll_\(direction.rawValue)_arrows_\(arrowCount)"
            )
            scheduleHide(after: 0.55)
        case .clicked:
            interactionState.scrolled()
            hoveredElement = nil
            hoveredCursorLocation = nil
            scheduleHide(after: 0.12)
        }
    }

    @discardableResult
    func activateHoveredElementIfAvailable() -> Bool {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { [weak self] in
                self?.activateHoveredElementIfAvailable() ?? false
            }
        }
        guard interactionState.consumeOK(), let hoveredElement else { return false }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        self.hoveredElement = nil
        let targetDepth = hoveredElementDepth
        let targetLocation = hoveredCursorLocation
        hoveredElementDepth = 0
        hoveredCursorLocation = nil
        guard let targetLocation else {
            hide(reason: "hover_click_target_location_unavailable")
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_click result=failed " +
                    "reason=target_location_unavailable fallback=normal_mapping"
            )
            return false
        }
        guard let currentLocation = CGEvent(source: nil)?.location else {
            hide(reason: "hover_click_cursor_unavailable")
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_click result=failed " +
                    "reason=cursor_location_unavailable fallback=normal_mapping"
            )
            return false
        }
        guard SiriRemoteCursorFeedbackState.cursorRemainsAtTarget(
            current: currentLocation,
            target: targetLocation
        ) else {
            hide(reason: "hover_click_cursor_moved")
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_click result=cancelled " +
                    "reason=cursor_moved fallback=normal_mapping"
            )
            return false
        }
        let error = AXUIElementPerformAction(hoveredElement, kAXPressAction as CFString)
        if error == .success {
            hide(reason: "hover_click_activated")
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_click result=completed " +
                    "action=ax_press target_depth=\(targetDepth)"
            )
            return true
        }
        hide(reason: "hover_click_failed")
        logger(
            "APPLE REMOTE TOUCH FEEDBACK phase=hover_click result=failed " +
                "action=ax_press error=\(error.rawValue) fallback=normal_mapping"
        )
        return false
    }

    func stop() {
        cancelInteraction(reason: "app_stop")
    }

    func cancelInteraction(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.cancelInteraction(reason: reason)
            }
            return
        }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        interactionState.expired()
        hoveredElement = nil
        hoveredElementDepth = 0
        hoveredCursorLocation = nil
        hide(reason: reason)
    }

    private func show(at point: NSPoint, mode: String) {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 104, height: 104),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = view
            window = panel
        }
        let visibleFrame = NSScreen.screens
            .first(where: { $0.visibleFrame.contains(point) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200)
        let layout = SiriRemoteCursorFeedbackLayout.layout(
            for: point,
            visibleFrame: visibleFrame
        )
        window?.setFrame(layout.frame, display: true)
        window?.orderFrontRegardless()
        view.needsDisplay = true
        if !isFeedbackVisible {
            isFeedbackVisible = true
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=shown result=visible " +
                    "mode=\(mode) placement=\(layout.placement.rawValue)"
            )
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide(reason: "idle_timeout")
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func schedulePointerIdleEvaluation(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.resolvePointerIdleTarget()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resolvePointerIdleTarget() {
        let target = clickableElementAtCursor()
        switch interactionState.pointerBecameIdle(hasClickableTarget: target != nil) {
        case .hide:
            hoveredElement = nil
            hoveredElementDepth = 0
            hoveredCursorLocation = nil
            hide(reason: "pointer_idle_no_clickable_target")
        case let .holdForClick(delay):
            hoveredElement = target?.element
            hoveredElementDepth = target?.depth ?? 0
            hoveredCursorLocation = target?.cursorLocation
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_target result=held " +
                    "action=ax_press target_depth=\(hoveredElementDepth) " +
                    "hold_ms=\(Int(delay * 1_000))"
            )
            scheduleClickableTargetExpiration(after: delay)
        }
    }

    private func scheduleClickableTargetExpiration(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.interactionState.expired()
            self.hoveredElement = nil
            self.hoveredElementDepth = 0
            self.hoveredCursorLocation = nil
            self.logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_target result=expired"
            )
            self.hide(reason: "click_window_expired")
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clickableElementAtCursor() -> (
        element: AXUIElement,
        depth: Int,
        cursorLocation: CGPoint
    )? {
        guard let location = CGEvent(source: nil)?.location else {
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_target result=failed " +
                    "reason=cursor_location_unavailable"
            )
            return nil
        }
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let elementError = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(location.x),
            Float(location.y),
            &element
        )
        guard elementError == .success, let element else {
            logger(
                "APPLE REMOTE TOUCH FEEDBACK phase=hover_target result=failed " +
                    "reason=ax_element_unavailable error=\(elementError.rawValue)"
            )
            return nil
        }
        guard let target = SiriRemotePressableTargetResolver.resolve(
            startingAt: element,
            supportsPress: { self.supportsPress($0) },
            parent: { self.parentElement(of: $0) }
        ) else { return nil }
        return (target.element, target.depth, location)
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        var actionNames: CFArray?
        let error = AXUIElementCopyActionNames(element, &actionNames)
        guard error == .success, let names = actionNames as? [String] else { return false }
        return names.contains(kAXPressAction as String)
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        )
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func hide(reason: String) {
        window?.orderOut(nil)
        guard isFeedbackVisible else { return }
        isFeedbackVisible = false
        logger(
            "APPLE REMOTE TOUCH FEEDBACK phase=hidden result=completed reason=\(reason)"
        )
    }
}

final class SiriRemoteCursorFeedbackView: NSView {
    var presentation: SiriRemoteCursorFeedbackState.Presentation = .pointer(scale: 1.0)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch presentation {
        case let .pointer(scale):
            drawPointer(scale: scale)
        case let .scroll(direction, arrowCount, scale):
            drawScroll(direction: direction, arrowCount: arrowCount, scale: scale)
        }
    }

    private func drawPointer(scale: CGFloat) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = SiriRemoteCursorFeedbackState.baseIndicatorDiameter * scale / 2
        let halo = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.controlAccentColor.withAlphaComponent(0.22).setStroke()
        halo.lineWidth = 7
        halo.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        halo.lineWidth = 2
        halo.stroke()
    }

    private func drawScroll(
        direction: SiriRemoteCursorFeedbackState.PageDirection,
        arrowCount: Int,
        scale: CGFloat
    ) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = SiriRemoteCursorFeedbackState.baseIndicatorDiameter * scale / 2
        let background = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.controlAccentColor.withAlphaComponent(0.12).setStroke()
        background.lineWidth = 5
        background.stroke()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 38,
            endAngle: 322,
            clockwise: false
        )
        NSColor.controlAccentColor.withAlphaComponent(0.96).setStroke()
        arc.lineWidth = 3.2
        arc.lineCapStyle = .round
        arc.stroke()

        let count = min(3, max(1, arrowCount))
        let chevronWidth = max(8, min(12, radius * 0.48))
        let chevronHeight = chevronWidth * 0.55
        let spacing = chevronHeight * 1.45
        let groupHeight = CGFloat(count - 1) * spacing
        let x = center.x + radius * 0.92
        let directionSign: CGFloat = direction == .up ? 1 : -1

        for index in 0..<count {
            let y = center.y - groupHeight / 2 + CGFloat(index) * spacing
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(
                x: x - chevronWidth / 2,
                y: y - directionSign * chevronHeight / 2
            ))
            chevron.line(to: NSPoint(
                x: x,
                y: y + directionSign * chevronHeight / 2
            ))
            chevron.line(to: NSPoint(
                x: x + chevronWidth / 2,
                y: y - directionSign * chevronHeight / 2
            ))
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setStroke()
            chevron.lineWidth = 5
            chevron.stroke()
            NSColor.controlAccentColor.withAlphaComponent(0.98).setStroke()
            chevron.lineWidth = 2.4
            chevron.stroke()
        }
    }
}
