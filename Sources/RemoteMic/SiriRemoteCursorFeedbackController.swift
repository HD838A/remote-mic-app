import AppKit
import Foundation

struct SiriRemoteCursorFeedbackState: Equatable {
    enum Presentation: Equatable {
        case pointer(scale: CGFloat)
        case scroll(symbol: String)
    }

    static func pointerScale(forSpeed speed: Double) -> CGFloat {
        let normalized = min(1, max(0, (speed - 2.0) / 70.0))
        let smooth = normalized * normalized * (3 - 2 * normalized)
        return 1.0 + CGFloat(smooth) * 1.2
    }

    static func scrollSymbol(forPixels pixels: Double) -> String {
        pixels >= 0 ? "↑" : "↓"
    }
}

final class SiriRemoteCursorFeedbackController {
    private let view = SiriRemoteCursorFeedbackView(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
    private var window: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var lastRenderUptime: TimeInterval = 0

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
            view.presentation = .pointer(
                scale: SiriRemoteCursorFeedbackState.pointerScale(forSpeed: speed)
            )
            show(at: NSEvent.mouseLocation)
            scheduleHide(after: 0.24)
        case let .scrolled(pixels, _):
            view.presentation = .scroll(
                symbol: SiriRemoteCursorFeedbackState.scrollSymbol(forPixels: pixels)
            )
            show(at: NSEvent.mouseLocation)
            scheduleHide(after: 0.55)
        case .clicked:
            scheduleHide(after: 0.12)
        }
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        hideWorkItem?.cancel()
        hideWorkItem = nil
        window?.orderOut(nil)
    }

    private func show(at point: NSPoint) {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 72, height: 72),
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
        let frame = NSRect(
            x: point.x - 36,
            y: point.y - 36,
            width: 72,
            height: 72
        )
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
        view.needsDisplay = true
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
        case let .scroll(symbol):
            drawScroll(symbol: symbol)
        }
    }

    private func drawPointer(scale: CGFloat) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = 11.0 * scale
        NSColor.systemBlue.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()

        let pointer = NSBezierPath()
        func scaled(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(
                x: center.x + x * scale,
                y: center.y + y * scale
            )
        }
        pointer.move(to: scaled(-7, 13))
        pointer.line(to: scaled(-2, -9))
        pointer.line(to: scaled(4, -3))
        pointer.line(to: scaled(10, -8))
        pointer.line(to: scaled(2, 14))
        pointer.close()
        NSColor.white.withAlphaComponent(0.95).setFill()
        pointer.fill()
        NSColor.systemBlue.setStroke()
        pointer.lineWidth = 1.5
        pointer.stroke()
    }

    private func drawScroll(symbol: String) {
        let pill = NSBezierPath(roundedRect: NSRect(x: 12, y: 17, width: 48, height: 38), xRadius: 14, yRadius: 14)
        NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
        pill.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
        ]
        let text = NSAttributedString(string: symbol, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2 - 1
        ))
    }
}
