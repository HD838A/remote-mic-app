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
    private let inserter: CommonPhraseInserter
    private var targetPID: pid_t?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation: UInt64 = 0
    private var localization: LocalizationStore?

    init(store: CommonPhraseStore, inserter: CommonPhraseInserter = CommonPhraseInserter()) {
        self.store = store
        self.inserter = inserter
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
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        routing.open(source: source)
        messageKey = "common_phrases.panel_hint"
        isVisible = true
        let window = CommonPhrasePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 330),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CommonPhrasePanelView(controller: self).environmentObject(localization))
        if let frame = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - 240, y: frame.minY + 48))
        }
        panel = window
        window.orderFrontRegardless()
        AppLogger.shared.write("COMMON_PHRASES PANEL operation_id=\(generation) phase=opened result=visible")
        return true
    }

    func close(reason: String) {
        routing.close()
        inserter.cancelPending()
        guard isVisible else { return }
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
        guard let phrase = store.phrase(for: button) else {
            messageKey = "common_phrases.error.no_phrase"
            AppLogger.shared.write("COMMON_PHRASES INSERT phase=failed reason=no_phrase")
            return
        }
        let current = generation
        messageKey = "common_phrases.inserting"
        inserter.insert(phrase.text(english: localization.locale.language.languageCode?.identifier == "en"), into: targetPID) { [weak self] key in
            guard let self, self.generation == current, self.isVisible else { return }
            self.messageKey = key
        }
    }
}

struct CommonPhrasePanelView: View {
    @ObservedObject var controller: CommonPhraseController
    @EnvironmentObject private var localization: LocalizationStore
    private var english: Bool { localization.locale.language.languageCode?.identifier == "en" }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(localization.text("common_phrases.title")).font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { controller.close(reason: "close_button") } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(localization.text("common_phrases.close"))
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); tile(.up); Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                GridRow { tile(.left); tile(.ok); tile(.right) }
                GridRow { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); tile(.down); Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
            }
            Text(localization.text(controller.messageKey)).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(width: 480, height: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
    private func tile(_ button: RemoteButton) -> some View {
        Button { controller.insert(button) } label: {
            VStack(spacing: 5) {
                Text(button == .ok ? "OK" : localization.text("common_phrases.key.\(button.rawValue)"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(controller.store.phrase(for: button)?.label(english: english) ?? localization.text("common_phrases.unassigned"))
                    .font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.center)
            }.frame(width: 130, height: 62).contentShape(Rectangle())
        }.buttonStyle(.bordered)
    }
}
