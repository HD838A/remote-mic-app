import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice silence notice")
struct VoiceSilenceNoticeTests {
    private let threshold = VoiceSilenceNoticeTracker.silenceThreshold

    /// 本固件按 VAD 门控推帧：开麦之后用户没开口就是 0 帧。
    /// 没收到过音频就提示，等于每次按下都弹。
    @Test func noNoticeBeforeAnyAudioArrives() {
        var tracker = VoiceSilenceNoticeTracker()
        tracker.beginSession()

        let early = tracker.consumePresentationIfDue(now: 10_000)
        let late = tracker.consumePresentationIfDue(now: 10_000 + threshold * 10)
        #expect(!early)
        #expect(!late)
    }

    @Test func waitsForTheFullSilenceWindow() {
        var tracker = VoiceSilenceNoticeTracker()
        tracker.beginSession()
        tracker.audioReceived(at: 100)

        let justBefore = tracker.consumePresentationIfDue(now: 100 + threshold - 0.5)
        #expect(!justBefore)

        let exactly = tracker.consumePresentationIfDue(now: 100 + threshold)
        #expect(exactly)
    }

    /// 用户看到一次就够了，反复弹会变成噪音。
    @Test func presentsOnlyOncePerSession() {
        var tracker = VoiceSilenceNoticeTracker()
        tracker.beginSession()
        tracker.audioReceived(at: 100)

        let first = tracker.consumePresentationIfDue(now: 100 + threshold)
        let second = tracker.consumePresentationIfDue(now: 100 + threshold + 60)
        let third = tracker.consumePresentationIfDue(now: 100 + threshold + 600)
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test func newAudioDefersTheWindow() {
        var tracker = VoiceSilenceNoticeTracker()
        tracker.beginSession()
        tracker.audioReceived(at: 100)

        // 静默 50 秒后又说了话：计时从新的音频时刻重新开始。
        tracker.audioReceived(at: 150)
        let tooEarly = tracker.consumePresentationIfDue(now: 150 + threshold - 1)
        #expect(!tooEarly)

        let due = tracker.consumePresentationIfDue(now: 150 + threshold)
        #expect(due)
    }

    /// 上一段的音频时刻不能拿来判断这一段。
    @Test func newSessionStartsFromScratch() {
        var tracker = VoiceSilenceNoticeTracker()
        tracker.beginSession()
        tracker.audioReceived(at: 100)
        let firstSession = tracker.consumePresentationIfDue(now: 100 + threshold)
        #expect(firstSession)

        tracker.endSession()
        tracker.beginSession()
        // 新会话还没收到音频：即使时间已经过去很久也不提示。
        let beforeAudio = tracker.consumePresentationIfDue(now: 100 + threshold * 5)
        #expect(!beforeAudio)

        tracker.audioReceived(at: 1_000)
        let afterAudio = tracker.consumePresentationIfDue(now: 1_000 + threshold)
        #expect(afterAudio)
    }

    @Test func endingSessionClearsPendingState() {
        var tracker = VoiceSilenceNoticeTracker()
        tracker.beginSession()
        tracker.audioReceived(at: 100)
        tracker.endSession()

        #expect(tracker.lastAudioAt == nil)
        #expect(!tracker.didPresent)
    }

    /// 阈值要远长于正常换气与思考，又短到「忘了按第二次」能被发现。
    @Test func thresholdStaysInAUsefulRange() {
        #expect(threshold >= 30)
        #expect(threshold <= 180)
    }
}
