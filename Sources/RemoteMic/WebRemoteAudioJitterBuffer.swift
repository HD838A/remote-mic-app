import Foundation

struct WebRemoteAudioJitterBuffer {
    private var frames: [UInt32: [Int16]] = [:]
    private var expectedSequence: UInt32?
    private var started = false

    let startFrameCount: Int
    let maximumFrameCount: Int

    init(startFrameCount: Int = 8, maximumFrameCount: Int = 40) {
        self.startFrameCount = startFrameCount
        self.maximumFrameCount = maximumFrameCount
    }

    var hasPendingFrames: Bool {
        !frames.isEmpty
    }

    mutating func append(sequence: UInt32, samples: [Int16]) {
        guard !samples.isEmpty else { return }
        if let expectedSequence {
            let distance = Int32(bitPattern: sequence &- expectedSequence)
            if distance < 0 { return }
            if distance > Int32(maximumFrameCount * 2) {
                frames.removeAll(keepingCapacity: true)
                self.expectedSequence = sequence
                started = false
            }
        } else {
            expectedSequence = sequence
        }
        frames[sequence] = samples
        discardOldestFramesIfNeeded()
    }

    mutating func nextFrame(finishing: Bool) -> [Int16]? {
        guard var sequence = expectedSequence else { return nil }
        if !started {
            guard finishing || frames.count >= startFrameCount else { return nil }
            started = true
        }
        if let samples = frames.removeValue(forKey: sequence) {
            expectedSequence = sequence &+ 1
            return samples
        }
        guard !frames.isEmpty else { return nil }
        sequence = sequence &+ 1
        expectedSequence = sequence
        return [Int16](repeating: 0, count: 320)
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        expectedSequence = nil
        started = false
    }

    private mutating func discardOldestFramesIfNeeded() {
        while frames.count > maximumFrameCount, let sequence = expectedSequence {
            frames.removeValue(forKey: sequence)
            expectedSequence = sequence &+ 1
            started = true
        }
    }
}
