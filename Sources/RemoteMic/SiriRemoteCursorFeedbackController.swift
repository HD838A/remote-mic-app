import AppKit
import ApplicationServices
import Foundation

struct SiriRemoteCursorFeedbackState: Equatable {
    enum Presentation: Equatable {
        case pointer(scale: CGFloat)
        case scroll(direction: VerticalDirection, scale: CGFloat)
    }

    enum VerticalDirection: Equatable {
        case up
        case down
    }

    static let baseIndicatorDiameter: CGFloat = 14

    static func indicatorScale(forSpeed speed: Double) -> CGFloat {
        let normalized = min(1, max(0, (speed - 2.0) / 70.0))
        let smooth = normalized * normalized * (3 - 2 * normalized)
        return 1.0 + CGFloat(smooth) * 1.2
    }

    static func presentation(for feedback: SiriRemoteTouchFeedbackKind) -> Presentation? {
        switch feedback {
        case let .pointerMoved(_, _, speed):
            return .pointer(scale: indicatorScale(forSpeed: speed))
        case let .scrolled(pixels, speed):
            return .scroll(
                direction: scrollDirection(forPixels: pixels),
                scale: indicatorScale(forSpeed: speed)
            )
        case .clicked:
            return nil
        }
    }

    static func scrollDirection(forPixels pixels: Double) -> VerticalDirection {
        pixels >= 0 ? .up : .down
    }

    static func scrollSymbolName(for direction: VerticalDirection) -> String {
        switch direction {
        case .up: "arrow.up.circle.fill"
        case .down: "arrow.down.circle.fill"
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

    static let clickableTargetHoldDelay: TimeInterval = 1.2

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
        case rightBelow = "right_below"
        case leftBelow = "left_below"
        case rightAbove = "right_above"
        case leftAbove = "left_above"
        case clamped
    }

    let frame: NSRect
    let placement: Placement

    static func layout(
        for point: NSPoint,
        visibleFrame: NSRect,
        size: CGFloat = 40,
        cursorBodySize: NSSize = NSSize(width: 18, height: 24),
        gap: CGFloat = 4
    ) -> SiriRemoteCursorFeedbackLayout {
        let belowY = point.y - size - 4
        let candidates: [(Placement, NSRect)] = [
            (.rightBelow, NSRect(
                x: point.x + cursorBodySize.width + gap,
                y: belowY,
                width: size,
                height: size
            )),
            (.leftBelow, NSRect(
                x: point.x - gap - size,
                y: belowY,
                width: size,
                height: size
            )),
            (.rightAbove, NSRect(
                x: point.x + cursorBodySize.width + gap,
                y: point.y + gap,
                width: size,
                height: size
            )),
            (.leftAbove, NSRect(
                x: point.x - gap - size,
                y: point.y + gap,
                width: size,
                height: size
            )),
        ]
        if let candidate = candidates.first(where: { visibleFrame.contains($0.1) }) {
            return SiriRemoteCursorFeedbackLayout(
                frame: candidate.1,
                placement: candidate.0
            )
        }
        let preferred = candidates[0].1
        return SiriRemoteCursorFeedbackLayout(
            frame: NSRect(
                x: min(max(preferred.minX, visibleFrame.minX), visibleFrame.maxX - size),
                y: min(max(preferred.minY, visibleFrame.minY), visibleFrame.maxY - size),
                width: size,
                height: size
            ),
            placement: .clamped
        )
    }

    static func cursorProtectionFrame(
        for point: NSPoint,
        cursorBodySize: NSSize = NSSize(width: 18, height: 24)
    ) -> NSRect {
        NSRect(
            x: point.x,
            y: point.y - cursorBodySize.height,
            width: cursorBodySize.width,
            height: cursorBodySize.height
        )
    }
}

final class SiriRemoteCursorFeedbackController {
    private let view = SiriRemoteCursorFeedbackView(
        frame: NSRect(x: 0, y: 0, width: 40, height: 40)
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

    func handle(_ feedback: SiriRemoteTouchFeedbackKind) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(feedback) }
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
            view.presentation = .scroll(
                direction: SiriRemoteCursorFeedbackState.scrollDirection(forPixels: pixels),
                scale: SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: speed)
            )
            show(at: NSEvent.mouseLocation, mode: "scroll")
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
                contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
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

private final class SiriRemoteCursorFeedbackView: NSView {
    var presentation: SiriRemoteCursorFeedbackState.Presentation = .pointer(scale: 1.0)

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch presentation {
        case let .pointer(scale):
            drawPointer(scale: scale)
        case let .scroll(direction, scale):
            drawScroll(direction: direction, scale: scale)
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
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        halo.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        halo.lineWidth = 2
        halo.stroke()

        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - 2.5,
            y: center.y - 2.5,
            width: 5,
            height: 5
        )).fill()
    }

    private func drawScroll(
        direction: SiriRemoteCursorFeedbackState.VerticalDirection,
        scale: CGFloat
    ) {
        let symbolName = SiriRemoteCursorFeedbackState.scrollSymbolName(for: direction)
        guard let baseImage = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) else { return }
        let diameter = SiriRemoteCursorFeedbackState.baseIndicatorDiameter * scale
        let pointSize = NSImage.SymbolConfiguration(pointSize: diameter, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [
            NSColor.controlAccentColor.withAlphaComponent(0.96),
            NSColor.white.withAlphaComponent(0.98),
        ])
        let image = baseImage.withSymbolConfiguration(pointSize.applying(palette)) ?? baseImage
        image.draw(
            in: NSRect(
                x: bounds.midX - diameter / 2,
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}
