import Foundation

// 遥控器 × Mac 端输入工具的能力矩阵（单一事实源）。
//
// 权威文档：公开仓 `remote/遥控器与输入工具能力矩阵.md`。**改这里必须同步改那份文档**，
// 反之亦然：界面该显示什么、语音键该怎么驱动，都只能从这份矩阵推导，不允许在页面里各写一套判断。
//
// 矩阵（2026-09-20 由用户补充默认快捷键；未测试项按原文标注）：
//
//   遥控器            长按收音  按一次收音  触摸面
//   小米 RC001/RC003    ✅        ❌        ❌
//   Chromecase          ✅        ✅        ❌
//   Apple Siri Remote   ✅      未测试      ✅
//
//   输入工具          长按收音  长按默认键  按一次收音  按一次默认键
//   Typeless            ❌       不支持       ✅          Fn
//   豆包输入法           ✅       Fn          ✅          右 Command
//   微信输入法           ✅       Fn          ✅          右 Command
//   Vokie               ✅       待确认       ✅          Fn
//   腾讯 ChatterFly      ✅       待确认       ✅          Fn
//
// 由此得到的搭配规则：
// 1. 「语音键模拟 Fn 点按」只在**不会按一次收音**的遥控器上才有意义（它把「按住」模拟成「点按」，
//    用来驱动只认点按的工具）。Chromecase 自己能按一次收音，页面不得出现该开关。
// 2. 触摸面类设置（滑动/光标）只有具备触摸面的遥控器才显示。
// 3. Chromecase 的语音键驱动方式由它自己的语音模式决定，不读上面的开关。

extension XiaomiRemoteModel {
    /// **型号默认值**：是否支持「按一次收音」（按一下开始、再按一下结束）。
    ///
    /// 只在「链路还没自报能力」时回退使用：运行中的判定一律走 `RemoteVoiceCapabilities.resolve`，
    /// 它优先采用设备自报的能力位。这里的值与私有包的型号声明等价，由跨仓一致性测试锁定。
    var supportsToggleVoiceRecording: Bool {
        isChromecaseRemote
    }

    /// **型号默认值**：是否有触摸面（滑动 / 光标）。同上，仅在缺少自报能力时回退使用。
    var supportsTouchSurface: Bool {
        isAppleSiriRemote
    }
}

extension OnboardingVoiceTool {
    /// 是否支持「长按收音」（按住说话、松手结束）。
    /// 已知工具里只有 Typeless 不支持；豆包、微信输入法、Vokie、腾讯 ChatterFly 均支持。
    var supportsHoldVoiceRecording: Bool {
        switch self {
        case .typeless: return false
        case .doubao, .weixin, .vokie, .chatterFly, .unselected, .other: return true
        }
    }
}

/// 遥控器语音能力的**最终判定结果**：链路自报的能力优先，自报缺失时才回退到型号默认表。
struct RemoteVoiceCapabilities: Equatable {
    var supportsToggleVoiceRecording: Bool
    var supportsTouchSurface: Bool

    /// - Parameters:
    ///   - model: 当前选中的遥控器型号（未知时传 nil）。
    ///   - declared: 链路自报的能力位；未连接、型号不支持或设备未自报时为空集合。
    static func resolve(
        model: XiaomiRemoteModel?,
        declared: ChromecaseDeclaredCapabilities = []
    ) -> RemoteVoiceCapabilities {
        guard let model else {
            // 型号都认不出来时，不得假装它支持任何能力。
            return RemoteVoiceCapabilities(
                supportsToggleVoiceRecording: false,
                supportsTouchSurface: false
            )
        }
        // 自报非空即优先（调用方按型号路由到该遥控器所在链路的那份自报，不会串用）；
        // 小米等没有自报通道的遥控器自然落到下面的型号默认表。
        if !declared.isEmpty {
            return RemoteVoiceCapabilities(
                supportsToggleVoiceRecording: declared.contains(.toggleVoiceGesture),
                supportsTouchSurface: declared.contains(.touchSurface)
            )
        }
        return RemoteVoiceCapabilities(
            supportsToggleVoiceRecording: model.supportsToggleVoiceRecording,
            supportsTouchSurface: model.supportsTouchSurface
        )
    }
}

/// 「语音键模拟 Fn 点按」的适用性：界面据此决定是否展示该开关。
///
/// 该开关存在的唯一理由是把遥控器的「按住」模拟成「点按」，去驱动只认点按的输入工具。
/// 因此只有在**不支持按一次收音**的遥控器档案页面上才适用。
enum VoiceFunctionKeyTapApplicability {
    static func isApplicable(capabilities: RemoteVoiceCapabilities) -> Bool {
        !capabilities.supportsToggleVoiceRecording
    }
}

/// 触摸面类设置（滑动箭头、光标反馈）的适用性。
enum TouchSurfaceControlApplicability {
    /// 页面请求了触摸类控件、且该遥控器确实有触摸面时才显示。
    static func isApplicable(
        capabilities: RemoteVoiceCapabilities,
        pageRequestsControl: Bool
    ) -> Bool {
        pageRequestsControl && capabilities.supportsTouchSurface
    }
}
