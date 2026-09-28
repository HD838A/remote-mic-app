#if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
import Testing

@testable import RemoteMic

import SayAllSiriRemote

/// 苹果遥控器：宿主的能力判定必须与**型号自报**一致。
///
/// 与 Chromecast 那条链路同构——能力只有一个来源遥控器自己的代码；宿主不再维护型号能力表。
/// 只要任一边漂移（新增/移除能力位、改了型号默认表），这里会失败。
struct SiriCapabilityContractTests {
    /// 私有包里 A2854 的能力声明（真机可核对的依据：`SayAllSiriRemoteModel.capabilities`）。
    /// 注：宿主自己也有一个同名类型（`RemoteHardwareInput.swift`），在同时 import 私有包的上下文
    /// 里必须限定模块名，否则 Ambiguous。
    private let declared: Set<SayAllSiriRemote.RemoteHardwareCapability> =
        SayAllSiriRemoteModel.a2854.capabilities

    @Test func hostFallbackMatchesTheDeclaration() {
        // 未连接时宿主回退到型号默认表；它必须与自报值等价，否则断线期间界面会失真。
        let fallback = RemoteVoiceCapabilities.resolve(
            model: .appleSiriRemoteA2854,
            declared: []
        )
        #expect(fallback.supportsTouchSurface == declared.contains(.touchSurface))
        #expect(fallback.supportsToggleVoiceRecording == declared.contains(.voiceStream))
    }

    @Test func hostHonoursTheDeclaredCapabilities() {
        let projected: SiriRemoteDeclaredCapabilities = [
            .controlEdges, .touchSurface, .continuousScroll,
        ]
        let resolved = RemoteVoiceCapabilities.resolve(
            model: .appleSiriRemoteA2854,
            declared: projected.asDeclaredVoiceCapabilities
        )
        #expect(resolved.supportsTouchSurface)
        #expect(!resolved.supportsToggleVoiceRecording)
        // 有触摸面 → 触摸类设置可以出现；没有「按一次收音」→ 「Fn 点按」开关仍在。
        #expect(
            TouchSurfaceControlApplicability.isApplicable(
                capabilities: resolved,
                pageRequestsControl: true
            )
        )
        #expect(VoiceFunctionKeyTapApplicability.isApplicable(capabilities: resolved))
    }

    @Test func modelWithoutTouchSurfaceLosesTheTouchControls() {
        // 将来若出现不具备触摸面的型号，宿主必须立刻不再显示触摸类设置。
        let resolved = RemoteVoiceCapabilities.resolve(
            model: .appleSiriRemoteA2854,
            declared: SiriRemoteDeclaredCapabilities.controlEdges.asDeclaredVoiceCapabilities
        )
        #expect(!resolved.supportsTouchSurface)
        #expect(
            !TouchSurfaceControlApplicability.isApplicable(
                capabilities: resolved,
                pageRequestsControl: true
            )
        )
    }

    // MARK: - 位序安全

    @Test func projectionMapsBitsByNameNotByPosition() {
        // 两条链路的位序不同：苹果遥控器 bit1 = touchSurface，Chromecast bit1 = voiceStream。
        // 若哪天改成按 rawValue 复制，这条会失败。
        let siriTouchOnly: SiriRemoteDeclaredCapabilities = [.touchSurface]
        #expect(siriTouchOnly.asDeclaredVoiceCapabilities.contains(.touchSurface))
        #expect(!siriTouchOnly.asDeclaredVoiceCapabilities.contains(.voiceStream))

        let siriVoiceOnly: SiriRemoteDeclaredCapabilities = [.voiceStream]
        #expect(siriVoiceOnly.asDeclaredVoiceCapabilities.contains(.voiceStream))
        #expect(!siriVoiceOnly.asDeclaredVoiceCapabilities.contains(.touchSurface))

        let siriBattery: SiriRemoteDeclaredCapabilities = [.batteryLevel]
        #expect(siriBattery.asDeclaredVoiceCapabilities.contains(.battery))
    }

    @Test func everySiriCapabilityBitIsDefinedInTheHostMirror() {
        // 宿主镜像必须覆盖私有包每一个能力位，否则新位会被静默丢掉。
        var all: SiriRemoteDeclaredCapabilities = []
        for capability in SayAllSiriRemote.RemoteHardwareCapability.allCases {
            switch capability {
            case .controlEdges: all.insert(.controlEdges)
            case .touchSurface: all.insert(.touchSurface)
            case .continuousScroll: all.insert(.continuousScroll)
            case .voiceStream: all.insert(.voiceStream)
            case .batteryLevel: all.insert(.batteryLevel)
            case .powerState: all.insert(.powerState)
            }
        }
        #expect(all.contains(.controlEdges))
        #expect(all.contains(.touchSurface))
        #expect(all.contains(.continuousScroll))
        #expect(all.contains(.voiceStream))
        #expect(all.contains(.batteryLevel))
        #expect(all.contains(.powerState))
    }
}
#endif
