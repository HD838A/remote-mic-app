import AppKit
import Combine
import SwiftUI

private final class CommonPhrasePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CommonPhraseController: ObservableObject {
    let store: CommonPhraseStore
    @Published private(set) var messageKey = "common_phrases.panel_hint"
    @Published private(set) var isVisible = false
    var onWillOpen: (() -> Void)?
    private var routing = CommonPhraseRouting()
    private var panel: NSPanel?
    private var feedbackPanel: NSPanel?
    private let inserter: CommonPhraseInserter
    private let frontmostProcessID: () -> pid_t?
    private var targetPID: pid_t?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation: UInt64 = 0
    private var localization: LocalizationStore?

    init(
        store: CommonPhraseStore,
        inserter: CommonPhraseInserter = CommonPhraseInserter(),
        frontmostProcessID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    ) {
        self.store = store
        self.inserter = inserter
        self.frontmostProcessID = frontmostProcessID
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let activated = workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, self.isVisible,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != self.targetPID else { return }
            self.close(reason: "frontmost_changed")
        }
        observers.append((workspaceCenter, activated))
        let resigned = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close(reason: "app_background")
        }
        observers.append((.default, resigned))
        let slept = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close(reason: "system_sleep")
        }
        observers.append((workspaceCenter, slept))
        let locked = workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close(reason: "session_inactive")
        }
        observers.append((workspaceCenter, locked))
    }

    deinit { for (center, observer) in observers { center.removeObserver(observer) } }

    @discardableResult
    func open(source: String, localization: LocalizationStore) -> Bool {
        guard store.isAvailable else {
            AppLogger.shared.write("COMMON_PHRASES PANEL phase=failed reason=resource_unavailable")
            return false
        }
        close(reason: "superseded")
        onWillOpen?()
        self.localization = localization
        generation &+= 1
        targetPID = frontmostProcessID()
        routing.open(source: source)
        messageKey = "common_phrases.panel_hint"
        isVisible = true
        let window = CommonPhrasePanel(contentRect: NSRect(origin: .zero, size: CommonPhrasePanelView.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CommonPhrasePanelView(controller: self).environmentObject(localization))
        if let frame = NSScreen.main?.frame {
            window.setFrameOrigin(NSPoint(x: frame.midX - CommonPhrasePanelView.size.width / 2, y: frame.midY - CommonPhrasePanelView.size.height / 2))
        }
        panel = window
        window.orderFrontRegardless()
        AppLogger.shared.write("COMMON_PHRASES PANEL operation_id=\(generation) phase=opened result=visible")
        return true
    }

    func close(reason: String) {
        routing.close()
        inserter.cancelPending()
        guard isVisible || feedbackPanel != nil else { return }
        feedbackPanel?.orderOut(nil)
        feedbackPanel?.contentView = nil
        feedbackPanel = nil
        isVisible = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        AppLogger.shared.write("COMMON_PHRASES PANEL operation_id=\(generation) phase=closed reason=\(reason)")
        generation &+= 1
    }

    func reset(source: String) {
        if routing.owner == source { close(reason: "input_reset") }
        routing.reset(source: source)
    }

    func handle(_ button: RemoteButton, phase: RemoteButtonPhase, source: String) -> Bool {
        switch routing.handle(button, phase: phase, source: source) {
        case .unhandled: return false
        case .consumed: return true
        case .close: close(reason: "back")
        case let .insert(button): insert(button)
        }
        return true
    }

    func claims(_ button: RemoteButton, source: String) -> Bool { routing.claims(button, source: source) }

    func insert(_ button: RemoteButton) {
        guard isVisible, let targetPID, let localization else { return }
        let phrase = store.phrase(for: button)
        // End the one-shot panel before submitting. Its held release remains
        // claimed, and the new insertion survives the panel's cancellation.
        close(reason: "selection")
        guard let phrase else {
            AppLogger.shared.write("COMMON_PHRASES INSERT operation_id=\(generation) phase=failed result=failed reason=no_phrase")
            showFailure("common_phrases.error.no_phrase")
            return
        }
        let current = generation
        inserter.insert(phrase.text(english: localization.locale.language.languageCode?.identifier == "en"), into: targetPID) { [weak self] key in
            guard let self, self.generation == current, key.hasPrefix("common_phrases.error.") else { return }
            self.showFailure(key)
        }
    }

    private func showFailure(_ key: String) {
        guard let localization else { return }
        messageKey = key
        let size = CGSize(width: 300, height: 100)
        let window = CommonPhrasePanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            Text(localization.text(key)).font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center).foregroundStyle(.white).padding(16)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 16)).opacity(0.8))
        if let frame = NSScreen.main?.frame {
            window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        feedbackPanel = window
        window.orderFrontRegardless()
        AppLogger.shared.write("COMMON_PHRASES FEEDBACK operation_id=\(generation) phase=shown result=visible reason=insertion_failed")
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == current else { return }
            self.close(reason: "failure_hint_timeout")
        }
    }
}

struct CommonPhrasePanelView: View {
    static let size = CGSize(width: 300, height: 360)
    @ObservedObject var controller: CommonPhraseController
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        VStack(spacing: 12) {
            Text(localization.text(controller.messageKey))
                .font(.system(size: 14, weight: .medium))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .top)
                .overlay(alignment: .bottomTrailing) {
                    Button { controller.close(reason: "close_button") } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localization.text("common_phrases.close"))
                }
            CommonPhrasePad(store: controller.store, diameter: 272, onSelect: controller.insert)
        }
        .padding(14).frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(.white)
        .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 22))
        .opacity(0.8)
        .environment(\.colorScheme, .dark)
    }
}

/// The panel and the editor share the same layout; callers decide whether a
/// press inserts text or merely selects the assignment position.
struct CommonPhrasePad: View {
    @ObservedObject var store: CommonPhraseStore
    var diameter: CGFloat
    var selectedButton: RemoteButton? = nil
    var onSelect: (RemoteButton) -> Void
    @EnvironmentObject private var localization: LocalizationStore
    private var english: Bool { localization.locale.language.languageCode?.identifier == "en" }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.065)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
            ForEach([RemoteButton.up, .right, .down, .left]) { button in
                direction(button)
            }
            Button { onSelect(.ok) } label: {
                VStack(spacing: 5) {
                    Text("OK").font(.system(size: diameter > 300 ? 22 : 17, weight: .semibold))
                    phraseLabel(.ok)
                }
                .frame(width: diameter * 0.38, height: diameter * 0.38)
                .background(
                    LinearGradient(colors: [Color(white: 0.19), Color(white: 0.085)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
                .overlay(Circle().stroke(selectedButton == .ok ? Color.accentColor : Color.black,
                                         lineWidth: selectedButton == .ok ? 2 : 1))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("OK"))
            .accessibilityValue(store.phrase(for: .ok)?.label(english: english) ?? localization.text("common_phrases.unassigned"))
            .accessibilityIdentifier("common-phrases-position-ok")
            .accessibilityAddTraits(selectedButton == .ok ? .isSelected : [])
        }
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
    }

    private func direction(_ button: RemoteButton) -> some View {
        let vertical = button == .up || button == .down
        let position: CGPoint = switch button {
        case .up: CGPoint(x: 0.5, y: 0.17)
        case .down: CGPoint(x: 0.5, y: 0.84)
        case .left: CGPoint(x: 0.15, y: 0.5)
        default: CGPoint(x: 0.85, y: 0.5)
        }
        let symbol: String = switch button {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        default: "chevron.right"
        }
        let sector = CommonPhraseDirectionSector(button: button)
        return Button { onSelect(button) } label: {
            ZStack {
                sector.fill(selectedButton == button ? Color.accentColor.opacity(0.25) : .clear)
                if selectedButton == button {
                    sector.stroke(Color.accentColor, lineWidth: 2)
                }
                VStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: diameter > 300 ? 23 : 18, weight: .semibold))
                    phraseLabel(button)
                }
                .frame(width: diameter * (vertical ? 0.52 : 0.27))
                .position(x: diameter * position.x, y: diameter * position.y)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(sector)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.text("common_phrases.key.\(button.rawValue)"))
        .accessibilityValue(store.phrase(for: button)?.label(english: english) ?? localization.text("common_phrases.unassigned"))
        .accessibilityIdentifier("common-phrases-position-\(button.rawValue)")
        .accessibilityAddTraits(selectedButton == button ? .isSelected : [])
    }

    private func phraseLabel(_ button: RemoteButton) -> some View {
        Text(store.phrase(for: button)?.label(english: english) ?? localization.text("common_phrases.unassigned"))
            .font(.system(size: diameter > 300 ? 15 : 12))
            .lineLimit(2).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CommonPhraseDirectionSector: Shape {
    let button: RemoteButton

    func path(in rect: CGRect) -> Path {
        let start: Double = switch button {
        case .up: 225
        case .right: 315
        case .down: 45
        default: 135
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.38
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .degrees(start),
                    endAngle: .degrees(start + 90), clockwise: false)
        path.addLine(to: CGPoint(x: center.x + inner * cos((start + 90) * .pi / 180),
                                y: center.y + inner * sin((start + 90) * .pi / 180)))
        path.addArc(center: center, radius: inner, startAngle: .degrees(start + 90),
                    endAngle: .degrees(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}
