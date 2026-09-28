import Foundation

/// 语音键在目标工具上的一次事件。
enum ChromecastFunctionKeyEvent: Equatable {
    case press
    case release
}

/// 语音键的两种驱动方式。
///
/// 目标工具分两类，语音键的语义必须跟着分：
/// - `hold`：**长按式**工具（豆包「长按模式」、微信输入法等）——按住说话、松开结束。
/// - `taps`：**点按式**工具（豆包「免按模式」、Typeless 等）——按一次开始，再按一次（或再按任意键）
///   结束；**松开不产生任何作用**。
///
/// `taps` 的依据（2026-09-18 真机实测，`Testing/VoiceKeyFnPanelProbe.swift`）：向豆包注入 Fn 按下 →
/// 语音面板出现；注入 Fn 松开并等待 2.5 秒 → 面板仍在；再注入一次按下 → 面板消失；又按下 → 再次出现。
/// 即豆包「免按模式」只在**按下**时切换状态。若沿用 `hold`（一个会话只发一次按下、松开一次），
/// 豆包的状态每**两个**会话才翻转一次——真机表现就是「按一下结束，电平图不消失；再按一下才结束，
/// 但遥控器灯又亮了（因为那一次已经是下一个会话的开始）」。
struct ChromecastFunctionKeyDrive: Equatable {
    /// 开始收音时要发出的事件序列。
    let startEvents: [ChromecastFunctionKeyEvent]
    /// 结束收音时要发出的事件序列。
    let stopEvents: [ChromecastFunctionKeyEvent]

    /// 按住—松开：开始按下（保持按住），结束松开。
    static let hold = ChromecastFunctionKeyDrive(
        startEvents: [.press],
        stopEvents: [.release]
    )

    /// 成对点按：开始按下并立即松开（一次点按），结束时再按下并松开（第二次点按）。
    ///
    /// 开始处必须**松开**：否则 Fn 修饰位在整个会话期间一直被按住，用户此时打字会变成 Fn 组合键
    /// （例如 Fn+Delete 是前向删除），而点按式工具根本不需要这个按住状态。
    static let taps = ChromecastFunctionKeyDrive(
        startEvents: [.press, .release],
        stopEvents: [.press, .release]
    )

    /// 由「遥控器自己的收音方式」与「目标工具是否支持长按」推导驱动方式。
    ///
    /// 规则来自能力矩阵（`VoiceInputCapabilityMatrix.swift` / 公开仓 `remote/遥控器与输入工具能力矩阵.md`）：
    /// - 工具不支持长按（Typeless 一类，只认点按）：无论遥控器怎么按，都只能靠成对点按把开关交到工具手里；
    /// - 工具支持长按：跟随遥控器的语音模式——「按一次说话」用成对点按（与豆包「免按模式」同构），
    ///   「按住说话」用按住—松开（与豆包「长按模式」同构）。
    ///
    /// 注意：这里**不再读**「语音键模拟 Fn 点按」开关。那个开关是为「只会按住收音」的遥控器准备的
    /// （界面也只在那些遥控器上显示），Chromecast 自己就能按一次收音，不需要它。
    static func resolve(
        voiceMode: ChromecastVoiceMode,
        toolSupportsHoldVoiceRecording: Bool
    ) -> ChromecastFunctionKeyDrive {
        guard toolSupportsHoldVoiceRecording else { return .taps }
        return voiceMode == .toggle ? .taps : .hold
    }
}
