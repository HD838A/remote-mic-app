import Foundation

/// Converts post-gain remote PCM into a compact, UI-friendly loudness value.
/// The meter intentionally keeps no audio after each 50 ms analysis window.
struct VoiceAudioLevelMeter {
    static let sampleRate = 16_000
    static let updateWindowSampleCount = sampleRate / 20

    private static let noiseFloorDBFS = -60.0
    private static let displayCeilingDBFS = -6.0
    private static let attackCoefficient = 0.72
    private static let releaseCoefficient = 0.28

    private var accumulatedSquareSum = 0.0
    private var accumulatedSampleCount = 0
    private(set) var level = 0.0

    mutating func append(_ samples: [Int16]) -> Double? {
        guard !samples.isEmpty else { return nil }

        var latestLevel: Double?
        for sample in samples {
            let normalizedSample = Double(sample) / 32_768.0
            accumulatedSquareSum += normalizedSample * normalizedSample
            accumulatedSampleCount += 1

            if accumulatedSampleCount == Self.updateWindowSampleCount {
                let rms = sqrt(accumulatedSquareSum / Double(accumulatedSampleCount))
                let target = Self.normalizedLevel(rms: rms)
                let coefficient = target >= level
                    ? Self.attackCoefficient
                    : Self.releaseCoefficient
                level += (target - level) * coefficient
                latestLevel = level
                accumulatedSquareSum = 0
                accumulatedSampleCount = 0
            }
        }
        return latestLevel
    }

    mutating func reset() {
        accumulatedSquareSum = 0
        accumulatedSampleCount = 0
        level = 0
    }

    static func normalizedLevel(rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(min(1, rms))
        let normalized = (decibels - noiseFloorDBFS) /
            (displayCeilingDBFS - noiseFloorDBFS)
        return min(1, max(0, normalized))
    }
}
