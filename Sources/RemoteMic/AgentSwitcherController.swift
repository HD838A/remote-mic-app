import AppKit
import Foundation
import SwiftUI

struct AgentSwitcherApplication: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
}

struct AgentSwitcherState: Equatable {
    enum Phase: Equatable {
        case choosing
        case opening(String)
        case failed(String)
        case empty
    }

    let applications: [AgentSwitcherApplication]
    let selectedIndex: Int
    let phase: Phase

    var selectedApplication: AgentSwitcherApplication? {
        guard applications.indices.contains(selectedIndex) else { return nil }
        return applications[selectedIndex]
    }
}

protocol AgentSwitcherRendering: AnyObject {
    func show(state: AgentSwitcherState, actions: AgentSwitcherActions)
    func update(state: AgentSwitcherState)
    func dismiss()
}

struct AgentSwitcherActions {
    let select: (Int) -> Void
    let confirm: () -> Void
    let cancel: () -> Void
    let handleKeyCode: (UInt16) -> Bool
}

final class AgentSwitcherController {
    typealias Opener = (AgentSwitcherApplication, @escaping (Error?) -> Void) -> Void
    typealias Localize = (String) -> String

    private struct Session {
        let token: UInt64
        let owner: String
        let startedAt: Date
        var state: AgentSwitcherState
    }

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
    }

    static let timeoutMilliseconds: UInt64 = 30_000
    static let frontmostPollMilliseconds: UInt64 = 250

    private let opener: Opener
    private let frontmostBundleIdentifier: () -> String?
    private let scheduler: HIDRemoteScheduling
    private let logger: (String) -> Void
    private let renderer: AgentSwitcherRendering
    private var session: Session?
    private var nextToken: UInt64 = 0
    private var nextOpenToken: UInt64 = 0
    private var timeoutTask: HIDRemoteScheduledTask?
    private var frontmostTask: HIDRemoteScheduledTask?

    var isActive: Bool { session != nil }
    var owner: String? { session?.owner }

    init(
        localize: @escaping Localize = { $0 },
        opener: @escaping Opener = AgentSwitcherController.openApplication,
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        logger: @escaping (String) -> Void = AppLogger.shared.write,
        renderer: AgentSwitcherRendering? = nil
    ) {
        self.opener = opener
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.scheduler = scheduler
        self.logger = logger
        self.renderer = renderer ?? AgentSwitcherPanelRenderer(localize: localize)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timeoutTask?.cancel()
        frontmostTask?.cancel()
    }

    func toggle(applications: [AgentSwitcherApplication], owner: String) {
        if session?.owner == owner {
            cancel(owner: owner, reason: "toggle")
            return
        }
        cancel(reason: "owner_changed")
        nextOpenToken &+= 1
        start(applications: applications, owner: owner)
    }

    @discardableResult
    func handle(button: RemoteButton, owner: String) -> Bool {
        guard let active = session, active.owner == owner else { return false }
        switch button {
        case .left:
            guard !active.state.phase.isOpening else { return true }
            moveSelection(delta: -1, token: active.token)
            return true
        case .right:
            guard !active.state.phase.isOpening else { return true }
            moveSelection(delta: 1, token: active.token)
            return true
        case .ok:
            guard !active.state.phase.isOpening else { return true }
            confirm(token: active.token)
            return true
        case .back, .menu:
            cancel(owner: owner, reason: button == .back ? "back" : "menu")
            return true
        default:
            cancel(owner: owner, reason: "unrelated_button_\(button.rawValue)")
            return false
        }
    }

    func cancel(owner: String? = nil, reason: String) {
        guard let active = session else { return }
        guard owner == nil || owner == active.owner else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        frontmostTask?.cancel()
        frontmostTask = nil
        session = nil
        renderer.dismiss()
        logger("AGENT SWITCHER phase=cancelled reason=\(reason) operation_id=\(active.token) elapsed_ms=\(elapsedMilliseconds(active))")
    }

    private func start(applications: [AgentSwitcherApplication], owner: String) {
        nextToken &+= 1
        let state = AgentSwitcherState(
            applications: applications,
            selectedIndex: 0,
            phase: applications.isEmpty ? .empty : .choosing
        )
        let token = nextToken
        session = Session(token: token, owner: owner, startedAt: Date(), state: state)
        let actions = AgentSwitcherActions(
            select: { [weak self] index in self?.select(index: index, token: token) },
            confirm: { [weak self] in self?.confirm(token: token) },
            cancel: { [weak self] in self?.cancel(owner: owner, reason: "pointer_cancel") },
            handleKeyCode: { [weak self] keyCode in self?.handle(keyCode: keyCode, owner: owner) ?? false }
        )
        renderer.show(state: state, actions: actions)
        scheduleTimeout(token: token)
        logger("AGENT SWITCHER phase=presented count=\(applications.count) operation_id=\(token) source=\(owner == "preview" ? "preview" : "remote") timeout_ms=\(Self.timeoutMilliseconds)")
    }

    private func select(index: Int, token: UInt64) {
        guard var active = session, active.token == token else { return }
        guard !active.state.phase.isOpening else { return }
        guard active.state.applications.indices.contains(index) else { return }
        active.state = AgentSwitcherState(
            applications: active.state.applications,
            selectedIndex: index,
            phase: .choosing
        )
        session = active
        renderer.update(state: active.state)
        scheduleTimeout(token: token)
    }

    private func moveSelection(delta: Int, token: UInt64) {
        guard var active = session, active.token == token else { return }
        let count = active.state.applications.count
        guard count > 0 else {
            scheduleTimeout(token: token)
            return
        }
        let nextIndex = (active.state.selectedIndex + delta + count) % count
        active.state = AgentSwitcherState(
            applications: active.state.applications,
            selectedIndex: nextIndex,
            phase: .choosing
        )
        session = active
        renderer.update(state: active.state)
        scheduleTimeout(token: token)
        logger("AGENT SWITCHER phase=navigate direction=\(delta < 0 ? "left" : "right") operation_id=\(token)")
    }

    private func confirm(token: UInt64) {
        guard var active = session, active.token == token,
              !active.state.phase.isOpening else { return }
        guard let application = active.state.selectedApplication else {
            scheduleTimeout(token: token)
            return
        }
        nextOpenToken &+= 1
        let openToken = nextOpenToken
        active.state = AgentSwitcherState(
            applications: active.state.applications,
            selectedIndex: active.state.selectedIndex,
            phase: .opening(application.id)
        )
        session = active
        renderer.update(state: active.state)
        scheduleTimeout(token: token)
        logger("AGENT SWITCHER phase=submitted selection=\(active.state.selectedIndex) operation_id=\(token) attempt_id=\(openToken)")
        opener(application) { [weak self] error in
            self?.handleOpenResult(
                error,
                application: application,
                token: token,
                openToken: openToken
            )
        }
    }

    private func handleOpenResult(
        _ error: Error?,
        application: AgentSwitcherApplication,
        token: UInt64,
        openToken: UInt64
    ) {
        guard var active = session,
              active.token == token,
              openToken == nextOpenToken
        else { return }
        if let error {
            active.state = AgentSwitcherState(
                applications: active.state.applications,
                selectedIndex: active.state.selectedIndex,
                phase: .failed(application.id)
            )
            session = active
            renderer.update(state: active.state)
            logger(
                "AGENT SWITCHER phase=attempt_failed retryable=true operation_id=\(token) attempt_id=\(openToken) " +
                    AppLogger.errorFields(error)
            )
            scheduleTimeout(token: token)
            return
        }
        scheduleFrontmostCheck(
            application: application,
            token: token,
            openToken: openToken
        )
    }

    private func scheduleFrontmostCheck(
        application: AgentSwitcherApplication,
        token: UInt64,
        openToken: UInt64
    ) {
        frontmostTask?.cancel()
        frontmostTask = scheduler.schedule(
            afterMilliseconds: Self.frontmostPollMilliseconds,
            repeatingEveryMilliseconds: Self.frontmostPollMilliseconds
        ) { [weak self] in
            guard let self,
                  self.session?.token == token,
                  self.nextOpenToken == openToken,
                  self.frontmostBundleIdentifier() == application.id
            else { return }
            self.complete(application: application, token: token)
        }
    }

    private func complete(application: AgentSwitcherApplication, token: UInt64) {
        guard let active = session, active.token == token else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        frontmostTask?.cancel()
        frontmostTask = nil
        session = nil
        renderer.dismiss()
        logger("AGENT SWITCHER phase=completed result=frontmost selection=\(active.state.selectedIndex) operation_id=\(token) elapsed_ms=\(elapsedMilliseconds(active))")
    }

    private func elapsedMilliseconds(_ session: Session) -> Int {
        max(0, Int(Date().timeIntervalSince(session.startedAt) * 1_000))
    }

    private func scheduleTimeout(token: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = scheduler.schedule(
            afterMilliseconds: Self.timeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.session?.token == token else { return }
            self.cancel(reason: "timeout")
        }
    }

    private func handle(keyCode: UInt16, owner: String) -> Bool {
        switch keyCode {
        case KeyCode.leftArrow:
            return handle(button: .left, owner: owner)
        case KeyCode.rightArrow:
            return handle(button: .right, owner: owner)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return handle(button: .ok, owner: owner)
        case KeyCode.escape:
            return handle(button: .back, owner: owner)
        default:
            return false
        }
    }

    @objc private func systemWillSleep() {
        cancel(reason: "sleep")
    }

    @objc private func applicationWillTerminate() {
        cancel(reason: "app_terminate")
    }

    private static func openApplication(
        _ application: AgentSwitcherApplication,
        completion: @escaping (Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: application.url, configuration: configuration) {
            _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}

private final class AgentSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension AgentSwitcherState.Phase {
    var isOpening: Bool {
        if case .opening = self { return true }
        return false
    }
}

private final class AgentSwitcherPanelRenderer: AgentSwitcherRendering {
    private let localize: AgentSwitcherController.Localize
    private var panel: AgentSwitcherPanel?
    private var hostingController: NSHostingController<AgentSwitcherPanelView>?
    private var actions: AgentSwitcherActions?
    private var localEventMonitor: Any?

    init(localize: @escaping AgentSwitcherController.Localize) {
        self.localize = localize
    }

    func show(state: AgentSwitcherState, actions: AgentSwitcherActions) {
        self.actions = actions
        let content = AgentSwitcherPanelView(
            state: state,
            localize: localize,
            actions: actions
        )
        if let panel, let hostingController {
            hostingController.rootView = content
            center(panel)
            installLocalEventMonitor()
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: content)
        let panel = AgentSwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 196),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        self.hostingController = hostingController
        installLocalEventMonitor()
        center(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func update(state: AgentSwitcherState) {
        guard let hostingController, let actions else { return }
        hostingController.rootView = AgentSwitcherPanelView(
            state: state,
            localize: localize,
            actions: actions
        )
    }

    func dismiss() {
        panel?.orderOut(nil)
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func center(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        ))
    }

    private func installLocalEventMonitor() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  self.shouldHandleLocalKeyEvent(event),
                  self.actions?.handleKeyCode(event.keyCode) == true
            else {
                return event
            }
            return nil
        }
    }

    private func shouldHandleLocalKeyEvent(_ event: NSEvent) -> Bool {
        guard !event.isARepeat,
              let panel,
              panel.isVisible,
              NSApp.keyWindow === panel || event.window === panel
        else { return false }
        return event.cgEvent?.getIntegerValueField(.eventSourceUserData) !=
            KeyboardInjector.syntheticEventMarker
    }
}

private struct AgentSwitcherPanelView: View {
    let state: AgentSwitcherState
    let localize: AgentSwitcherController.Localize
    let actions: AgentSwitcherActions

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            panelBackground
            VStack(spacing: 14) {
                switch state.phase {
                case .empty:
                    emptyView
                default:
                    applicationStrip
                    statusView
                }
            }
            .padding(18)
        }
        .frame(minWidth: 420, idealWidth: 560, maxWidth: 760, minHeight: 158)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .windowBackgroundColor))
        } else {
            VisualEffect(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private var applicationStrip: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: state.applications.count > 4) {
                    HStack(alignment: .center, spacing: 12) {
                        ForEach(Array(state.applications.enumerated()), id: \.element.id) { index, app in
                            applicationButton(app, selected: index == state.selectedIndex) {
                                actions.select(index)
                                actions.confirm()
                            }
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                    .frame(minWidth: geometry.size.width)
                }
                .onChange(of: state.selectedIndex) { index in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 112)
    }

    private func applicationButton(
        _ application: AgentSwitcherApplication,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .frame(width: selected ? 56 : 48, height: selected ? 56 : 48)
                    .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.86), value: selected)
                Text(application.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 86)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.accentColor.opacity(0.85) : Color.clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(application.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var statusView: some View {
        switch state.phase {
        case let .opening(identifier):
            Text(String(format: localize("agent_switcher.opening"), appName(identifier)))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case let .failed(identifier):
            Text(String(format: localize("agent_switcher.open_failed"), appName(identifier)))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        default:
            Text(localize("agent_switcher.controls"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(localize("agent_switcher.empty_title"))
                .font(.system(size: 14, weight: .semibold))
            Text(localize("agent_switcher.empty_detail"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
    }

    private func appName(_ identifier: String) -> String {
        state.applications.first(where: { $0.id == identifier })?.name ?? identifier
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
