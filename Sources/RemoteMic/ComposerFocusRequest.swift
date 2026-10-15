import Foundation

/// Converts the focus callback into a cancellable, bounded operation.
final class ComposerFocusRequest: @unchecked Sendable {
    enum Failure: Error { case timedOut }

    let gate = ApplicationFocusRequestGate()
    let requestID: UInt64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var result: Result<Bool, Error>?

    init() { requestID = gate.begin() }

    private func install(_ continuation: CheckedContinuation<Bool, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ result: Result<Bool, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        _ = gate.begin()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    static func perform(
        timeout: Duration = .seconds(10),
        start: @escaping (ApplicationFocusRequestGate, UInt64, @escaping (Bool) -> Void) -> Bool
    ) async throws -> Bool {
        let request = ComposerFocusRequest()
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                request.finish(.failure(Failure.timedOut))
            } catch {}
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                DispatchQueue.main.async {
                    guard request.gate.isCurrent(request.requestID) else { return }
                    if !start(request.gate, request.requestID, { request.finish(.success($0)) }) {
                        request.finish(.success(false))
                    }
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }
}
