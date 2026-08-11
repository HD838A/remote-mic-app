import AppKit
import QuartzCore
import SwiftUI

enum PostDictationHUDPresentation {
    static let requestingStatusKey = "post_dictation.status.requesting"

    static func shouldShow(state: PostDictationPolishState, statusKey: String) -> Bool {
        state == .requesting && statusKey == requestingStatusKey
    }
}

enum PostDictationHUDLayout {
    static let windowSize = CGSize(width: 330, height: 80)
    static let bottomMargin: CGFloat = 12

    static func frame(in visibleFrame: CGRect) -> CGRect {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
        let x = min(
            max(visibleFrame.midX - windowSize.width / 2, visibleFrame.minX),
            maximumX
        )
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
        let y = min(
            visibleFrame.minY + bottomMargin,
            maximumY
        )
        return CGRect(origin: CGPoint(x: x, y: y), size: windowSize)
    }
}

@MainActor
final class PostDictationHUDController {
    private let localization: LocalizationStore
    private let panel: PostDictationHUDPanel
    private var shouldBeVisible = false
    private var transitionGeneration: UInt64 = 0

    init(localization: LocalizationStore) {
        self.localization = localization
        let hostingController = NSHostingController(
            rootView: PostDictationHUDView(localization: localization)
        )
        hostingController.view.frame = CGRect(origin: .zero, size: PostDictationHUDLayout.windowSize)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        panel = PostDictationHUDPanel(
            contentRect: CGRect(origin: .zero, size: PostDictationHUDLayout.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
    }

    func setVisible(_ visible: Bool) {
        guard visible != shouldBeVisible || (visible && !panel.isVisible) else { return }
        shouldBeVisible = visible
        transitionGeneration &+= 1
        let generation = transitionGeneration

        if visible {
            positionPanel()
            panel.setAccessibilityLabel(localization.text("post_dictation.hud.requesting"))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            return
        }

        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.transitionGeneration == generation,
                      !self.shouldBeVisible
                else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    func hideImmediately() {
        shouldBeVisible = false
        transitionGeneration &+= 1
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
        guard let screen else { return }
        panel.setFrame(PostDictationHUDLayout.frame(in: screen.visibleFrame), display: true)
    }
}

private final class PostDictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PostDictationHUDView: View {
    @ObservedObject var localization: LocalizationStore

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.65, blue: 0.08).opacity(0.18))
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.77, blue: 0.08))
            }
            .frame(width: 30, height: 30)

            Text(localization.text("post_dictation.hud.requesting"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.98, blue: 0.93))
                .lineLimit(1)

            Spacer(minLength: 4)

            TimelineView(.periodic(from: .now, by: 0.28)) { context in
                let activeIndex = Int(context.date.timeIntervalSinceReferenceDate / 0.28) % 3
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(progressColor(for: index, activeIndex: activeIndex))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .frame(width: 290, height: 52)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.15, green: 0.13, blue: 0.11).opacity(0.94))
                .shadow(color: Color.black.opacity(0.32), radius: 12, y: 5)
        )
        .frame(width: PostDictationHUDLayout.windowSize.width, height: PostDictationHUDLayout.windowSize.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localization.text("post_dictation.hud.requesting"))
    }

    private func progressColor(for index: Int, activeIndex: Int) -> Color {
        let colors = [
            Color(red: 1.0, green: 0.58, blue: 0.06),
            Color(red: 1.0, green: 0.68, blue: 0.04),
            Color(red: 1.0, green: 0.81, blue: 0.08),
        ]
        return colors[index].opacity(index == activeIndex ? 1 : 0.38)
    }
}
