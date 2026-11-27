import AppKit
import CoreGraphics
import Foundation

enum PermissionDragHelperPane: String {
    case inputMonitoring = "input_monitoring"
    case accessibility

    var systemSettingsPane: String {
        switch self {
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .accessibility: return "Privacy_Accessibility"
        }
    }
}

enum PermissionDragHelperSource: String {
    case onboarding
    case settings
}

enum PermissionDragHelperPlacement: String {
    case belowList = "below_list"
    case sidecarRight = "sidecar_right"
    case sidecarLeft = "sidecar_left"
    case safeArea = "safe_area"
}

enum PermissionDragHelperGeometry {
    static let cardSize = CGSize(width: 318, height: 108)
    static let panelSize = CGSize(width: 330, height: 120)
    static let panelInset: CGFloat = 6
    static let listLeftOffset: CGFloat = 263
    static let listTopOffset: CGFloat = 105
    static let sidecarTopGap: CGFloat = 8
    static let cardTopOffset: CGFloat = 337
    static let sidecarGap: CGFloat = 16
    static let safeAreaMargin: CGFloat = 16
    static let visibleMargin: CGFloat = 8
}

struct PermissionDragHelperPlacementResult: Equatable {
    let cardOrigin: CGPoint
    let placement: PermissionDragHelperPlacement
}

enum PermissionDragHelperPlacementCalculator {
    /// `windowFrame` and `visibleFrame` are AppKit screen coordinates (bottom-left origin).
    ///
    /// The offsets are measured from the System Settings window frame. The card top is
    /// 18 pt below the permission list bottom, and its left edge follows the list.
    static func place(
        windowFrame: CGRect,
        visibleFrame: CGRect,
        pane: PermissionDragHelperPane
    ) -> PermissionDragHelperPlacementResult {
        let cardSize = PermissionDragHelperGeometry.cardSize
        let safe = visibleFrame.insetBy(
            dx: PermissionDragHelperGeometry.visibleMargin,
            dy: PermissionDragHelperGeometry.visibleMargin
        )
        func fits(_ origin: CGPoint) -> Bool {
            safe.contains(CGRect(origin: origin, size: cardSize))
        }

        let cardTop = windowFrame.maxY - PermissionDragHelperGeometry.cardTopOffset
        let cardY = cardTop - cardSize.height
        if pane == .inputMonitoring {
            let belowList = CGPoint(
                x: windowFrame.minX + PermissionDragHelperGeometry.listLeftOffset,
                y: cardY
            )
            if fits(belowList) {
                return PermissionDragHelperPlacementResult(
                    cardOrigin: belowList,
                    placement: .belowList
                )
            }
        }

        let sidecarTop = windowFrame.maxY
            - PermissionDragHelperGeometry.listTopOffset
            - PermissionDragHelperGeometry.sidecarTopGap
        let sidecarY = sidecarTop - cardSize.height
        let right = CGPoint(
            x: windowFrame.maxX + PermissionDragHelperGeometry.sidecarGap,
            y: sidecarY
        )
        if fits(right) {
            return PermissionDragHelperPlacementResult(cardOrigin: right, placement: .sidecarRight)
        }

        let left = CGPoint(
            x: windowFrame.minX - PermissionDragHelperGeometry.sidecarGap - cardSize.width,
            y: sidecarY
        )
        if fits(left) {
            return PermissionDragHelperPlacementResult(cardOrigin: left, placement: .sidecarLeft)
        }

        let safeOrigin = CGPoint(
            x: visibleFrame.maxX - PermissionDragHelperGeometry.safeAreaMargin - cardSize.width,
            y: visibleFrame.minY + PermissionDragHelperGeometry.safeAreaMargin
        )
        return PermissionDragHelperPlacementResult(cardOrigin: safeOrigin, placement: .safeArea)
    }

    static func panelOrigin(for cardOrigin: CGPoint) -> CGPoint {
        CGPoint(
            x: cardOrigin.x - PermissionDragHelperGeometry.panelInset,
            y: cardOrigin.y - PermissionDragHelperGeometry.panelInset
        )
    }
}

struct PermissionDragHelperTarget {
    let windowFrame: CGRect
    let visibleFrame: CGRect
}

struct PermissionDragHelperWindowSnapshot {
    let target: PermissionDragHelperTarget?
    let hasModalWindow: Bool
}

enum PermissionDragHelperWindowLocator {
    private static let ownerNames: Set<String> = ["System Settings", "系统设置"]

    /// A sheet such as the authorization prompt is a second System Settings window
    /// on the same level. The card must hide while it is visible so it never covers
    /// the system password prompt.
    static func snapshot() -> PermissionDragHelperWindowSnapshot {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return PermissionDragHelperWindowSnapshot(target: nil, hasModalWindow: false)
        }

        let candidates: [CGRect] = windows.compactMap { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            guard ownerNames.contains(owner) else { return nil }
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else {
                return nil
            }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 100,
                  height >= 100
            else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        guard let cgFrame = candidates.max(by: {
            $0.width * $0.height < $1.width * $1.height
        }), cgFrame.width >= 600, cgFrame.height >= 600 else {
            return PermissionDragHelperWindowSnapshot(
                target: nil,
                hasModalWindow: candidates.count > 1
            )
        }

        // CGWindowList uses the primary display's top-left origin. AppKit uses the
        // primary display's bottom-left origin.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let windowFrame = CGRect(
            x: cgFrame.minX,
            y: primaryHeight - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
        let screen = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(windowFrame).area
                < rhs.frame.intersection(windowFrame).area
        } ?? NSScreen.main
        guard let screen else {
            return PermissionDragHelperWindowSnapshot(
                target: nil,
                hasModalWindow: candidates.count > 1
            )
        }
        return PermissionDragHelperWindowSnapshot(
            target: PermissionDragHelperTarget(
                windowFrame: windowFrame,
                visibleFrame: screen.visibleFrame
            ),
            hasModalWindow: candidates.count > 1
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

struct PermissionDragHelperCopy {
    let product: String
    let drag: String
    let hint: String
    let idle: String
    let checking: String
    let waiting: String
    let added: String
    let dragFailed: String
    let reopen: String
    let close: String
    let accessibilityLabel: String

    init(localization: LocalizationStore) {
        product = localization.text("permission.helper.product")
        drag = localization.text("permission.helper.drag")
        hint = localization.text("permission.helper.hint")
        idle = localization.text("permission.helper.idle")
        checking = localization.text("permission.helper.checking")
        waiting = localization.text("permission.helper.waiting")
        added = localization.text("permission.helper.added")
        dragFailed = localization.text("permission.helper.drag_failed")
        reopen = localization.text("permission.helper.reopen")
        close = localization.text("common.action.close")
        accessibilityLabel = localization.text("permission.helper.accessibility_label")
    }
}

/// Owns the small utility panel that places the real app bundle next to the System
/// Settings permission list. The panel is non-activating so it never takes focus away
/// from the checkbox the user is about to click.
final class PermissionDragHelperController {
    static let shared = PermissionDragHelperController()

    private var panel: NSPanel?
    private var cardView: PermissionDragCardView?
    private var pane: PermissionDragHelperPane?
    private var source: PermissionDragHelperSource = .settings
    private var generation = UUID()
    private var requestedAt: Date?
    private var windowFound = false
    private var shown = false
    private var fallback = false
    private var missingWindowPolls = 0
    private var hiddenForSystemModal = false
    private var permissionGrantedHandled = false
    private var permissionQueryInFlight = false
    private var windowPollTimer: Timer?
    private var permissionPollTimer: Timer?
    private var localKeyMonitor: Any?
    private var closeWorkItem: DispatchWorkItem?
    private var waitingWorkItem: DispatchWorkItem?

    private init() {}

    func present(
        pane: PermissionDragHelperPane,
        source: PermissionDragHelperSource,
        settings: AppSettings
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.present(pane: pane, source: source, settings: settings)
            }
            return
        }

        // The rows stay clickable after the permission is granted. Reopening System
        // Settings is still useful, but a drag card would be misleading.
        if pane == .inputMonitoring, HIDRemoteMonitor.isInputMonitoringGranted {
            log("action=skipped result=already_granted pane=\(pane.rawValue) source=\(source.rawValue)")
            return
        }
        if pane == .accessibility, KeyboardInjector.isAccessibilityTrusted {
            log("action=skipped result=already_granted pane=\(pane.rawValue) source=\(source.rawValue)")
            return
        }

        if panel != nil {
            close(reason: "replaced")
        }

        let localization = LocalizationStore(settings: settings)
        let copy = PermissionDragHelperCopy(localization: localization)
        let bundleURL = Bundle.main.bundleURL
        let newGeneration = UUID()
        generation = newGeneration
        self.pane = pane
        self.source = source
        requestedAt = Date()
        windowFound = false
        shown = false
        fallback = false
        hiddenForSystemModal = false
        missingWindowPolls = 0
        permissionGrantedHandled = false
        permissionQueryInFlight = false

        let card = PermissionDragCardView(
            bundleURL: bundleURL,
            copy: copy,
            onClose: { [weak self] in
                guard let self, self.generation == newGeneration else { return }
                self.close(reason: "close_button")
            },
            onDragStarted: { [weak self] in
                guard let self, self.generation == newGeneration else { return }
                self.cardView?.setState(.idle)
                self.log("action=drag_started pane=\(pane.rawValue) source=\(source.rawValue)")
            },
            onDragEnded: { [weak self] accepted in
                guard let self, self.generation == newGeneration else { return }
                self.handleDragEnded(accepted: accepted)
            },
            onReopen: { [weak self] in
                guard let self, self.generation == newGeneration else { return }
                self.reopenSettings()
            }
        )
        let panel = makePanel(cardView: card)
        self.panel = panel
        cardView = card

        log("action=requested pane=\(pane.rawValue) source=\(source.rawValue)")
        addKeyMonitor()
        startTimers()
        pollWindow()
    }

    private func makePanel(cardView: PermissionDragCardView) -> NSPanel {
        let size = PermissionDragHelperGeometry.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        cardView.frame = NSRect(
            x: PermissionDragHelperGeometry.panelInset,
            y: PermissionDragHelperGeometry.panelInset,
            width: PermissionDragHelperGeometry.cardSize.width,
            height: PermissionDragHelperGeometry.cardSize.height
        )
        cardView.autoresizingMask = []
        container.addSubview(cardView)
        panel.contentView = container
        return panel
    }

    private func startTimers() {
        let windowTimer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pollWindow()
        }
        RunLoop.main.add(windowTimer, forMode: .common)
        windowPollTimer = windowTimer

        let permissionTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPermission()
        }
        RunLoop.main.add(permissionTimer, forMode: .common)
        permissionPollTimer = permissionTimer
        pollPermission()
    }

    private func pollWindow() {
        guard panel != nil, let pane else { return }
        let snapshot = PermissionDragHelperWindowLocator.snapshot()
        if snapshot.hasModalWindow {
            hideForSystemModal()
            return
        }
        if let target = snapshot.target {
            missingWindowPolls = 0
            windowFound = true
            let placement = PermissionDragHelperPlacementCalculator.place(
                windowFrame: target.windowFrame,
                visibleFrame: target.visibleFrame,
                pane: pane
            )
            show(
                cardOrigin: placement.cardOrigin,
                placement: placement.placement
            )
            return
        }

        if windowFound, shown {
            missingWindowPolls += 1
            if missingWindowPolls >= 3 {
                close(reason: "settings_window_closed")
            }
            return
        }

        guard !shown, let requestedAt,
              Date().timeIntervalSince(requestedAt) >= 2.5,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.contains(NSEvent.mouseLocation)
              }) ?? NSScreen.main
        else {
            return
        }
        let visibleFrame = screen.visibleFrame
        let safeOrigin = CGPoint(
            x: visibleFrame.maxX - PermissionDragHelperGeometry.safeAreaMargin
                - PermissionDragHelperGeometry.cardSize.width,
            y: visibleFrame.minY + PermissionDragHelperGeometry.safeAreaMargin
        )
        show(cardOrigin: safeOrigin, placement: .safeArea)
    }

    private func hideForSystemModal() {
        guard shown, !hiddenForSystemModal, let pane else { return }
        hiddenForSystemModal = true
        panel?.orderOut(nil)
        log(
            "action=hidden reason=system_modal pane=\(pane.rawValue) "
                + "source=\(source.rawValue)"
        )
    }

    private func show(cardOrigin: CGPoint, placement: PermissionDragHelperPlacement) {
        guard let panel, let pane else { return }
        let panelOrigin = PermissionDragHelperPlacementCalculator.panelOrigin(for: cardOrigin)
        let wasFallback = fallback
        fallback = placement == .safeArea
        panel.setFrameOrigin(panelOrigin)

        if !shown {
            shown = true
            if fallback {
                cardView?.setState(.fallback)
            }
            panel.orderFrontRegardless()
            log(
                "action=shown pane=\(pane.rawValue) source=\(source.rawValue) "
                    + "placement=\(placement.rawValue)"
            )
        } else if hiddenForSystemModal {
            hiddenForSystemModal = false
            panel.orderFrontRegardless()
            if wasFallback, !fallback, cardView?.phase == .fallback {
                cardView?.setState(.idle)
            }
            log(
                "action=shown reason=system_modal_cleared pane=\(pane.rawValue) "
                    + "source=\(source.rawValue)"
            )
        } else if wasFallback, !fallback {
            if cardView?.phase == .fallback {
                cardView?.setState(.idle)
            }
            log(
                "action=repositioned pane=\(pane.rawValue) source=\(source.rawValue) "
                    + "placement=\(placement.rawValue)"
            )
        }
    }

    private func pollPermission() {
        guard panel != nil, let pane, !permissionQueryInFlight, !permissionGrantedHandled else {
            return
        }
        permissionQueryInFlight = true
        let queryGeneration = generation
        RuntimePermissionReader.shared.query(
            needsAccessibility: pane == .accessibility
        ) { [weak self] snapshot in
            guard let self, self.generation == queryGeneration else { return }
            self.permissionQueryInFlight = false
            let granted = pane == .inputMonitoring
                ? snapshot.inputMonitoringGranted
                : snapshot.accessibilityTrusted
            if granted {
                self.handleGranted()
            }
        }
    }

    private func handleGranted() {
        guard !permissionGrantedHandled, let pane else { return }
        permissionGrantedHandled = true
        let grantGeneration = generation
        let paneToken = pane.rawValue
        log("action=permission_granted pane=\(paneToken) source=\(source.rawValue)")
        cardView?.setState(.added)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == grantGeneration else { return }
            self.close(reason: "granted")
        }
        closeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func handleDragEnded(accepted: Bool) {
        guard let pane else { return }
        if accepted {
            log("action=drag_ended result=accepted pane=\(pane.rawValue) source=\(source.rawValue)")
            cardView?.setState(.checking)
            waitingWorkItem?.cancel()
            let waitGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == waitGeneration else { return }
                guard !self.permissionGrantedHandled else { return }
                self.cardView?.setState(.waiting)
            }
            waitingWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        } else {
            log(
                "action=drag_failed reason=drop_cancelled pane=\(pane.rawValue) "
                    + "source=\(source.rawValue)"
            )
            cardView?.setState(.dragFailed)
        }
    }

    private func reopenSettings() {
        guard let pane,
              let url = URL(
                  string: "x-apple.systempreferences:com.apple.preference.security?"
                      + pane.systemSettingsPane
              )
        else {
            return
        }
        log("action=reopen_requested pane=\(pane.rawValue) source=\(source.rawValue)")
        NSWorkspace.shared.open(url)
        missingWindowPolls = 0
    }

    private func addKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close(reason: "escape")
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        localKeyMonitor = nil
    }

    private func close(reason: String) {
        guard panel != nil else { return }
        let paneToken = pane?.rawValue ?? "unknown"
        let sourceToken = source.rawValue
        generation = UUID()
        requestedAt = nil
        windowPollTimer?.invalidate()
        permissionPollTimer?.invalidate()
        windowPollTimer = nil
        permissionPollTimer = nil
        closeWorkItem?.cancel()
        waitingWorkItem?.cancel()
        closeWorkItem = nil
        waitingWorkItem = nil
        removeKeyMonitor()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        cardView = nil
        pane = nil
        windowFound = false
        shown = false
        fallback = false
        missingWindowPolls = 0
        permissionGrantedHandled = false
        permissionQueryInFlight = false
        log("action=closed reason=\(reason) pane=\(paneToken) source=\(sourceToken)")
    }

    private func log(_ message: String) {
        AppLogger.shared.write("PERMISSION_HELPER \(message)")
    }
}
