import CoreGraphics
import Foundation

// 「哪些动作可以被按住」是动作类型自身的判定，定义在 `RemoteButtons.swift`，
// 与 `ConfiguredButtonAction` 放在一起：自测脚本单独编译该文件时同样可用。

/// 把一个方向键真正按在系统里，直到用户松开遥控器按键。
///
/// 物理键盘按住一个键时，系统先发一次 `keyDown`，随后按系统节奏补发带自动重复标记的
/// `keyDown`，松开时发一次 `keyUp`。目标 App 因此既能读到“键一直按着”的状态，
/// 也能收到重复事件（播放器快进、光标连续移动都依赖其中之一）。这里复刻同一序列。
final class KeyboardHoldExecution {
    struct Target: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags

        init(_ key: HoldableKey) {
            keyCode = key.keyCode
            flags = key.flags
        }
    }

    struct Session: Equatable {
        let id: UUID
        let target: Target
        let startedAt: Date
        var repeats: Int
    }

    typealias EventPoster = (_ keyCode: CGKeyCode, _ isDown: Bool, _ flags: CGEventFlags,
                             _ autorepeat: Bool) -> Bool

    static let shared = KeyboardHoldExecution()

    /// 首次自动重复前的等待时间。系统默认约 375 ms，这里取相邻的整值。
    static let initialRepeatDelayMilliseconds = 350
    /// 自动重复间隔。取 60 ms，接近系统默认节奏，又不会把目标 App 压满。
    static let repeatIntervalMilliseconds = 60
    /// 松开事件丢失时的兜底时长：到点强制抬起，绝不让按键一直卡在按下状态。
    static let maximumDurationMilliseconds = 60_000

    private let poster: EventPoster
    private let logger: (String) -> Void
    private let now: () -> Date
    private let initialRepeatDelay: Int
    private let repeatInterval: Int
    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "com.hd838a.RemoteMic.keyboard-hold")
    private var timer: DispatchSourceTimer?
    private var session: Session?

    init(
        poster: @escaping EventPoster = KeyboardHoldExecution.post,
        logger: @escaping (String) -> Void = { AppLogger.shared.write($0) },
        now: @escaping () -> Date = Date.init,
        initialRepeatDelayMilliseconds: Int = KeyboardHoldExecution.initialRepeatDelayMilliseconds,
        repeatIntervalMilliseconds: Int = KeyboardHoldExecution.repeatIntervalMilliseconds
    ) {
        self.poster = poster
        self.logger = logger
        self.now = now
        initialRepeatDelay = max(1, initialRepeatDelayMilliseconds)
        repeatInterval = max(1, repeatIntervalMilliseconds)
    }

    private static func post(
        keyCode: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags,
        autorepeat: Bool
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
        else { return false }
        event.flags = flags
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        event.setIntegerValueField(
            .eventSourceUserData,
            value: KeyboardInjector.syntheticEventMarker
        )
        event.post(tap: .cghidEventTap)
        return true
    }

    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil
    }

    /// 开始按住。已有会话会先被安全抬起，因此同一时刻系统里最多只有一个被按住的键。
    @discardableResult
    func begin(_ target: Target) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = session {
            releaseLocked(existing, reason: "replaced")
        }
        let id = UUID()
        let startedAt = now()
        guard poster(target.keyCode, true, target.flags, false) else {
            logger(
                "BUTTON HOLD operation_id=\(id.uuidString) phase=hold_failed " +
                    "reason=press_not_submitted key=\(target.keyCode)"
            )
            return false
        }
        session = Session(id: id, target: target, startedAt: startedAt, repeats: 0)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(initialRepeatDelay),
            repeating: .milliseconds(repeatInterval),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in self?.repeatTick(id: id) }
        timer.resume()
        self.timer = timer
        logger(
            "BUTTON HOLD operation_id=\(id.uuidString) phase=hold_started key=\(target.keyCode) " +
                "repeat_after_ms=\(initialRepeatDelay) repeat_interval_ms=\(repeatInterval)"
        )
        return true
    }

    /// 抬起当前按住的键。没有会话时是空操作，可以安全重复调用。
    func end(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = session else { return }
        releaseLocked(existing, reason: reason)
    }

    private func repeatTick(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = session, current.id == id else { return }
        let elapsed = now().timeIntervalSince(current.startedAt)
        if elapsed * 1000 >= Double(Self.maximumDurationMilliseconds) {
            releaseLocked(current, reason: "maximum_duration")
            return
        }
        guard poster(current.target.keyCode, true, current.target.flags, true) else {
            releaseLocked(current, reason: "repeat_not_submitted")
            return
        }
        session?.repeats = current.repeats + 1
    }

    /// 调用方必须已持有 `lock`。
    private func releaseLocked(_ current: Session, reason: String) {
        timer?.cancel()
        timer = nil
        session = nil
        // 抬起必须无条件尝试：即使按下或重复曾失败，系统里也不能留下按住的键。
        let released = poster(current.target.keyCode, false, current.target.flags, false)
        let elapsed = Int(now().timeIntervalSince(current.startedAt) * 1000)
        logger(
            "BUTTON HOLD operation_id=\(current.id.uuidString) phase=hold_ended reason=\(reason) " +
                "key=\(current.target.keyCode) repeats=\(current.repeats) elapsed_ms=\(elapsed) " +
                "release_submitted=\(released) user_visible_result=unknown"
        )
    }
}
