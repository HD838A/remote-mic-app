import AppKit
import SwiftUI

/// 语音会话剩余时间的浮层。
///
/// 会话进行到剩余 10 秒时出现，固定在屏幕下方居中区域（语音输入提示条上方），
/// 到 0 秒后显示「录音已结束」再停留几秒自动消失。
///
/// 这个浮层是纯展示：不结束会话、不发 `STREAM_STOP`、不 flush 音频。
/// 遥控器到点自己停止后，浮层只在本地把文案改成「录音已结束」。
final class VoiceLimitCountdownController {
    private struct Session {
        let model: XiaomiRemoteModel
        let startedAt: Date
        let generation: UInt64
    }

    /// 需要持续读取锚点，因此用固定间隔的短定时器；
    /// 只在浮层可见时逐帧读屏上界面文字，重建面板代价高，不能每秒重建 NSHostingView。
    private static let refreshInterval: TimeInterval = 0.25
    private static let panelSize = CGSize(width: 132, height: 64)

    private let logger: (String) -> Void
    private var panel: NSPanel?
    private var hostView: NSHostingView<VoiceLimitCountdownBubble>?
    private var timer: Timer?
    private var session: Session?
    private var renderedState: VoiceLimitCountdownState = .hidden
    private var renderedRemaining: Int?
    private var previewWorkItem: DispatchWorkItem?

    init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    var isActive: Bool { session != nil }

    /// 蓝牙语音会话在 `STREAM_START` 后调用。
    func begin(model: XiaomiRemoteModel) {
        end(reason: "superseded")
        guard VoiceLimitCountdown.supportsCountdown(model: model) else { return }
        session = Session(model: model, startedAt: Date(), generation: nextGeneration())
        renderedState = .hidden
        renderedRemaining = nil
        logger("UI VOICE_COUNTDOWN phase=started result=armed model=\(model.rawValue)")
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        self.timer = timer
        // `.common` 让浮层在用户拖动窗口或菜单跟踪期间仍然更新。
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 会话结束时调用。已经显示「录音已结束」时保留 hold 期由刷新自行收尾，
    /// 其余情况立即消失，避免残缺提示留在屏幕上。
    func end(reason: String) {
        guard let current = session else { return }
        let elapsed = elapsed(for: current)
        guard elapsed >= VoiceLimitCountdown.limit else {
            // 用户提前松键：立即撤掉，不留残缺提示。
            hide(reason: "session_end_\(reason)")
            return
        }
        // 到点停止：立刻换成「录音已结束」，等 hold 期结束由 refresh 自行隐藏。
        present(
            state: .ended(overshoot: elapsed - VoiceLimitCountdown.limit),
            model: current.model
        )
        logger(
            "UI VOICE_COUNTDOWN phase=stopped result=held reason=\(reason) " +
                "model=\(current.model.rawValue)"
        )
    }

    /// 进程退出或功能关闭时强制清理。
    func stop() {
        hide(reason: "application_stop")
    }

    /// 立即显示给定状态，不依赖语音会话与 50 秒等待。
    ///
    /// 只用于本机验证浮层的位置和外观；它会自动消失，不留下需要手动关闭的状态。
    func showPreview(state: VoiceLimitCountdownState, model: XiaomiRemoteModel, seconds: TimeInterval) {
        hide(reason: "preview_superseded")
        session = Session(model: model, startedAt: Date(), generation: nextGeneration())
        present(state: state, model: model)
        let frame = panel?.frame ?? .zero
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        let visible = screen?.visibleFrame ?? .zero
        logger(
            "UI VOICE_COUNTDOWN phase=preview result=shown placement=screen_bottom_center " +
                "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) " +
                "w=\(Int(frame.width)) h=\(Int(frame.height)) " +
                "screen_w=\(Int(visible.width)) screen_h=\(Int(visible.height)) " +
                "x_center_delta=\(Int(frame.midX - visible.midX)) " +
                "y_from_bottom=\(Int(frame.origin.y - visible.minY))"
        )
        let work = DispatchWorkItem { [weak self] in
            self?.hide(reason: "preview_finished")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        previewWorkItem = work
    }

    private func nextGeneration() -> UInt64 {
        Self.generationCounter &+= 1
        return Self.generationCounter
    }

    private static var generationCounter: UInt64 = 0

    private func elapsed(for session: Session) -> TimeInterval {
        Date().timeIntervalSince(session.startedAt)
    }

    private func refresh() {
        guard let current = session else {
            hide(reason: "no_session")
            return
        }
        let elapsed = elapsed(for: current)
        switch VoiceLimitCountdownTick.resolve(elapsed: elapsed, model: current.model) {
        case .wait:
            break
        case let .show(state):
            present(state: state, model: current.model)
        case .finish:
            hide(reason: "countdown_hold_finished")
        }
    }

    private func present(state: VoiceLimitCountdownState, model: XiaomiRemoteModel) {
        ensurePanel()
        let origin = originForPanel()
        panel?.setFrame(CGRect(origin: origin, size: Self.panelSize), display: false)
        panel?.orderFrontRegardless()
        updateContent(state: state)
        if state != renderedState {
            renderedState = state
            logApplied(state: state, model: model)
        }
    }

    private func updateContent(state: VoiceLimitCountdownState) {
        guard let hostView else { return }
        switch state {
        case .hidden:
            return
        case let .counting(remaining):
            guard renderedRemaining != remaining else { return }
            renderedRemaining = remaining
            hostView.rootView = VoiceLimitCountdownBubble(
                remaining: remaining,
                isEnded: false
            )
        case .ended:
            renderedRemaining = nil
            hostView.rootView = VoiceLimitCountdownBubble(
                remaining: 0,
                isEnded: true
            )
        }
    }

    private func logApplied(
        state: VoiceLimitCountdownState,
        model: XiaomiRemoteModel
    ) {
        switch state {
        case .hidden:
            return
        case let .counting(remaining):
            logger(
                "UI VOICE_COUNTDOWN phase=displayed result=counting model=\(model.rawValue) " +
                    "remaining_s=\(remaining) placement=screen_bottom_center"
            )
        case .ended:
            logger(
                "UI VOICE_COUNTDOWN phase=ended result=notified model=\(model.rawValue) " +
                    "placement=screen_bottom_center"
            )
        }
    }

    /// 浮层固定贴在鼠标所在屏幕的中下方，与语音输入提示条同一片视线。
    private func originForPanel() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return VoiceLimitCountdownAnchor.placement(
            panelSize: Self.panelSize,
            visibleFrame: visibleFrame
        )
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let host = NSHostingView(
            rootView: VoiceLimitCountdownBubble(remaining: 0, isEnded: false)
        )
        host.frame = CGRect(origin: .zero, size: Self.panelSize)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 绝不能拦截点击：用户说话时可能仍在操作目标 App。
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // 必须浮在输入法候选窗之上，否则会被候选条盖住。
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        hostView = host
        self.panel = panel
    }

    private func hide(reason: String) {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        session = nil
        renderedState = .hidden
        renderedRemaining = nil
        hostView = nil
        panel?.contentView = nil
        panel = nil
        logger("UI VOICE_COUNTDOWN phase=stopped result=hidden reason=\(reason)")
    }
}

/// 浮层内容：剩余秒数，或会话已结束的提示。
struct VoiceLimitCountdownBubble: View {
    private static let numberSize: CGFloat = 26
    private static let captionSize: CGFloat = 12
    private static let labelSize: CGFloat = 13

    let remaining: Int
    let isEnded: Bool

    var body: some View {
        VStack(spacing: 2) {
            if isEnded {
                Text(LocalizedStringKey("countdown.recording_ended"))
                    // 中文界面字号不得小于 12pt。
                    .font(.system(size: Self.labelSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Text("\(remaining)")
                    .font(.system(size: Self.numberSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(LocalizedStringKey("countdown.seconds_left"))
                    .font(.system(size: Self.captionSize))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 96)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: isEnded ? 0xA5342C : 0x1C1C1E).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        // 颜色本身不传递唯一含义：数字和文案同时表达状态。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        isEnded
            ? noticeLocalized("countdown.accessibility.ended")
            : String(format: noticeLocalized("countdown.accessibility.remaining"), remaining)
    }
}
