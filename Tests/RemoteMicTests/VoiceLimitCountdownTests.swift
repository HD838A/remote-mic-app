import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice limit countdown")
struct VoiceLimitCountdownTests {
    @Test(arguments: [XiaomiRemoteModel.rc001, .rc003])
    func countdownOnlyStartsInTheLastTenSeconds(model: XiaomiRemoteModel) {
        #expect(VoiceLimitCountdown.state(elapsed: 0, model: model) == .hidden)
        #expect(VoiceLimitCountdown.state(elapsed: 49.9, model: model) == .hidden)
        // 进入第 50 秒就显示 10：向上取整，避免最后一秒闪成 0 再跳回 1。
        #expect(VoiceLimitCountdown.state(elapsed: 50, model: model) == .counting(remaining: 10))
        #expect(VoiceLimitCountdown.state(elapsed: 50.4, model: model) == .counting(remaining: 10))
        #expect(VoiceLimitCountdown.state(elapsed: 51, model: model) == .counting(remaining: 9))
        #expect(VoiceLimitCountdown.state(elapsed: 59, model: model) == .counting(remaining: 1))
    }

    @Test(arguments: [XiaomiRemoteModel.rc001, .rc003])
    func reachingTheLimitReportsRecordingEnded(model: XiaomiRemoteModel) {
        // 到 0 秒立即切换成结束提示，但不能等到遥控器真的停下才提示。
        #expect(VoiceLimitCountdown.state(elapsed: 60, model: model) == .ended(overshoot: 0))
        #expect(
            VoiceLimitCountdown.state(elapsed: 61.5, model: model)
                == .ended(overshoot: 1.5)
        )
        // hold 期结束后彻底消失，不在屏幕上留下陈旧提示。
        #expect(
            VoiceLimitCountdown.state(
                elapsed: 60 + VoiceLimitCountdown.holdTime,
                model: model
            ) == .hidden
        )
    }

    @Test(arguments: [XiaomiRemoteModel.appleSiriRemoteA2854, .chromecastVoiceRemote, .unknown])
    func modelsWithoutProvenLimitNeverShowCountdown(model: XiaomiRemoteModel) {
        // 没有证据表明这些来源存在 60 秒上限；显示倒计时等于制造一个不存在的约束。
        #expect(!VoiceLimitCountdown.supportsCountdown(model: model))
        #expect(VoiceLimitCountdown.state(elapsed: 50, model: model) == .hidden)
        #expect(VoiceLimitCountdown.state(elapsed: 60, model: model) == .hidden)
    }

    @Test func invalidElapsedValuesStayHidden() {
        #expect(VoiceLimitCountdown.state(elapsed: -1, model: .rc003) == .hidden)
        #expect(VoiceLimitCountdown.state(elapsed: .nan, model: .rc003) == .hidden)
        #expect(VoiceLimitCountdown.state(elapsed: .infinity, model: .rc003) == .hidden)
    }

    @Test func titleIsEmptyOnlyWhenHidden() {
        #expect(VoiceLimitCountdownState.hidden.title == nil)
        #expect(VoiceLimitCountdownState.counting(remaining: 7).title == "7")
        #expect(VoiceLimitCountdownState.ended(overshoot: 0.4).title == "0")
    }

    @Test(arguments: [XiaomiRemoteModel.rc001, .rc003])
    func refreshBeforeTheCountdownWindowMustNotFinishTheTimer(model: XiaomiRemoteModel) {
        // 回归：`.hidden` 曾经被当成"提示已过期"，导致第 0.25 秒就拆掉定时器，
        // 长会话永远等不到倒计时。窗口之前的每一次刷新都必须是 `.wait`。
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 0, model: model) == .wait)
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 0.25, model: model) == .wait)
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 1.5, model: model) == .wait)
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 30, model: model) == .wait)
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 49.99, model: model) == .wait)
        // 进入窗口后开始显示，不能落到 `.finish`。
        #expect(
            VoiceLimitCountdownTick.resolve(elapsed: 50, model: model)
                == .show(.counting(remaining: 10))
        )
        #expect(
            VoiceLimitCountdownTick.resolve(elapsed: 59.5, model: model)
                == .show(.counting(remaining: 1))
        )
    }

    @Test(arguments: [XiaomiRemoteModel.rc001, .rc003])
    func refreshAfterTheLimitKeepsShowingEndedUntilHoldExpires(model: XiaomiRemoteModel) {
        // 遥控器实测在 60.040~60.069 秒停止，此时 `state` 已是 `.hidden`；
        // 刷新仍要显示结束文案，直到 hold 期结束才 `.finish`。
        #expect(
            VoiceLimitCountdownTick.resolve(elapsed: 60.05, model: model)
                == .show(.ended(overshoot: 60.05 - VoiceLimitCountdown.limit))
        )
        #expect(
            VoiceLimitCountdownTick.resolve(elapsed: 61.5, model: model)
                == .show(.ended(overshoot: 1.5))
        )
        #expect(
            VoiceLimitCountdownTick.resolve(
                elapsed: 60 + VoiceLimitCountdown.holdTime,
                model: model
            ) == .finish
        )
        #expect(
            VoiceLimitCountdownTick.resolve(
                elapsed: 60 + VoiceLimitCountdown.holdTime + 5,
                model: model
            ) == .finish
        )
    }

    @Test(arguments: [XiaomiRemoteModel.appleSiriRemoteA2854, .chromecastVoiceRemote, .unknown])
    func refreshNeverShowsAnythingForOtherModels(model: XiaomiRemoteModel) {
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 0, model: model) == .finish)
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 55, model: model) == .finish)
        #expect(VoiceLimitCountdownTick.resolve(elapsed: 61, model: model) == .finish)
    }

    @Test func countdownWindowLeavesRoomForTheAudioTail() {
        // 倒计时在 60 秒结束；遥控器实测停止点略晚于 60 秒（60054~60069ms）。
        // hold 期必须覆盖这段抖动，否则“录音已结束”会在遥控器停止后被提前撤掉。
        #expect(VoiceLimitCountdown.holdTime >= 1)
        #expect(VoiceLimitCountdown.leadTime > 0)
        #expect(VoiceLimitCountdown.leadTime < VoiceLimitCountdown.limit)
    }
}

@Suite("Voice limit countdown placement")
struct VoiceLimitCountdownAnchorTests {
    private let panelSize = CGSize(width: 132, height: 64)
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func panelIsHorizontallyCenteredOnScreen() {
        let point = VoiceLimitCountdownAnchor.placement(
            panelSize: panelSize,
            visibleFrame: screen
        )
        #expect(point.x + panelSize.width / 2 == screen.midX)
    }

    @Test func panelSitsJustAboveTheVoiceInputBar() {
        // 语音输入提示条固定在底部居中；浮层紧贴它上方，
        // 这样两件东西在同一片视线内，并且不遮挡提示条。
        let point = VoiceLimitCountdownAnchor.placement(
            panelSize: panelSize,
            visibleFrame: screen
        )
        let centerY = point.y + panelSize.height / 2
        // 必须明显低于屏幕中线，否则会离底部提示条太远。
        #expect(centerY < screen.minY + screen.height * 0.25)
        // 也不能贴到最底边，要给语音输入提示条本身留出位置。
        #expect(centerY > screen.minY + screen.height * 0.10)
    }

    @Test func panelStaysInsideTheVisibleFrame() {
        let point = VoiceLimitCountdownAnchor.placement(
            panelSize: panelSize,
            visibleFrame: screen
        )
        #expect(point.y >= screen.minY)
        #expect(point.y + panelSize.height <= screen.maxY)
        #expect(point.x >= screen.minX)
        #expect(point.x + panelSize.width <= screen.maxX)
    }

    @Test func smallVisibleFrameStillYieldsAUsableOrigin() {
        // 可见区域比浮层还小时不能让上下界互相打架并给出负值。
        let tight = CGRect(x: 0, y: 0, width: 100, height: 40)
        let point = VoiceLimitCountdownAnchor.placement(panelSize: panelSize, visibleFrame: tight)
        #expect(point.x.isFinite && point.y.isFinite)
        #expect(point.x >= tight.minX)
        #expect(point.y >= tight.minY)
    }
}
