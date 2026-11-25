import AppKit
import SwiftUI

/// A transient, non-activating glass strip. SayAll does not have to be the
/// frontmost app: the panel orders front without activating and never becomes key.
@MainActor
final class FunctionPanelController: ObservableObject {
    @Published private(set) var items: [FunctionPanelItem] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var emptyText = ""
    @Published private(set) var panelTitle = ""
    @Published private(set) var isPresented = false

    private var window: FunctionPanelWindow?
    private var openButton: RemoteButton?
    private var execute: ((FunctionPanelItem) -> Bool)?
    private var showUnavailable: ((String) -> Void)?
    private var repeatTask: Task<Void, Never>?
    private var autoCloseTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var operationID = UUID()
    private var openedAt = Date()

    private static let itemWidth: CGFloat = 96
    private static let itemSpacing: CGFloat = 18
    private static let horizontalPadding: CGFloat = 48
    private static let panelHeight: CGFloat = 172
    private static let emptyWidth: CGFloat = 420
    private static let emptyHeight: CGFloat = 120
    /// 生产默认 10 秒；本地视觉预览可调长，避免还没看清就关闭。
    var autoCloseNanoseconds: UInt64 = 10_000_000_000

    var panelWidth: CGFloat {
        Self.panelWidth(forItemCount: items.count)
    }

    var panelHeight: CGFloat {
        Self.panelHeight(forItemCount: items.count)
    }

    static func panelWidth(forItemCount count: Int) -> CGFloat {
        guard count > 0 else { return emptyWidth }
        let slots = min(max(count, 5), 9)
        return CGFloat(slots) * itemWidth +
            CGFloat(slots - 1) * itemSpacing +
            horizontalPadding
    }

    static func panelHeight(forItemCount count: Int) -> CGFloat {
        count == 0 ? emptyHeight : panelHeight
    }

    static func wrappedIndex(_ index: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    func present(
        items: [FunctionPanelItem],
        emptyText: String,
        panelTitle: String,
        openButton: RemoteButton?,
        execute: @escaping (FunctionPanelItem) -> Bool,
        showUnavailable: @escaping (String) -> Void
    ) {
        if isPresented {
            close(reason: "replaced")
        }
        self.items = items
        self.emptyText = emptyText
        self.panelTitle = panelTitle
        self.openButton = openButton
        self.execute = execute
        self.showUnavailable = showUnavailable
        selectedIndex = 0
        operationID = UUID()
        openedAt = Date()
        isPresented = true
        makeWindowIfNeeded()
        updateWindowGeometry()
        installWorkspaceObservers()
        scheduleAutoClose()

        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        if let window {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                window.animator().alphaValue = 1
            }
        }
        let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier
        AppLogger.shared.write(
            "FUNCTION PANEL phase=opened operation_id=\(operationID.uuidString) " +
                "items=\(items.count) frontmost_unchanged=\(frontmostBefore == frontmostAfter)"
        )
    }

    func close(reason: String) {
        guard isPresented else { return }
        let selectedID = items.indices.contains(selectedIndex)
            ? items[selectedIndex].id
            : "none"
        let duration = Int(Date().timeIntervalSince(openedAt) * 1000)
        repeatTask?.cancel()
        repeatTask = nil
        autoCloseTask?.cancel()
        autoCloseTask = nil
        removeWorkspaceObservers()
        window?.orderOut(nil)
        isPresented = false
        items = []
        selectedIndex = 0
        panelTitle = ""
        execute = nil
        showUnavailable = nil
        AppLogger.shared.write(
            "FUNCTION PANEL phase=closed operation_id=\(operationID.uuidString) " +
                "result=\(reason) selected=\(selectedID) duration_ms=\(duration)"
        )
    }

    /// Raw HID press/release edges are claimed before gesture recognition.
    func handle(button: RemoteButton, phase: RemoteButtonPhase, source _: String) -> Bool {
        guard isPresented else { return false }
        switch phase {
        case .release:
            if button == .left || button == .right {
                stopRepeat()
            }
            return true
        case .press:
            resetAutoClose()
            switch button {
            case .ok:
                executeSelected()
            case .back, .menu:
                close(reason: "back")
            case .left:
                move(by: -1)
                startRepeat(direction: -1)
            case .right:
                move(by: 1)
                startRepeat(direction: 1)
            case .up, .down:
                break
            default:
                if button == openButton {
                    close(reason: "toggle")
                }
            }
            return true
        }
    }

    /// Sources that already resolve a gesture still get one panel action and no
    /// pass-through. Hold repeat is implemented only on the raw HID path.
    func handle(button: RemoteButton, trigger: ButtonTrigger, source _: String) -> Bool {
        guard isPresented else { return false }
        resetAutoClose()
        switch button {
        case .ok:
            executeSelected()
        case .back, .menu:
            close(reason: "back")
        case .left:
            move(by: -1)
        case .right:
            move(by: 1)
        case .up, .down:
            break
        default:
            if button == openButton {
                close(reason: "toggle")
            }
        }
        return true
    }

    func click(index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        resetAutoClose()
        executeSelected()
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = Self.wrappedIndex(selectedIndex, delta: delta, count: items.count)
        resetAutoClose()
    }

    private func executeSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        if item.unavailableReasonKey != nil {
            showUnavailable?(item.unavailableReasonText ?? "")
            resetAutoClose()
            AppLogger.shared.write(
                "FUNCTION PANEL phase=rejected operation_id=\(operationID.uuidString) " +
                    "item=\(item.id) reason=unavailable"
            )
            return
        }
        let executor = execute
        close(reason: "executed")
        let handled = executor?(item) ?? false
        AppLogger.shared.write(
            "FUNCTION PANEL phase=execute operation_id=\(operationID.uuidString) " +
                "item=\(item.id) result=\(handled ? "success" : "failure")"
        )
    }

    private func startRepeat(direction: Int) {
        stopRepeat()
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            while !Task.isCancelled {
                self.move(by: direction)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.autoCloseNanoseconds ?? 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.close(reason: "timeout")
        }
    }

    private func resetAutoClose() {
        guard isPresented else { return }
        scheduleAutoClose()
    }

    private func installWorkspaceObservers() {
        removeWorkspaceObservers()
        let center = NSWorkspace.shared.notificationCenter
        let closeOnActivation: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.close(reason: "frontmost_changed") }
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
            using: closeOnActivation
        ))
        let closeOnSleep: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.close(reason: "system_sleep") }
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main,
            using: closeOnSleep
        ))
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main,
            using: closeOnSleep
        ))
        let closeOnLock: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.close(reason: "screen_locked") }
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main,
            using: closeOnLock
        ))
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let panel = FunctionPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.appearance = nil
        let hosting = NSHostingView(rootView: FunctionPanelView(controller: self))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        window = panel
    }

    private func updateWindowGeometry() {
        guard let window else { return }
        let size = NSSize(width: panelWidth, height: panelHeight)
        window.setContentSize(size)
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }
}

final class FunctionPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
