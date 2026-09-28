import Foundation
import Testing
@testable import RemoteMic

#if SAYALL_CHROMECAST_ENABLED && canImport(SayAllChromecast)
import SayAllChromecast

/// 跨仓一致性校验：**宿主的能力判断必须与私有包型号自报的能力声明一致**，
/// 且两者都必须与说明文档 `remote/遥控器与输入工具能力矩阵.md` 里写的相符。
///
/// 这样「文档说 Chromecast 支持按一次、不支持触摸面」就不再只是界面里的硬编码：
/// 任何一侧的声明被改动（新增型号、改能力位）都会在这里失败，逼着三处一起改。
@Suite("Chromecast 能力契约（跨仓一致性）")
struct ChromecastCapabilityContractTests {
    private var declared: ChromecastCapabilityFlags {
        ChromecastRemoteModel.chromecastVoiceRemote.capabilities
    }

    @Test func modelDeclaresTheMatrixCapabilities() {
        #expect(declared.contains(.controlEdges))
        #expect(declared.contains(.voiceStream))
        #expect(declared.contains(.toggleVoiceGesture))
        // 文档：Chromecast 无触摸面、不宣告电池。两者都必须保持缺席。
        #expect(!declared.contains(.touchSurface))
        #expect(!declared.contains(.battery))
    }

    @Test func declaredGestureModesCoverHoldAndTapOnce() {
        // 文档：Chromecast 长按收音 ✅、按一次收音 ✅。
        #expect(
            ChromecastRemoteModel.chromecastVoiceRemote.supportedVoiceGestureModes == [.toggle, .hold]
        )
    }

    /// 集成层做的事情：把私有包的位域原样映射到宿主镜像。
    private var mappedToHost: ChromecastDeclaredCapabilities {
        ChromecastDeclaredCapabilities(rawValue: declared.rawValue)
    }

    @Test func hostResolvesTheDeclaredCapabilities() {
        // 端到端：设备报什么，宿主就按什么判定（不再查型号）。
        let resolved = RemoteVoiceCapabilities.resolve(
            model: .chromecastVoiceRemote,
            declared: mappedToHost
        )
        #expect(resolved.supportsToggleVoiceRecording == declared.contains(.toggleVoiceGesture))
        #expect(resolved.supportsTouchSurface == declared.contains(.touchSurface))
        // 与文档一致：会按一次收音 → 页面不出现「Fn 点按」开关；无触摸面 → 触摸类设置不出现。
        #expect(!VoiceFunctionKeyTapApplicability.isApplicable(capabilities: resolved))
        #expect(
            !TouchSurfaceControlApplicability.isApplicable(
                capabilities: resolved,
                pageRequestsControl: true
            )
        )
    }

    @Test func hostMirrorCoversEveryDeclaredBit() {
        // 宿主镜像必须覆盖私有包的每一个能力位，否则新位会被静默丢掉。
        let all: ChromecastCapabilityFlags = [
            .controlEdges, .voiceStream, .touchSurface, .battery, .toggleVoiceGesture,
        ]
        let mirror = ChromecastDeclaredCapabilities(rawValue: all.rawValue)
        #expect(mirror.contains(.controlEdges))
        #expect(mirror.contains(.voiceStream))
        #expect(mirror.contains(.touchSurface))
        #expect(mirror.contains(.battery))
        #expect(mirror.contains(.toggleVoiceGesture))
    }

    @Test func fallbackTableMatchesTheDeclaration() {
        // 未连接时的兜底表必须与自报值等价，否则断线期间界面会失真。
        let fallback = RemoteVoiceCapabilities.resolve(
            model: .chromecastVoiceRemote,
            declared: []
        )
        #expect(fallback.supportsToggleVoiceRecording == declared.contains(.toggleVoiceGesture))
        #expect(fallback.supportsTouchSurface == declared.contains(.touchSurface))
    }

    @Test func hostBatteryPolicyMatchesTheDeclaration() {
        let model = XiaomiRemoteModel.chromecastVoiceRemote
        // 型号不宣告电池时，界面不得显示永远是「未知」的电量位。
        #expect(
            RemoteBatteryPresentationPolicy.shouldShowBattery(
                model: model,
                level: 87,
                powerState: .onBattery
            ) == declared.contains(.battery)
        )
    }
}
#endif
