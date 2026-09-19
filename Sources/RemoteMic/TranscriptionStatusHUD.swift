import AppKit
import SwiftUI

/// A small floating "pill" indicator — in the spirit of iOS's Dynamic
/// Island — that appears near the top of the screen while the embedded
/// transcription engine is recording or working, so pressing the remote's
/// voice button gives visible feedback instead of silence. Purely a status
/// display: it never intercepts clicks or takes focus.
final class TranscriptionStatusHUD {
    enum Phase: Equatable {
        case recording
        case transcribing
        case inserted(characterCount: Int)
        case noSpeech

        fileprivate var systemImageName: String {
            switch self {
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
            case .inserted: return "checkmark"
            case .noSpeech: return "questionmark"
            }
        }

        fileprivate var label: String {
            switch self {
            case .recording: return "Recording…"
            case .transcribing: return "Transcribing…"
            case let .inserted(count): return "Inserted \(count) characters"
            case .noSpeech: return "No speech detected"
            }
        }

        /// Terminal phases auto-hide shortly after appearing; `.recording`
        /// and `.transcribing` stay up until the next phase replaces them.
        fileprivate var autoHideDelay: TimeInterval? {
            switch self {
            case .recording, .transcribing: return nil
            case .inserted, .noSpeech: return 1.4
            }
        }
    }

    private var panel: NSPanel?
    private let state = TranscriptionStatusHUDState()
    private var hideWorkItem: DispatchWorkItem?

    /// Shows (creating the panel on first use) or updates the HUD to the
    /// given phase. Safe to call repeatedly; each call cancels any pending
    /// auto-hide from a previous phase. Callers are responsible for already
    /// being on the main actor — this type holds AppKit/SwiftUI state but
    /// isn't itself actor-isolated, so it can be stored as a plain property
    /// on a non-isolated owner like `BridgeAppModel`.
    @MainActor
    func show(_ phase: Phase) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        state.phase = phase
        if panel == nil {
            panel = makePanel()
        }
        positionAndShow()
        if let delay = phase.autoHideDelay {
            let workItem = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    /// Dismisses the HUD immediately (e.g. destination was unsafe, or the
    /// buffer turned out to be silent and nothing was ever shown).
    @MainActor
    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    @MainActor
    private func makePanel() -> NSPanel {
        let hostingView = NSHostingView(
            rootView: TranscriptionStatusHUDView(state: state)
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        return panel
    }

    @MainActor
    private func positionAndShow() {
        guard let panel, let screen = NSScreen.main else { return }
        let fittingSize = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 44)
        let size = NSSize(width: max(fittingSize.width, 160), height: max(fittingSize.height, 44))
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 12
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

// Deliberately not @MainActor: it's stored as a default-initialized property
// on TranscriptionStatusHUD, which is itself constructed from BridgeAppModel's
// non-isolated init. Every actual mutation and read happens from the
// @MainActor-isolated methods above, which is all SwiftUI requires in
// practice for a Published property backing a view it renders.
private final class TranscriptionStatusHUDState: ObservableObject {
    @Published var phase: TranscriptionStatusHUD.Phase = .recording
}

private struct TranscriptionStatusHUDView: View {
    @ObservedObject fileprivate var state: TranscriptionStatusHUDState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.phase.systemImageName)
                .font(.system(size: 13, weight: .semibold))
            Text(state.phase.label)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(.black.opacity(0.82))
        )
        .fixedSize()
        .animation(.easeInOut(duration: 0.15), value: state.phase)
    }
}
