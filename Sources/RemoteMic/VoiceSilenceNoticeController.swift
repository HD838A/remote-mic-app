import AppKit
import SwiftUI

/// Chromecast 语音会话「长时间没有声音」的判定。
///
/// 远端按 VAD 门控推帧：开麦之后用户没开口就是 0 帧，所以不能从开麦时刻开始计时，
/// 必须**先收到过至少一帧音频**。每次会话只提示一次——用户看到一次就够了，
/// 反复弹会变成噪音。
struct VoiceSilenceNoticeTracker: Equatable {
    /// 静默多久开始提示。取 60 秒：正常换气、思考都远短于它，
    /// 而「说完忘了按第二次」的人通常已经去干别的了。
    static let silenceThreshold: TimeInterval = 60

    private(set) var receivedAudio = false
    private(set) var lastAudioAt: TimeInterval?
    private(set) var didPresent = false

    /// 会话开始：上一段的音频时刻不能拿来判断这一段。
    mutating func beginSession() {
        receivedAudio = false
        lastAudioAt = nil
        didPresent = false
    }

    mutating func audioReceived(at time: TimeInterval) {
        receivedAudio = true
        lastAudioAt = time
    }

    /// 到点就返回 `true`，并且一次会话只会返回一次。
    mutating func consumePresentationIfDue(now: TimeInterval) -> Bool {
        guard receivedAudio, !didPresent, let lastAudioAt,
              now.isFinite, lastAudioAt.isFinite,
              now - lastAudioAt >= Self.silenceThreshold
        else { return false }
        didPresent = true
        return true
    }

    mutating func endSession() {
        receivedAudio = false
        lastAudioAt = nil
        didPresent = false
    }
}

/// 屏幕正中的一次性提示浮窗。
///
/// 窗口参数与 `SiriRemoteCursorFeedbackController` 一致：不抢焦点（`nonactivatingPanel`）、
/// 不挡鼠标（`ignoresMouseEvents`）、所有 Space 含全屏可见（`canJoinAllSpaces` +
/// `fullScreenAuxiliary`）、应用失焦不隐藏（`hidesOnDeactivate = false`）。
///
/// 用户说话时前台通常是输入法或别的 App，SayAll 自己的窗口根本没开，
/// 所以这个提示必须是独立浮窗，不能挂在设置窗口里。
final class VoiceSilenceNoticeController {
    /// 停留时长。比常用语失败提示（3 秒）长一点：这里有两行字要读完。
    static let visibleDuration: TimeInterval = 5

    private var window: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private let logger: (String) -> Void

    init(logger: @escaping (String) -> Void) {
        self.logger = logger
    }

    var isVisible: Bool { window != nil }

    func present(title: String, text: String) {
        dismiss(reason: "replaced")
        let hosting = NSHostingView(rootView: NoticeBubble(tier: .tip, title: title, text: text))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else {
            logger("VOICE SILENCE NOTICE phase=shown result=failed reason=empty_measurement")
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 气泡自带设计阴影；窗口再画一层会沿不透明轮廓留下灰边。
        panel.hasShadow = false
        // 只是提示，不该挡住用户点击它下面的东西。
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)

        // 键盘焦点所在屏：多数情况下就是用户正在操作的那块屏。
        let screen = NSScreen.main?.frame ?? NSRect(origin: .zero, size: size)
        panel.setFrameOrigin(
            NSPoint(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2
            )
        )

        window = panel
        panel.orderFrontRegardless()
        logger(
            "VOICE SILENCE NOTICE phase=shown result=visible "
                + "size=\(Int(size.width))x\(Int(size.height)) duration_s=\(Int(Self.visibleDuration))"
        )

        let work = DispatchWorkItem { [weak self] in self?.dismiss(reason: "timeout") }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.visibleDuration,
            execute: work
        )
    }

    func dismiss(reason: String) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let window else { return }
        window.orderOut(nil)
        self.window = nil
        logger("VOICE SILENCE NOTICE phase=hidden reason=\(reason)")
    }
}
