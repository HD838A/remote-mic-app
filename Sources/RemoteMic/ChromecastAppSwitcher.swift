import Foundation

/// Owns the switcher while a Chromecast remote navigates it. The normal
/// button recognizer never sees the press or release of a session command.
final class ChromecastAppSwitcher {
    private let session: KeyboardInjector.AppSwitcherSession
    private let scheduler: HIDRemoteScheduling
    private let logger: (String) -> Void
    private let observeMouseDismiss: (@escaping () -> Void) -> (() -> Void)?
    private var operationID: UUID?
    private var consumedPresses = Set<RemoteButton>()
    private var timeout: HIDRemoteScheduledTask?
    private var removeMouseObserver: (() -> Void)?
    private var repeatTask: HIDRemoteScheduledTask?
    private var repeatingButton: RemoteButton?

    init(
        session: KeyboardInjector.AppSwitcherSession = .init(),
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        logger: @escaping (String) -> Void = AppLogger.shared.write,
        observeMouseDismiss: @escaping (@escaping () -> Void) -> (() -> Void)? = HIDRemoteMonitor.installMouseClickDismissObserver
    ) {
        self.session = session
        self.scheduler = scheduler
        self.logger = logger
        self.observeMouseDismiss = observeMouseDismiss
    }

    func start(button: RemoteButton) -> Bool {
        _ = session.forceReleaseModifiersIfNeeded()
        operationID = UUID()
        // Use the reliable tab cycle on systems where Dock may ignore arrows.
        if #available(macOS 14, *) { session.markArrowNavigation(supported: false) }
        let submitted = session.trigger()
        log("start", result: submitted ? "submitted" : "failed", detail: "button=\(button.rawValue)")
        if submitted {
            removeMouseObserver = observeMouseDismiss { [weak self] in
                self?.cancel(reason: "mouse_click", dismissSwitcher: false)
            }
            scheduleTimeout()
        } else {
            finish(reason: "start_failed")
        }
        return submitted
    }

    func handle(_ phase: RemoteButtonPhase, button: RemoteButton, isSwitcherBinding: @autoclosure () -> Bool) -> Bool {
        if phase == .release {
            if repeatingButton == button { stopRepeat() }
            return consumedPresses.remove(button) != nil || session.isActive
        }
        guard session.isActive else {
            consumedPresses.remove(button)
            return false
        }
        consumedPresses.insert(button)
        stopRepeat()
        switch button {
        case .ok:
            if session.isWindowPickerActive, !session.pickerHasHighlight {
                log("confirm", result: "ignored", detail: "reason=no_highlight")
                scheduleTimeout()
            } else {
                let submitted = session.confirm()
                finish(reason: submitted ? "confirmation_submitted" : "confirm_failed", confirmed: submitted)
            }
        case .back:
            finish(reason: "back")
        case .left, .right, .up, .down:
            guard navigate(button) else { return true }
            repeatingButton = button
            repeatTask = scheduler.schedule(
                afterMilliseconds: HIDRemoteTiming.repeatStartMilliseconds,
                repeatingEveryMilliseconds: HIDRemoteTiming.repeatIntervalMilliseconds(for: button)
            ) { [weak self] in
                _ = self?.navigate(button)
            }
        default:
            if isSwitcherBinding() {
                let submitted = session.trigger()
                log("tab", result: submitted ? "submitted" : "failed", detail: "button=\(button.rawValue)")
                if submitted { scheduleTimeout() }
                else { finish(reason: "tab_failed") }
            } else {
                finish(reason: "unrelated_button_\(button.rawValue)")
            }
        }
        return true
    }

    func cancel(reason: String, dismissSwitcher: Bool = true) {
        if operationID != nil { finish(reason: reason, dismissSwitcher: dismissSwitcher) }
        _ = session.forceReleaseModifiersIfNeeded()
    }

    private func navigate(_ button: RemoteButton) -> Bool {
        let submitted = button == .up || button == .down
            ? session.moveWindowSelection(up: button == .up)
            : session.moveSelection(left: button == .left)
        log("navigate", result: submitted ? "submitted" : "failed", detail: "button=\(button.rawValue)")
        if submitted { scheduleTimeout() }
        else { finish(reason: "navigation_failed") }
        return submitted
    }

    private func scheduleTimeout() {
        timeout?.cancel()
        timeout = scheduler.schedule(afterMilliseconds: HIDRemoteTiming.appSwitcherTimeoutMilliseconds,
                                     repeatingEveryMilliseconds: nil) { [weak self] in
            self?.finish(reason: "timeout")
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatingButton = nil
    }

    private func finish(reason: String, confirmed: Bool = false, dismissSwitcher: Bool = true) {
        removeMouseObserver?()
        removeMouseObserver = nil
        timeout?.cancel()
        timeout = nil
        stopRepeat()
        let released = confirmed || session.cancel(dismissSwitcher: dismissSwitcher)
        let result = !released || reason.hasSuffix("_failed") ? "failed" : confirmed ? "submitted" : "cancelled"
        log("terminal", result: result, detail: "reason=\(reason)")
        operationID = nil
    }

    private func log(_ phase: String, result: String, detail: String) {
        guard let operationID else { return }
        logger("CHROMECAST APP SWITCHER operation_id=\(operationID) phase=\(phase) result=\(result) " +
               "\(detail) user_visible_result=unknown")
    }
}
