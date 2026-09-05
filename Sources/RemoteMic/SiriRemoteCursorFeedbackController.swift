import AppKit
import Foundation

struct SiriRemoteCursorFeedbackState: Equatable {
    enum Presentation: Equatable {
        case pointer(scale: CGFloat)
        case scroll(direction: VerticalDirection)
    }

    static func pointerScale(forSpeed speed: Double) -> CGFloat {
        let normalized = min(1, max(0, (speed - 2.0) / 70.0))
        let smooth = normalized * normalized * (3 - 2 * normalized)
        return 1.0 + CGFloat(smooth) * 1.2
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

    enum VerticalDirection: Equatable {
        case up
        case down
    }
}

struct SiriRemoteCursorFeedbackLayout {
    static func frame(
        for point: NSPoint,
        visibleFrame: NSRect,
        size: CGFloat = 48,
        cursorBodyOffset: NSPoint = NSPoint(x: 8, y: -8)
    ) -> NSRect {
        let center = NSPoint(
            x: point.x + cursorBodyOffset.x,
            y: point.y + cursorBodyOffset.y
        )
        let originX = min(
            max(center.x - size / 2, visibleFrame.minX),
            visibleFrame.maxX - size
        )
        let originY = min(
            max(center.y - size / 2, visibleFrame.minY),
            visibleFrame.maxY - size
        )
        return NSRect(x: originX, y: originY, width: size, height: size)
    }
}

final class SiriRemoteCursorFeedbackController {
    private let view = SiriRemoteCursorFeedbackView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
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
                direction: SiriRemoteCursorFeedbackState.scrollDirection(forPixels: pixels)
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
                contentRect: NSRect(x: 0, y: 0, width: 48, height: 48),
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
        let frame = NSScreen.screens
            .first(where: { $0.visibleFrame.contains(point) })
            .map { SiriRemoteCursorFeedbackLayout.frame(for: point, visibleFrame: $0.visibleFrame) }
            ?? NSRect(x: point.x - 16, y: point.y - 32, width: 48, height: 48)
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
        case let .scroll(direction):
            drawScroll(direction: direction)
        }
    }

    private func drawPointer(scale: CGFloat) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = 8.0 * scale
        let halo = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        halo.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.82).setStroke()
        halo.lineWidth = 2
        halo.stroke()

        NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - 2.5,
            y: center.y - 2.5,
            width: 5,
            height: 5
        )).fill()
    }

    private func drawScroll(direction: SiriRemoteCursorFeedbackState.VerticalDirection) {
        let symbolName = SiriRemoteCursorFeedbackState.scrollSymbolName(for: direction)
        guard let baseImage = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        ) else { return }
        let pointSize = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [
            NSColor.controlAccentColor.withAlphaComponent(0.96),
            NSColor.white.withAlphaComponent(0.98),
        ])
        let image = baseImage.withSymbolConfiguration(pointSize.applying(palette)) ?? baseImage
        image.draw(
            in: NSRect(x: bounds.midX - 11, y: bounds.midY - 11, width: 22, height: 22),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}
