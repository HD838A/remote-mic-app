import Foundation
import Testing
@testable import RemoteMic

/// 能力矩阵的回归保护：**这里的断言必须与公开仓 `remote/遥控器与输入工具能力矩阵.md` 一致**。
/// 界面该显示什么、语音键该怎么驱动，都从这份矩阵推导；矩阵变了，这里和文档一起改。
@Suite("能力矩阵：遥控器 × 输入工具")
struct VoiceInputCapabilityMatrixTests {
    // MARK: - 遥控器

    @Test func onlyChromecastSupportsTapOnceRecording() {
        // 小米 RC001/RC003 只能按住收音；Apple Siri Remote 的「按一次」尚未测试，
        // 因此一律按「不支持」处理，不得对外显示该能力。
        #expect(!XiaomiRemoteModel.rc003.supportsToggleVoiceRecording)
        #expect(!XiaomiRemoteModel.rc001.supportsToggleVoiceRecording)
        #expect(!XiaomiRemoteModel.appleSiriRemoteA2854.supportsToggleVoiceRecording)
        #expect(!XiaomiRemoteModel.appleSiriRemoteA2540.supportsToggleVoiceRecording)
        #expect(XiaomiRemoteModel.chromecastVoiceRemote.supportsToggleVoiceRecording)
    }

    @Test func onlyAppleSiriRemoteHasATouchSurface() {
        #expect(XiaomiRemoteModel.appleSiriRemoteA2854.supportsTouchSurface)
        #expect(XiaomiRemoteModel.appleSiriRemoteA2540.supportsTouchSurface)
        #expect(!XiaomiRemoteModel.rc001.supportsTouchSurface)
        #expect(!XiaomiRemoteModel.rc003.supportsTouchSurface)
        #expect(!XiaomiRemoteModel.chromecastVoiceRemote.supportsTouchSurface)
    }

    // MARK: - 输入工具

    @Test func onlyTypelessLacksHoldToTalk() {
        #expect(!OnboardingVoiceTool.typeless.supportsHoldVoiceRecording)
        #expect(OnboardingVoiceTool.doubao.supportsHoldVoiceRecording)
        #expect(OnboardingVoiceTool.weixin.supportsHoldVoiceRecording)
        #expect(OnboardingVoiceTool.other.supportsHoldVoiceRecording)
        #expect(OnboardingVoiceTool.unselected.supportsHoldVoiceRecording)
    }

    // MARK: - 能力判定：链路自报优先，型号默认兜底

    @Test func declaredCapabilitiesWinOverTheModelTable() {
        // 自报说「不支持按一次、但有触摸面」时，判定必须听设备的——型号默认表只用于兜底。
        let declared: ChromecastDeclaredCapabilities = [.controlEdges, .voiceStream, .touchSurface]
        let resolved = RemoteVoiceCapabilities.resolve(
            model: .chromecastVoiceRemote,
            declared: declared
        )
        #expect(!resolved.supportsToggleVoiceRecording)
        #expect(resolved.supportsTouchSurface)
        // 界面随之变化：Fn 点按开关出现（它只会按住），触摸类设置也出现。
        #expect(VoiceFunctionKeyTapApplicability.isApplicable(capabilities: resolved))
        #expect(
            TouchSurfaceControlApplicability.isApplicable(
                capabilities: resolved,
                pageRequestsControl: true
            )
        )
    }

    @Test func declaredCapabilitiesOfThisModelMatchTheMatrix() {
        let declared: ChromecastDeclaredCapabilities = [
            .controlEdges, .voiceStream, .toggleVoiceGesture,
        ]
        let resolved = RemoteVoiceCapabilities.resolve(
            model: .chromecastVoiceRemote,
            declared: declared
        )
        #expect(resolved.supportsToggleVoiceRecording)
        #expect(!resolved.supportsTouchSurface)
        // 会按一次收音，因此不出现「Fn 点按」开关。
        #expect(!VoiceFunctionKeyTapApplicability.isApplicable(capabilities: resolved))
    }

    @Test func fallsBackToTheModelTableWhenNothingIsDeclared() {
        // 未连接、或设备未自报：用型号默认表。
        let chromecast = RemoteVoiceCapabilities.resolve(model: .chromecastVoiceRemote, declared: [])
        #expect(chromecast.supportsToggleVoiceRecording)
        #expect(!chromecast.supportsTouchSurface)

        let siri = RemoteVoiceCapabilities.resolve(model: .appleSiriRemoteA2854, declared: [])
        #expect(siri.supportsTouchSurface)

        let xiaomi = RemoteVoiceCapabilities.resolve(model: .rc003, declared: [])
        #expect(!xiaomi.supportsToggleVoiceRecording)
        #expect(!xiaomi.supportsTouchSurface)
    }

    @Test func unknownModelNeverClaimsCapabilities() {
        let resolved = RemoteVoiceCapabilities.resolve(model: nil, declared: [])
        #expect(!resolved.supportsToggleVoiceRecording)
        #expect(!resolved.supportsTouchSurface)
        // 型号未知时仍保留「Fn 点按」入口：它是驱动点按式工具的唯一办法。
        #expect(VoiceFunctionKeyTapApplicability.isApplicable(capabilities: resolved))
    }

    // MARK: - 界面门禁

    @Test func fnTapSwitchIsNotOfferedForTapOnceRemotes() {
        let resolved = RemoteVoiceCapabilities.resolve(
            model: .chromecastVoiceRemote,
            declared: []
        )
        #expect(!VoiceFunctionKeyTapApplicability.isApplicable(capabilities: resolved))
    }

    @Test func fnTapSwitchStaysAvailableForHoldOnlyRemotes() {
        for model in [XiaomiRemoteModel.rc003, .rc001, .appleSiriRemoteA2854] {
            let resolved = RemoteVoiceCapabilities.resolve(model: model, declared: [])
            #expect(VoiceFunctionKeyTapApplicability.isApplicable(capabilities: resolved))
        }
    }

    @Test func touchControlsNeverAppearWithoutATouchSurface() {
        let siri = RemoteVoiceCapabilities.resolve(model: .appleSiriRemoteA2854, declared: [])
        #expect(
            TouchSurfaceControlApplicability.isApplicable(
                capabilities: siri,
                pageRequestsControl: true
            )
        )
        let xiaomi = RemoteVoiceCapabilities.resolve(model: .rc003, declared: [])
        #expect(
            !TouchSurfaceControlApplicability.isApplicable(
                capabilities: xiaomi,
                pageRequestsControl: true
            )
        )
        let chromecast = RemoteVoiceCapabilities.resolve(model: .chromecastVoiceRemote, declared: [])
        #expect(
            !TouchSurfaceControlApplicability.isApplicable(
                capabilities: chromecast,
                pageRequestsControl: true
            )
        )
        // 页面没请求就不显示（默认路径）。
        #expect(
            !TouchSurfaceControlApplicability.isApplicable(
                capabilities: siri,
                pageRequestsControl: false
            )
        )
    }
}
