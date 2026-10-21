import Foundation
import Testing
@testable import RemoteMic

@Suite struct LocalUsageLedgerTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func store() -> UserDefaults { UserDefaults(suiteName: "LocalUsageTests.\(UUID())")! }
    private func ledger(_ defaults: UserDefaults, now: Date) -> LocalUsageLedger {
        LocalUsageLedger(defaults: defaults, buttonCount: 0, voiceDuration: 0, longestVoice: 0, now: now)
    }

    @Test func canonicalDateIsIndependentOfDeviceTimeZone() {
        #expect(LocalUsageLedger.day(date("2026-10-20T15:59:59Z")) == "2026-10-20")
        #expect(LocalUsageLedger.day(date("2026-10-20T16:00:00Z")) == "2026-10-21")
    }

    @Test func preservesLegacyBaselineWithoutInventingDailyHistory() {
        let defaults = store()
        let l = LocalUsageLedger(defaults: defaults, buttonCount: 100, voiceDuration: 3600,
            longestVoice: 600, now: date("2026-10-19T04:00:00Z"))
        #expect(l.archive?.lifetime.button_count == 100)
        #expect(l.archive?.lifetime.voice_duration_ms == 3_600_000)
        #expect(l.archive?.lifetime.longest_voice_ms == 600_000)
        #expect(l.archive?.days.isEmpty == true)
        #expect(l.archive?.incomplete_days == ["2026-10-19"])
        #expect(defaults.object(forKey: "usage.totalButtonPressCount") == nil)
    }

    @Test func splitsEffectiveAudioAtMidnightAndAttributesFullSessionToStartDay() {
        let defaults = store(), start = date("2026-10-19T15:59:59Z")
        let l = ledger(defaults, now: date("2026-10-18T00:00:00Z"))
        l.beginVoice(at: start)
        l.recordSamples(32_000, endingAt: date("2026-10-19T16:00:01Z"))
        #expect(l.archive?.open_session_day == "2026-10-19")
        #expect(l.finishVoice(fallbackDuration: 30, startedAt: start, endedAt: date("2026-10-19T16:00:05Z")) == 2)
        #expect(l.archive?.days["2026-10-19"]?.voice_duration_ms == 1000)
        #expect(l.archive?.days["2026-10-20"]?.voice_duration_ms == 1000)
        #expect(l.archive?.days["2026-10-19"]?.longest_voice_ms == 2000)
        #expect(l.archive?.days["2026-10-19"]?.voice_session_count == 1)
        #expect(l.archive?.days["2026-10-20"]?.voice_session_count == 0)
    }

    @Test func excludesWaitingAndPausesAndDoesNotWriteForEveryAudioBatch() {
        let defaults = store(), start = date("2026-10-19T01:00:00Z")
        let l = ledger(defaults, now: start)
        l.beginVoice(at: start)
        let persisted = defaults.data(forKey: LocalUsageLedger.storageKey)
        l.recordSamples(16_000, endingAt: start.addingTimeInterval(30))
        l.recordSamples(16_000, endingAt: start.addingTimeInterval(90))
        #expect(defaults.data(forKey: LocalUsageLedger.storageKey) == persisted)
        #expect(l.finishVoice(fallbackDuration: 100, startedAt: start, endedAt: start.addingTimeInterval(100)) == 2)
        #expect(l.archive?.lifetime.voice_duration_ms == 2000)
    }

    @Test func emptySessionAndRepeatedStartDoNotFabricateDuration() {
        let now = date("2026-10-19T01:00:00Z"), l = ledger(store(), now: date("2026-10-18T00:00:00Z"))
        l.beginVoice(at: now)
        l.beginVoice(at: now.addingTimeInterval(5))
        #expect(l.finishVoice(fallbackDuration: 30, startedAt: now, endedAt: now.addingTimeInterval(30)) == 0)
        #expect(l.archive?.days.isEmpty == true)
        #expect(l.archive?.open_session_day == nil)
    }

    @Test func conservesSubMillisecondSamplesAcrossBatches() {
        let now = date("2026-10-19T01:00:00Z"), l = ledger(store(), now: date("2026-10-18T00:00:00Z"))
        l.beginVoice(at: now)
        for i in 1...16 { l.recordSamples(1, endingAt: now.addingTimeInterval(Double(i) / 16_000)) }
        #expect(l.finishVoice(fallbackDuration: 2, startedAt: now, endedAt: now.addingTimeInterval(2)) == 0.001)
        #expect(l.archive?.lifetime.voice_duration_ms == 1)
    }

    @Test func interruptedSessionDoesNotBecomeAFinalDailySummaryAfterRestart() {
        let defaults = store(), now = date("2026-10-19T15:59:59Z")
        let first = ledger(defaults, now: date("2026-10-18T00:00:00Z"))
        first.beginVoice(at: now)
        first.recordSamples(16_000, endingAt: now)
        let next = ledger(defaults, now: date("2026-10-20T02:00:00Z"))
        #expect(next.archive?.open_session_day == nil)
        #expect(next.archive?.incomplete_days.contains("2026-10-19") == true)
        #expect(next.archive?.incomplete_days.contains("2026-10-20") == true)
    }

    @Test func unknownSchemaIsPreservedAndDoesNotResetCounters() throws {
        let defaults = store(), data = Data("{\"schema_version\":99}".utf8)
        defaults.set(data, forKey: LocalUsageLedger.storageKey)
        let l = ledger(defaults, now: date("2026-10-19T01:00:00Z"))
        l.recordButton(at: date("2026-10-19T01:00:00Z"))
        #expect(l.archive == nil)
        #expect(defaults.data(forKey: LocalUsageLedger.storageKey) == data)
    }

    @Test func backwardCompatibilityRetainsOldCountersAndRecognizesDowngradeGap() {
        let defaults = store(), now = date("2026-10-19T01:00:00Z")
        defaults.set(50, forKey: "usage.totalButtonPressCount")
        let l = ledger(defaults, now: now)
        l.recordButton(at: now)
        let next = LocalUsageLedger(defaults: defaults, buttonCount: 80, voiceDuration: 0,
            longestVoice: 0, now: date("2026-10-20T01:00:00Z"))
        #expect(defaults.integer(forKey: "usage.totalButtonPressCount") == 50)
        #expect(next.archive?.lifetime.button_count == 80)
        #expect(next.archive?.incomplete_days.contains("2026-10-20") == true)
    }
}
