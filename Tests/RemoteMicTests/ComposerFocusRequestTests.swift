import Foundation
import Testing
@testable import RemoteMic

@MainActor
struct ComposerFocusRequestTests {
    @Test(arguments: [true, false])
    func acceptedRequestWaitsForFinalCallback(focused: Bool) async throws {
        var callback: ((Bool) -> Void)?
        var finished = false
        let task = Task {
            let value = try await ComposerFocusRequest.perform { _, _, completion in
                callback = completion
                return true
            }
            finished = true
            return value
        }
        for _ in 0..<1_000 {
            if callback != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!finished)
        let completion = try #require(callback)
        completion(focused)
        completion(!focused)
        #expect(try await task.value == focused)
    }

    @Test func rejectedRequestReturnsFailure() async throws {
        #expect(try await !ComposerFocusRequest.perform { _, _, _ in false })
    }

    @Test func cancellationInvalidatesFocusAndIgnoresLateCallback() async throws {
        var callback: ((Bool) -> Void)?
        var gate: ApplicationFocusRequestGate?
        var requestID: UInt64?
        let task = Task {
            try await ComposerFocusRequest.perform { value, identifier, completion in
                gate = value; requestID = identifier; callback = completion
                return true
            }
        }
        for _ in 0..<1_000 {
            if callback != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let completion = try #require(callback)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation must terminate focus") }
        catch { #expect(error is CancellationError) }
        #expect(try #require(gate).isCurrent(#require(requestID)) == false)
        completion(true)
    }

    @Test func missingCallbackTimesOutAndInvalidatesFocus() async throws {
        var gate: ApplicationFocusRequestGate?
        var requestID: UInt64?
        do {
            _ = try await ComposerFocusRequest.perform(timeout: .milliseconds(50)) { value, identifier, _ in
                gate = value; requestID = identifier
                return true
            }
            Issue.record("Missing callback must time out")
        } catch { #expect(error is ComposerFocusRequest.Failure) }
        // A busy main queue may time out before submission; neither path may leave focus pending.
        if let gate, let requestID {
            #expect(!gate.isCurrent(requestID))
        }
    }

    @Test func cancellationBeforeStartDoesNotSubmitFocus() async {
        var submitted = false
        let task = Task {
            try await ComposerFocusRequest.perform { _, _, _ in
                submitted = true
                return true
            }
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request must fail") }
        catch { #expect(error is CancellationError) }
        #expect(!submitted)
    }
}
