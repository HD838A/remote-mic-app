import Foundation

/// Numeric local summaries. Legacy settings remain readable by earlier versions.
struct LocalUsageCounters: Codable, Equatable {
    var button_count: UInt64 = 0
    var voice_duration_ms: UInt64 = 0
    var voice_session_count: UInt64 = 0
    var longest_voice_ms: UInt64 = 0
}

struct LocalUsageArchive: Codable {
    var schema_version = 1
    var first_day: String
    var last_observed_day: String
    var incomplete_days: Set<String>
    var open_session_day: String?
    var days: [String: LocalUsageCounters]
    var lifetime: LocalUsageCounters
}

final class LocalUsageLedger {
    static let storageKey = "usage.localSummary.v1"
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }
    static func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private let defaults: UserDefaults
    private(set) var archive: LocalUsageArchive?
    private var sessionStart: Date?
    private var sessionSamples: UInt64 = 0
    private var sessionSegments: [String: UInt64] = [:]

    init(defaults: UserDefaults, buttonCount: UInt64, voiceDuration: TimeInterval,
         longestVoice: TimeInterval, now: Date = Date()) {
        self.defaults = defaults
        let today = Self.day(now)
        let baseline = LocalUsageCounters(button_count: buttonCount,
            voice_duration_ms: Self.milliseconds(voiceDuration),
            longest_voice_ms: Self.milliseconds(longestVoice))
        if let data = defaults.data(forKey: Self.storageKey) {
            guard var stored = try? JSONDecoder().decode(LocalUsageArchive.self, from: data),
                  stored.schema_version == 1 else { return }
            // An interrupted session or an older app can leave an unmeasured interval.
            let hasLegacyGap = baseline.button_count > stored.lifetime.button_count ||
                baseline.voice_duration_ms > stored.lifetime.voice_duration_ms
            if stored.open_session_day != nil || hasLegacyGap {
                let start = stored.open_session_day ?? stored.last_observed_day
                var date = Self.calendar.date(byAdding: .day, value: -14, to: now)!
                while date <= now {
                    let day = Self.day(date)
                    if day >= start { stored.incomplete_days.insert(day) }
                    date = Self.calendar.date(byAdding: .day, value: 1, to: date)!
                }
            }
            stored.open_session_day = nil
            stored.lifetime.button_count = max(stored.lifetime.button_count, baseline.button_count)
            stored.lifetime.voice_duration_ms = max(stored.lifetime.voice_duration_ms, baseline.voice_duration_ms)
            stored.lifetime.longest_voice_ms = max(stored.lifetime.longest_voice_ms, baseline.longest_voice_ms)
            stored.last_observed_day = today
            archive = stored
        } else {
            archive = LocalUsageArchive(first_day: today, last_observed_day: today,
                incomplete_days: [today], days: [:], lifetime: baseline)
        }
        persist(at: now)
    }

    func recordButton(at date: Date) {
        guard var state = archive else { return }
        let day = Self.day(date)
        var counters = state.days[day] ?? LocalUsageCounters()
        counters.button_count = Self.add(counters.button_count, 1)
        state.days[day] = counters
        state.lifetime.button_count = Self.add(state.lifetime.button_count, 1)
        archive = state
        persist(at: date)
    }

    func beginVoice(at date: Date) {
        guard sessionStart == nil, archive != nil else { return }
        sessionStart = date
        sessionSamples = 0
        sessionSegments = [:]
        archive?.open_session_day = Self.day(date)
        persist(at: date)
    }

    /// The shared receive boundary calls this once per accepted 16 kHz PCM batch.
    /// Counting samples excludes waiting, pauses, wall-clock jumps and output fan-out.
    func recordSamples(_ count: Int, endingAt date: Date) {
        guard count > 0, sessionStart != nil, archive != nil else { return }
        let samples = UInt64(count)
        sessionSamples = Self.add(sessionSamples, samples)
        var remaining = samples
        var end = date
        while remaining > 0 {
            let startOfDay = Self.calendar.startOfDay(for: end)
            let capacity = UInt64(max(0, end.timeIntervalSince(startOfDay) * 16_000).rounded())
            if capacity == 0 {
                end = end.addingTimeInterval(-1.0 / 16_000)
                continue
            }
            let part = min(remaining, capacity)
            sessionSegments[Self.day(end), default: 0] = Self.add(sessionSegments[Self.day(end), default: 0], part)
            remaining -= part
            end = end.addingTimeInterval(-Double(part) / 16_000)
        }
    }

    /// A caller without an active receive session can supply an already measured duration.
    @discardableResult
    func finishVoice(fallbackDuration: TimeInterval, startedAt: Date?, endedAt: Date) -> TimeInterval {
        guard var state = archive else { return fallbackDuration }
        let hadSession = sessionStart != nil
        let start = sessionStart ?? startedAt ?? endedAt.addingTimeInterval(-max(0, fallbackDuration))
        let duration = hadSession ? Double(sessionSamples) / 16_000 : fallbackDuration
        let totalMS = Self.milliseconds(duration)
        var segments = sessionSegments
        if !hadSession, totalMS > 0 {
            sessionStart = start
            recordSamples(Int(min(Double(Int.max), duration * 16_000)), endingAt: endedAt)
            segments = sessionSegments
        }
        if totalMS > 0 {
            var allocated: UInt64 = 0
            let days = segments.keys.sorted()
            for (index, day) in days.enumerated() {
                let ms = index == days.count - 1 ? totalMS - min(totalMS, allocated) : min(totalMS - min(totalMS, allocated), segments[day]! / 16)
                var counters = state.days[day] ?? LocalUsageCounters()
                counters.voice_duration_ms = Self.add(counters.voice_duration_ms, ms)
                state.days[day] = counters
                allocated += ms
            }
            let startDay = Self.day(start)
            var counters = state.days[startDay] ?? LocalUsageCounters()
            counters.voice_session_count = Self.add(counters.voice_session_count, 1)
            counters.longest_voice_ms = max(counters.longest_voice_ms, totalMS)
            state.days[startDay] = counters
            state.lifetime.voice_session_count = Self.add(state.lifetime.voice_session_count, 1)
            state.lifetime.voice_duration_ms = Self.add(state.lifetime.voice_duration_ms, totalMS)
            state.lifetime.longest_voice_ms = max(state.lifetime.longest_voice_ms, totalMS)
        }
        state.open_session_day = nil
        archive = state
        sessionStart = nil
        sessionSamples = 0
        sessionSegments = [:]
        persist(at: endedAt)
        return Double(totalMS) / 1000
    }

    private func persist(at date: Date) {
        guard var state = archive else { return }
        let cutoff = Self.day(Self.calendar.date(byAdding: .day, value: -14, to: date)!)
        state.days = state.days.filter { $0.key >= cutoff }
        state.incomplete_days = state.incomplete_days.filter { $0 >= cutoff }
        state.last_observed_day = Self.day(date)
        archive = state
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }
    private static func milliseconds(_ duration: TimeInterval) -> UInt64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        let value = duration * 1000
        if value >= Double(UInt64.max) { return .max }
        return UInt64(value.rounded(.down))
    }
}
