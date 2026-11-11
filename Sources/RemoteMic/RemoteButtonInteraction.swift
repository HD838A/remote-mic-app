import Foundation

/// This controller accepts ordinary remote buttons only. Voice session edges never enter it.
final class RemoteButtonInteractionController {
    private final class Interaction {
        let id = UUID()
        let snapshot: RemoteButtonInteractionSnapshot
        let valid: () -> Bool
        let perform: (ButtonTrigger, ConfiguredButtonAction) -> Bool
        let beginHold: ((ConfiguredButtonAction) -> Bool)?
        let endHold: ((String) -> Void)?
        var pressed = true
        var second = false
        var waiting = false
        var consumed = false
        var holding = false
        var count = 0
        var timer: HIDRemoteScheduledTask?
        var longTimer: HIDRemoteScheduledTask?
        var guardTimer: HIDRemoteScheduledTask?
        init(snapshot: RemoteButtonInteractionSnapshot, valid: @escaping () -> Bool,
             perform: @escaping (ButtonTrigger, ConfiguredButtonAction) -> Bool,
             beginHold: ((ConfiguredButtonAction) -> Bool)? = nil,
             endHold: ((String) -> Void)? = nil) {
            self.snapshot = snapshot
            self.valid = valid
            self.perform = perform
            self.beginHold = beginHold
            self.endHold = endHold
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
                perform: @escaping (ButtonTrigger, ConfiguredButtonAction) -> Bool,
                beginHold: ((ConfiguredButtonAction) -> Bool)? = nil,
                endHold: ((String) -> Void)? = nil) {
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
        let current = Interaction(snapshot: snapshot(), valid: valid, perform: perform,
                                  beginHold: beginHold, endHold: endHold)
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
        // 「按住执行」与上面的重复方式无关：按住即把长按动作里的方向键按下去，松手才抬起。
        // 配了双击时先等双击窗口；单击另有动作时等长按阈值，保证短按仍执行单击。
        if current.snapshot.isHoldExecutionActive {
            let delay = holdStartDelay(for: current.snapshot)
            if delay == 0 {
                startHold(button, current)
            } else {
                AppLogger.shared.write(
                    "BUTTON HOLD operation_id=\(current.id.uuidString) phase=hold_waiting " +
                        "start_ms=\(delay) double_ms=\(current.snapshot.settings.doubleClickMilliseconds)"
                )
                current.timer = schedule(button, current, after: delay) { owner, value in
                    guard value.pressed, !value.second else { return }
                    owner.startHold(button, value)
                }
            }
            return
        }
        if mode == .repeatSingle {
            let learnedStart = UInt64(current.snapshot.repeatSingleStartMilliseconds ?? 0)
            if !current.snapshot.recognizesDouble {
                fire(button, current, .singleClick)
                scheduleRepeat(button, current, .singleClick,
                               delay: max(HIDRemoteTiming.repeatStartMilliseconds, learnedStart))
            } else {
                let delay = max(UInt64(current.snapshot.settings.doubleClickMilliseconds), learnedStart)
                AppLogger.shared.write(
                    "BUTTON HOLD operation_id=\(current.id.uuidString) phase=waiting " +
                        "repeat_start_ms=\(delay) double_ms=\(current.snapshot.settings.doubleClickMilliseconds)"
                )
                current.timer = schedule(button, current, after: delay) { owner, value in
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
        // 按住执行已经接管了“按住”，长按动作不再作为一次性动作触发。
        guard !current.snapshot.isHoldExecutionActive else { return }
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
        // 按住执行把目标键真正按住，由系统负责自动重复；这里不再补发离散动作。
        guard interactions[button] === current, current.snapshot.repeatAllowed,
              !current.snapshot.isHoldExecutionActive else { return }
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

    /// 按住开始前的等待：双击窗口优先；单击另有动作时等长按阈值，短按照常执行单击动作。
    private func holdStartDelay(for snapshot: RemoteButtonInteractionSnapshot) -> UInt64 {
        if snapshot.recognizesDouble {
            return max(UInt64(snapshot.settings.doubleClickMilliseconds),
                       UInt64(snapshot.repeatSingleStartMilliseconds ?? 0))
        }
        guard let holdAction = snapshot.holdExecutionAction,
              snapshot.single.action != .disabled,
              snapshot.single != holdAction else { return 0 }
        return UInt64(snapshot.settings.longPressMilliseconds)
    }

    /// 进入按住：只发一次按下，由 `KeyboardHoldExecution` 负责系统级自动重复，松键时抬起。
    private func startHold(_ button: RemoteButton, _ current: Interaction) {
        guard interactions[button] === current, current.pressed, current.valid() else {
            cancel(button, reason: "context_changed")
            return
        }
        guard let action = current.snapshot.holdExecutionAction,
              let beginHold = current.beginHold else {
            cancel(button, reason: "hold_unavailable")
            return
        }
        current.consumed = true
        current.count += 1
        current.holding = true
        if !beginHold(action) {
            current.holding = false
            cancel(button, reason: "hold_failed")
        }
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
        if current.holding {
            current.holding = false
            // 无论因为松键、断连还是上下文变化结束，都必须把系统里的键抬起来。
            current.endHold?(reason)
        }
        AppLogger.shared.write("BUTTON HOLD operation_id=\(current.id.uuidString) phase=completed reason=\(reason) count=\(current.count) external_result=unknown")
    }

    func cancelAll(reason: String) {
        for button in Array(interactions.keys) { cancel(button, reason: reason) }
    }

    deinit { cancelAll(reason: "disposed") }
}
