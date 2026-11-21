import Foundation

/// 遥控器语音会话的硬件上限提示。
///
/// RC001 / RC003 的语音会话由遥控器固件在约 60 秒处自行结束；Mac 既不能延长，
/// 也不能提前替它收尾。这个类型只负责把「已过多少秒」换算成用户可读的提示状态，
/// 不结束会话、不发送控制命令、不触碰音频。
enum VoiceLimitCountdown {
    /// 遥控器固件实测的硬上限（`ATVV STREAM summary duration_ms` 从未超过 60069）。
    static let limit: TimeInterval = 60

    /// 倒计时出现前的静默时间。前 50 秒不打扰用户。
    static let leadTime: TimeInterval = 10

    /// 倒计时出现后的静默时间，之后转为“录音已结束”提示。
    static let holdTime: TimeInterval = 3

    /// 只有已确认存在 60 秒固件上限的型号提示倒计时。
    ///
    /// 其他型号没有该上限的证据；给它们显示倒计时等于凭空制造一个不存在的约束。
    static func supportsCountdown(model: XiaomiRemoteModel) -> Bool {
        model == .rc001 || model == .rc003
    }

    /// 用户在 `elapsed` 秒时看到的状态。
    static func state(elapsed: TimeInterval, model: XiaomiRemoteModel) -> VoiceLimitCountdownState {
        guard supportsCountdown(model: model) else { return .hidden }
        guard elapsed.isFinite, elapsed >= 0 else { return .hidden }
        if elapsed >= limit + holdTime { return .hidden }
        if elapsed >= limit { return .ended(overshoot: elapsed - limit) }
        let remaining = limit - elapsed
        guard remaining <= leadTime else { return .hidden }
        // 向上取整：刚进入第 50 秒时就显示 10，避免出现 “倒计时停在 1 秒” 的错觉。
        return .counting(remaining: Int(remaining.rounded(.up)))
    }
}

/// 一次定时刷新要做什么。
///
/// 单独抽出来是因为 `.hidden` 同时表示「还没到显示窗口」和「提示已经过期」，
/// 用状态值本身无法区分；早期版本据此在会话第 0.25 秒就拆掉了定时器。
enum VoiceLimitCountdownTick: Equatable {
    /// 继续等待，不改动屏幕。
    case wait
    /// 显示给定的提示。
    case show(VoiceLimitCountdownState)
    /// 这一次倒计时结束，可以清理。
    case finish

    static func resolve(elapsed: TimeInterval, model: XiaomiRemoteModel) -> Self {
        guard elapsed.isFinite, elapsed >= 0 else { return .finish }
        guard supportsCountdown(model: model) else { return .finish }
        switch VoiceLimitCountdown.state(elapsed: elapsed, model: model) {
        case let state where state != .hidden:
            return .show(state)
        case _:
            if elapsed >= limit + holdTime { return .finish }
            if elapsed >= limit {
                // 遥控器实测在 60.040~60.069 秒停止，可能略晚于 limit；
                // 这段时间仍要显示结束文案，而不是当作"还没开始"。
                return .show(.ended(overshoot: elapsed - limit))
            }
            // 还没进入显示窗口：必须继续等。
            return .wait
        }
    }

    private static var limit: TimeInterval { VoiceLimitCountdown.limit }
    private static var holdTime: TimeInterval { VoiceLimitCountdown.holdTime }

    private static func supportsCountdown(model: XiaomiRemoteModel) -> Bool {
        VoiceLimitCountdown.supportsCountdown(model: model)
    }
}

/// 本机验证用的命令行参数解析。
///
/// 只影响是否主动弹出一次预览，不改变任何语音、音频或遥控器行为；
/// 正式启动不带该参数时完全不生效。
enum VoiceLimitCountdownPreview {
    static let flag = "--voice-countdown-preview"

    /// 返回参数后面的秒数（可能为空，表示用默认值）。
    /// 没有该参数时返回 `nil`。
    static func argumentValue(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return "" }
        let candidate = arguments[next]
        // 后面紧跟另一个参数时不把它当成秒数。
        return candidate.hasPrefix("-") ? "" : candidate
    }
}

/// 倒计时当前展示的内容。
enum VoiceLimitCountdownState: Equatable {
    /// 不显示任何提示。
    case hidden
    /// 距离遥控器上限还有多少秒（10…1）。
    case counting(remaining: Int)
    /// 已到遥控器上限；`overshoot` 是超过上限的秒数，只用于日志。
    case ended(overshoot: TimeInterval)

    /// 菜单栏标题。`hidden` 时为空，调用方据此决定是否露出文字。
    var title: String? {
        switch self {
        case .hidden: return nil
        case let .counting(remaining): return "\(remaining)"
        case .ended: return "0"
        }
    }

    /// 日志与状态比较用的稳定标识，不包含用户内容。
    var diagnosticName: String {
        switch self {
        case .hidden: return "hidden"
        case .counting: return "counting"
        case .ended: return "ended"
        }
    }
}
