import AppKit
import Combine
import SwiftUI

@MainActor
final class VoiceContinuationWarningPanelController {
    private static let panelSize = NSSize(width: 580, height: 184)
    private static let topOffset: CGFloat = 44
    private let viewModel = VoiceContinuationWarningViewModel()
    private var panel: NSPanel?

    func update(isStreaming: Bool, remainingSeconds: Int?) {
        guard isStreaming,
              let remainingSeconds,
              (0...10).contains(remainingSeconds)
        else {
            hide()
            return
        }

        let panel = makePanelIfNeeded()
        viewModel.remainingSeconds = remainingSeconds
        position(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        // The native panel shadow follows the rectangular window bounds and
        // creates a visible square around the rounded SwiftUI card.
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        let hostingView = NSHostingView(
            rootView: VoiceContinuationWarningView(viewModel: viewModel)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.maxY - Self.panelSize.height - Self.topOffset
        )
        panel.setFrame(
            NSRect(origin: origin, size: Self.panelSize),
            display: true,
            animate: false
        )
    }
}

@MainActor
private final class VoiceContinuationWarningViewModel: ObservableObject {
    @Published var remainingSeconds = 0
}

private struct VoiceContinuationWarningView: View {
    private static let cardSize = CGSize(width: 500, height: 104)
    @ObservedObject var viewModel: VoiceContinuationWarningViewModel
    @State private var isPulsing = false

    private var remainingSeconds: Int {
        viewModel.remainingSeconds
    }

    private var isCritical: Bool {
        remainingSeconds <= 5
    }

    private var accentColor: Color {
        isCritical ? Color(red: 1.0, green: 0.23, blue: 0.19) :
            Color(red: 1.0, green: 0.58, blue: 0.05)
    }

    private var backgroundOpacity: Double {
        if isCritical {
            return isPulsing ? 0.96 : 0.84
        }
        return isPulsing ? 0.92 : 0.80
    }

    private var outerGlowOpacity: Double {
        if isCritical {
            return isPulsing ? 0.16 : 0.48
        }
        return isPulsing ? 0.12 : 0.36
    }

    private var innerGlowOpacity: Double {
        if isCritical {
            return isPulsing ? 0.28 : 0.62
        }
        return isPulsing ? 0.22 : 0.50
    }

    private let cardShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        ZStack {
            // Use blurred fills instead of strokes. This creates a soft glow
            // behind the card rather than a detached ring that scales around it.
            cardShape
                .fill(accentColor.opacity(outerGlowOpacity))
                .blur(radius: isPulsing ? 24 : 13)
                .scaleEffect(isPulsing ? 1.055 : 1.015)

            cardShape
                .fill(accentColor.opacity(innerGlowOpacity))
                .blur(radius: isPulsing ? 11 : 6)
                .scaleEffect(isPulsing ? 1.018 : 1.005)

            cardShape
                .fill(accentColor.opacity(backgroundOpacity))

            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.clear.tint(accentColor), in: cardShape)
                    .opacity(0.38)
            } else {
                cardShape
                    .fill(.ultraThinMaterial)
                    .opacity(0.22)
            }

            cardShape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.16),
                            .clear,
                            .black.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            HStack(spacing: 14) {
                Image(systemName: isCritical ? "mic.badge.xmark" : "mic.badge.exclamationmark")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 4) {
                    Text("voice_warning.title")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("voice_warning.action")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.96))
                }

                Spacer(minLength: 8)

                Text("\(remainingSeconds)s")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .shadow(color: .black.opacity(0.42), radius: 1.5, y: 1)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .shadow(
            color: accentColor.opacity(isPulsing ? 0.16 : 0.34),
            radius: isPulsing ? 13 : 8,
            y: 5
        )
        .padding(40)
        .animation(
            .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
            value: isPulsing
        )
        .onAppear {
            isPulsing = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("voice_warning.accessibility"))
    }
}
