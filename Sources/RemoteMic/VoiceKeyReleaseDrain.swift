/// Serializes a software PTT release with playback completion on the main queue.
/// Cancelling invalidates only this waiter, never the shared audio output queue.
final class VoiceKeyReleaseDrain {
    private var generation: UInt64 = 0
    private(set) var isPending = false

    func wait(
        drain: (@escaping () -> Void) -> Void,
        release: @escaping () -> Void
    ) {
        cancel()
        let expectedGeneration = generation
        isPending = true
        drain { [weak self] in
            guard let self, self.generation == expectedGeneration, self.isPending else { return }
            self.isPending = false
            release()
        }
    }

    func cancel() {
        generation &+= 1
        isPending = false
    }
}
