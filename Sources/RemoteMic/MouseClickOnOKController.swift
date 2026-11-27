import Foundation

enum MouseClickOnOKPolicy {
    /// 成功移动后，OK 在这个窗口内改发一次左键单击。
    static let recentMoveWindow: TimeInterval = 5

    static func shouldClick(
        button: RemoteButton,
        phase: RemoteButtonPhase,
        enabled: Bool,
        lastSuccessfulMoveAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard button == .ok, phase == .press, enabled, let lastSuccessfulMoveAt else {
            return false
        }
        let age = now - lastSuccessfulMoveAt
        return age >= 0 && age <= recentMoveWindow
    }
}

/// 把“最近移动过鼠标”转换成一次可观察的 OK 单击；不参与按键手势识别。
final class MouseClickOnOKController {
    private let isEnabled: () -> Bool
    private let lastSuccessfulMoveAt: () -> TimeInterval?
    private let now: () -> TimeInterval
    private let postClick: () -> Bool
    private let logger: (String) -> Void

    init(
        isEnabled: @escaping () -> Bool,
        lastSuccessfulMoveAt: @escaping () -> TimeInterval?,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        postClick: @escaping () -> Bool,
        logger: @escaping (String) -> Void
    ) {
        self.isEnabled = isEnabled
        self.lastSuccessfulMoveAt = lastSuccessfulMoveAt
        self.now = now
        self.postClick = postClick
        self.logger = logger
    }

    /// 返回 true 表示本次 OK 已被鼠标单击消费，调用方不得再执行 OK 的原绑定。
    func handle(button: RemoteButton, phase: RemoteButtonPhase) -> Bool {
        let lastMove = lastSuccessfulMoveAt()
        let timestamp = now()
        guard MouseClickOnOKPolicy.shouldClick(
            button: button,
            phase: phase,
            enabled: isEnabled(),
            lastSuccessfulMoveAt: lastMove,
            now: timestamp
        ) else { return false }

        let started = timestamp
        let submitted = postClick()
        let elapsed = Int((now() - started) * 1_000)
        let sinceMove = lastMove.map { Int((timestamp - $0) * 1_000) } ?? -1
        logger(
            "MOUSE CLICK phase=completed result=\(submitted ? "submitted" : "failed") " +
                "reason=ok_after_move since_move_ms=\(sinceMove) elapsed_ms=\(elapsed) " +
                "target_result=unknown"
        )
        return submitted
    }
}
