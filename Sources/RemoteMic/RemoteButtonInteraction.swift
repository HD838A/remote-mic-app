import Foundation

/// This controller accepts ordinary remote buttons only. Voice session edges never enter it.
final class RemoteButtonInteractionController {
    private final class Interaction {
        let id = UUID()
        let snapshot: RemoteButtonInteractionSnapshot
        let valid: () -> Bool
        let perform: (ButtonTrigger, ConfiguredButtonAction) -> Bool
        var pressed = true
        var second = false
        var waiting = false
        var consumed = false
        var count = 0
        var timer: HIDRemoteScheduledTask?
        var longTimer: HIDRemoteScheduledTask?
        var guardTimer: HIDRemoteScheduledTask?
        init(snapshot: RemoteButtonInteractionSnapshot, valid: @escaping () -> Bool,
             perform: @escaping (ButtonTrigger, ConfiguredButtonAction) -> Bool) {
            self.snapshot = snapshot
            self.valid = valid
            self.perform = perform
        }
    }

    private let scheduler: HIDRemoteScheduling
    private var interactions: [RemoteButton: Interaction] = [:]

    init(scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler()) {
        self.scheduler = scheduler
    }

    func isTracking(_ button: RemoteButton) -> Bool { interactions[button] != nil }

    func handle(_ phase: RemoteButtonPhase, button: RemoteButton,
                snapshot: @autoclosure () -> RemoteButtonInteractionSnapshot,
                valid: @escaping () -> Bool,
                perform: @escaping (ButtonTrigger, ConfiguredButtonAction) -> Bool) {
        if phase == .release { release(button); return }
        if let current = interactions[button] {
            guard current.waiting else { return }
            current.timer?.cancel()
            current.pressed = true
            current.second = true
            current.waiting = false
            scheduleLong(button, current)
            return
        }
        let current = Interaction(snapshot: snapshot(), valid: valid, perform: perform)
        interactions[button] = current
        guard current.snapshot.unavailableReason == nil, valid() else {
            current.consumed = true
            AppLogger.shared.write("BUTTON HOLD operation_id=\(current.id.uuidString) phase=blocked result=unsupported button=\(button.rawValue)")
            return
        }
        current.guardTimer = scheduler.schedule(afterMilliseconds: 100, repeatingEveryMilliseconds: 100) { [weak self, weak current] in
            guard let self, let current, !current.valid() else { return }
            self.cancel(button, reason: "context_changed")
        }
        let mode = current.snapshot.mode!
        if mode == .repeatSingle {
            if !current.snapshot.recognizesDouble {
                fire(button, current, .singleClick)
                scheduleRepeat(button, current, .singleClick, delay: 350)
            } else {
                current.timer = schedule(button, current, after: UInt64(current.snapshot.settings.doubleClickMilliseconds)) { owner, value in
                    guard value.pressed, !value.second else { return }
                    owner.fire(button, value, .singleClick)
                    owner.scheduleRepeat(button, value, .singleClick, delay: value.snapshot.repeatInterval)
                }
            }
        } else if !current.snapshot.recognizesDouble && !current.snapshot.recognizesLong {
            fire(button, current, .singleClick)
        } else {
            scheduleLong(button, current)
        }
    }

    private func release(_ button: RemoteButton) {
        guard let current = interactions[button], current.pressed else { return }
        current.pressed = false
        current.timer?.cancel()
        current.longTimer?.cancel()
        if current.consumed { cancel(button, reason: "released"); return }
        if current.second {
            fire(button, current, .doubleClick)
            cancel(button, reason: "double_completed")
        } else if current.snapshot.recognizesDouble {
            current.waiting = true
            current.timer = schedule(button, current, after: UInt64(current.snapshot.settings.doubleClickMilliseconds)) { owner, value in
                owner.fire(button, value, .singleClick)
                owner.cancel(button, reason: "single_completed")
            }
        } else {
            fire(button, current, .singleClick)
            cancel(button, reason: "single_completed")
        }
    }

    private func scheduleLong(_ button: RemoteButton, _ current: Interaction) {
        guard current.snapshot.recognizesLong,
              !(current.second && current.snapshot.mode == .repeatSingle) else { return }
        current.longTimer = schedule(button, current, after: UInt64(current.snapshot.settings.longPressMilliseconds)) { owner, value in
            guard value.pressed else { return }
            owner.fire(button, value, .longPress)
            if value.snapshot.mode == .repeatLong {
                owner.scheduleRepeat(button, value, .longPress, delay: value.snapshot.repeatInterval)
            }
        }
    }

    private func scheduleRepeat(_ button: RemoteButton, _ current: Interaction,
                                _ trigger: ButtonTrigger, delay: UInt64) {
        guard interactions[button] === current, current.snapshot.repeatAllowed else { return }
        current.timer = schedule(button, current, after: delay) { owner, value in
            guard value.pressed else { return }
            owner.fire(button, value, trigger)
            owner.scheduleRepeat(button, value, trigger, delay: value.snapshot.repeatInterval)
        }
    }

    private func fire(_ button: RemoteButton, _ current: Interaction, _ trigger: ButtonTrigger) {
        guard interactions[button] === current, current.valid() else {
            cancel(button, reason: "context_changed"); return
        }
        let action = trigger == .singleClick ? current.snapshot.single :
            (trigger == .doubleClick ? current.snapshot.double : current.snapshot.long)
        current.consumed = true
        current.count += 1
        if !current.perform(trigger, action) { cancel(button, reason: "action_failed") }
    }

    private func schedule(_ button: RemoteButton, _ current: Interaction, after delay: UInt64,
                          action: @escaping (RemoteButtonInteractionController, Interaction) -> Void) -> HIDRemoteScheduledTask {
        scheduler.schedule(afterMilliseconds: delay, repeatingEveryMilliseconds: nil) { [weak self, weak current] in
            guard let self, let current, self.interactions[button] === current else { return }
            action(self, current)
        }
    }

    func cancel(_ button: RemoteButton, reason: String) {
        guard let current = interactions.removeValue(forKey: button) else { return }
        current.timer?.cancel()
        current.longTimer?.cancel()
        current.guardTimer?.cancel()
        AppLogger.shared.write("BUTTON HOLD operation_id=\(current.id.uuidString) phase=completed reason=\(reason) count=\(current.count) external_result=unknown")
    }

    func cancelAll(reason: String) {
        for button in Array(interactions.keys) { cancel(button, reason: reason) }
    }

    deinit { cancelAll(reason: "disposed") }
}
