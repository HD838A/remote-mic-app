import Foundation

/// Result of building, preparing and starting an audio engine.
///
/// `failed` carries the original error so the caller can preserve the existing
/// status text and error-domain diagnostics.
enum AudioEngineStartOutcome<Value> {
    case ready(Value)
    case failed(Error)
    case timedOut
}

/// Cancellation flag shared with the worker that may be blocked in Core Audio.
final class AudioEngineStartToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Runs the Core Audio engine work away from the serial audio queue, with a
/// bounded wait.
///
/// A Core Audio call can stop returning after a virtual device is re-enumerated
/// or released. This coordinator keeps that blocked call on its own queue so
/// the audio queue can still finish the attempt, report a timeout, and retry
/// with a fresh engine and worker.
///
/// Everything that synchronously reaches the HAL belongs inside `work`,
/// including device enumeration, `AVAudioEngine` construction, graph
/// connection and binding the output device. A blocked `AVAudioEngine()`
/// initializer wedges its caller exactly like a blocked `prepare()`, so leaving
/// any of those steps on the shared queue reopens the same failure.
struct AudioEngineStartCoordinator {
    typealias QueueFactory = (_ operationID: UInt64, _ attempt: Int) -> DispatchQueue
    typealias Work<Value> = (AudioEngineStartToken) throws -> Value

    static let defaultTimeout: TimeInterval = 2

    private let timeout: TimeInterval
    private let queueFactory: QueueFactory

    init(
        timeout: TimeInterval = Self.defaultTimeout,
        queueFactory: @escaping QueueFactory = Self.makeQueue
    ) {
        self.timeout = timeout
        self.queueFactory = queueFactory
    }

    /// Bounded execution with a value returned to the caller.
    func run<Value>(
        operationID: UInt64,
        attempt: Int,
        work: @escaping Work<Value>,
        cleanup: @escaping () -> Void
    ) -> AudioEngineStartOutcome<Value> {
        let token = AudioEngineStartToken()
        let queue = queueFactory(operationID, attempt)
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var outcome: AudioEngineStartOutcome<Value> = .failed(AudioEngineStartError.cancelled)

        queue.async {
            let result: AudioEngineStartOutcome<Value>
            do {
                let value = try work(token)
                result = token.isCancelled ? .timedOut : .ready(value)
            } catch {
                result = token.isCancelled ? .timedOut : .failed(error)
            }
            resultLock.lock()
            outcome = result
            resultLock.unlock()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            token.cancel()
            // The cleanup stays behind the worker. If the HAL call is still
            // blocked, it runs as soon as the worker returns; if the work
            // already finished, it tears the orphaned engine down promptly.
            queue.async(execute: cleanup)
            return .timedOut
        }

        resultLock.lock()
        defer { resultLock.unlock() }
        return outcome
    }

    /// Bounded execution that only reports the outcome.
    func start(
        operationID: UInt64,
        attempt: Int,
        start: @escaping Work<Void>,
        cleanup: @escaping () -> Void
    ) -> AudioEngineStartOutcome<Void> {
        run(operationID: operationID, attempt: attempt, work: start, cleanup: cleanup)
    }

    private static func makeQueue(operationID: UInt64, attempt: Int) -> DispatchQueue {
        DispatchQueue(
            label: "RemoteMic.audioOutput.prepare.\(operationID).\(attempt)",
            qos: .userInitiated
        )
    }
}

enum AudioEngineStartError: Error {
    case cancelled
}
