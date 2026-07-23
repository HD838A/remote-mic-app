import Foundation

enum TestToneGenerator {
    static let duration: TimeInterval = 1.0
    static let frequency: Double = 440.0
    static let amplitude: Double = 0.15

    static func samples(sampleRate: Double) -> [Int16] {
        guard sampleRate > 0 else { return [] }
        let frameCount = Int((sampleRate * duration).rounded())
        guard frameCount > 0 else { return [] }
        let peak = Double(Int16.max) * amplitude
        return (0..<frameCount).map { index in
            let phase = 2.0 * Double.pi * frequency * Double(index) / sampleRate
            return Int16((peak * sin(phase)).rounded())
        }
    }
}

enum TestToneGate {
    static func canPlay(hasSelectedDevice: Bool, isStreaming: Bool, isPlaying: Bool) -> Bool {
        hasSelectedDevice && !isStreaming && !isPlaying
    }
}
