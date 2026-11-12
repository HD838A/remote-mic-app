import Foundation
import Testing
@testable import RemoteMic

@Suite("Update check network budget")
struct UpdateCheckCoordinatorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 100_000)

    @Test func repeatedAboutVisitsUseOneSuccessfulCheckForSixHours() {
        var checks = UpdateCheckCoordinator()
        let result1 = checks.request(.information, sessionInProgress: false, now: start)
        #expect(result1 == .start)
        let result2 = checks.finish(success: true, now: start)
        #expect(!result2)
        for minute in 1..<360 {
            let result3 = checks.request(.information, sessionInProgress: false,
                                   now: start.addingTimeInterval(Double(minute) * 60))
            #expect(result3 == .cached)
        }
        let result4 = checks.request(.information, sessionInProgress: false,
                               now: start.addingTimeInterval(6 * 3600))
        #expect(result4 == .start)
    }

    @Test func manualCheckBypassesFreshInformation() {
        var checks = UpdateCheckCoordinator()
        _ = checks.request(.information, sessionInProgress: false, now: start)
        _ = checks.finish(success: true, now: start)
        let result5 = checks.request(.userInitiated, sessionInProgress: false, now: start)
        #expect(result5 == .start)
    }

    @Test func concurrentRequestsAreCoalescedBeforePreviewFeedPrefetch() {
        var checks = UpdateCheckCoordinator()
        let result6 = checks.request(.userInitiated, sessionInProgress: false, now: start)
        #expect(result6 == .start)
        for _ in 0..<10 {
            let result7 = checks.request(.userInitiated, sessionInProgress: false, now: start)
            #expect(result7 == .coalesced)
        }
        let result8 = checks.finish(success: true, now: start)
        #expect(!result8)
    }

    @Test func manualRequestDuringInformationCheckIsReplayedOnce() {
        var checks = UpdateCheckCoordinator()
        _ = checks.request(.information, sessionInProgress: false, now: start)
        for _ in 0..<10 {
            let result9 = checks.request(.userInitiated, sessionInProgress: true, now: start)
            #expect(result9 == .coalesced)
        }
        let result10 = checks.finish(success: true, now: start)
        #expect(result10)
        let result11 = checks.request(.userInitiated, sessionInProgress: false, now: start)
        #expect(result11 == .start)
        let result12 = checks.finish(success: true, now: start)
        #expect(!result12)
    }

    @Test func automaticSparkleSessionAlsoPreservesQueuedManualCheck() {
        var checks = UpdateCheckCoordinator()
        let result13 = checks.request(.userInitiated, sessionInProgress: true, now: start)
        #expect(result13 == .coalesced)
        let result14 = checks.finish(success: true, now: start)
        #expect(result14)
        let result15 = checks.request(.userInitiated, sessionInProgress: false, now: start)
        #expect(result15 == .start)
    }

    @Test func failedChecksAndClockReversalDoNotBecomeFreshCache() {
        var checks = UpdateCheckCoordinator()
        _ = checks.request(.information, sessionInProgress: false, now: start)
        _ = checks.finish(success: false, now: start)
        let result16 = checks.request(.information, sessionInProgress: false, now: start)
        #expect(result16 == .start)
        _ = checks.finish(success: true, now: start)
        let result17 = checks.request(.information, sessionInProgress: false,
                               now: start.addingTimeInterval(-1))
        #expect(result17 == .start)
    }

    @Test func oldChannelCompletionCannotRefreshTheNewChannelCache() {
        var checks = UpdateCheckCoordinator()
        _ = checks.request(.information, sessionInProgress: false, now: start)
        checks.invalidate(cancelPreparation: false)
        _ = checks.finish(success: true, now: start)
        let result18 = checks.request(.information, sessionInProgress: false, now: start)
        #expect(result18 == .start)
    }

    @Test func cancellingChannelResolutionAllowsTheNewChannelToStart() {
        var checks = UpdateCheckCoordinator()
        _ = checks.request(.userInitiated, sessionInProgress: false, now: start)
        checks.invalidate(cancelPreparation: true)
        let result19 = checks.request(.userInitiated, sessionInProgress: false, now: start)
        #expect(result19 == .start)
    }
    @Test func failedManualCheckDoesNotHideBehindAnOlderSuccessfulCache() {
        var checks = UpdateCheckCoordinator()
        _ = checks.request(.information, sessionInProgress: false, now: start)
        _ = checks.finish(success: true, now: start)
        _ = checks.request(.userInitiated, sessionInProgress: false, now: start)
        _ = checks.finish(success: false, now: start)
        let decision = checks.request(.information, sessionInProgress: false, now: start)
        #expect(decision == .start)
    }

}
