import AppKit
import Foundation
import Testing
@testable import RemoteMic

@MainActor
struct ComposerFocusRequestTests {
    @Test func selfFocusIsHandledWithoutQueryingAccessibility() async throws {
        let gate = ApplicationFocusRequestGate()
        let requestID = gate.begin()
        var results: [Bool] = []
        let accepted = KeyboardInjector.focusFrontmostComposer(
            requestGate: gate, requestID: requestID,
            accessibilityTrusted: { true }, frontmostApplication: { .current },
            completion: { results.append($0) }
        )
        #expect(accepted)
        for _ in 0..<5_000 {
            if !results.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(results == [false])
    }

    @Test func macroSelfFocusCompletesInsteadOfTimingOut() async throws {
        let focused = try await ComposerFocusRequest.perform { gate, requestID, completion in
            KeyboardInjector.focusFrontmostComposer(
                requestGate: gate, requestID: requestID,
                accessibilityTrusted: { true }, frontmostApplication: { .current },
                completion: completion
            )
        }
        #expect(!focused)
    }

    @Test func selfFocusRetainsPermissionAndRequestGates() {
        let gate = ApplicationFocusRequestGate()
        let requestID = gate.begin()
        var targetRequested = false
        let target: () -> NSRunningApplication? = { targetRequested = true; return .current }
        #expect(!KeyboardInjector.focusFrontmostComposer(
            requestGate: gate, requestID: requestID,
            accessibilityTrusted: { false }, frontmostApplication: target,
            completion: { _ in Issue.record("Rejected focus must not complete") }
        ))
        #expect(!targetRequested)
        _ = gate.begin()
        #expect(!KeyboardInjector.focusFrontmostComposer(
            requestGate: gate, requestID: requestID,
            accessibilityTrusted: { true }, frontmostApplication: target,
            completion: { _ in Issue.record("Stale focus must not complete") }
        ))
        #expect(!targetRequested)
    }

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
