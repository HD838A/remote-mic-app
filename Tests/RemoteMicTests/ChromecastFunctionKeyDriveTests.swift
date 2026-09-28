import Foundation
import Testing
@testable import RemoteMic

@Suite("Chromecast 语音键驱动（长按式 / 点按式）")
struct ChromecastFunctionKeyDriveTests {
    // MARK: - 事件形状

    @Test func holdDriveSendsPressOnStartAndReleaseOnStop() {
        // 长按式工具（豆包「长按模式」）：按住说话、松开结束。
        #expect(ChromecastFunctionKeyDrive.hold.startEvents == [.press])
        #expect(ChromecastFunctionKeyDrive.hold.stopEvents == [.release])
    }

    @Test func tapsDriveSendsPairedTapsOnBothEdges() {
        // 点按式工具（豆包「免按模式」、Typeless）：开始一次点按、结束再一次点按。
        #expect(ChromecastFunctionKeyDrive.taps.startEvents == [.press, .release])
        #expect(ChromecastFunctionKeyDrive.taps.stopEvents == [.press, .release])
    }

    @Test func startOfTapsDriveAlwaysReleasesTheKey() {
        // 开始的点按必须自己松开：否则 Fn 修饰位在整个会话期间被按住，
        // 用户此时打字会变成 Fn 组合键。
        #expect(ChromecastFunctionKeyDrive.taps.startEvents.last == .release)
    }

    @Test func stopOfTapsDriveAlwaysPressesTheKey() {
        // 真机实测（Testing/VoiceKeyFnPanelProbe.swift）：点按式工具对「松开」无反应，
        // 结束必须再给一次「按下」，否则真机表现就是「按一下结束不生效、要再按一下」。
        #expect(ChromecastFunctionKeyDrive.taps.stopEvents.first == .press)
    }

    // MARK: - 驱动推导（能力矩阵）

    @Test func resolveFollowsTheRemoteVoiceModeWhenToolSupportsHold() {
        // 工具支持长按（豆包长按模式/微信/Vokie/ChatterFly）：跟随遥控器自己的收音方式。
        #expect(
            ChromecastFunctionKeyDrive.resolve(
                voiceMode: .toggle,
                toolSupportsHoldVoiceRecording: true
            ) == .taps
        )
        #expect(
            ChromecastFunctionKeyDrive.resolve(
                voiceMode: .hold,
                toolSupportsHoldVoiceRecording: true
            ) == .hold
        )
    }

    @Test func resolveUsesTapsForToolsWithoutHoldToTalk() {
        // Typeless 一类只认点按：遥控器怎么按都得靠成对点按把开关交出去。
        #expect(
            ChromecastFunctionKeyDrive.resolve(
                voiceMode: .hold,
                toolSupportsHoldVoiceRecording: false
            ) == .taps
        )
        #expect(
            ChromecastFunctionKeyDrive.resolve(
                voiceMode: .toggle,
                toolSupportsHoldVoiceRecording: false
            ) == .taps
        )
    }
}
