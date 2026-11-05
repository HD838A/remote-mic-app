import AppKit
import Foundation
import Testing
@testable import RemoteMic

/// 宏宿主自聚焦请求的契约。
///
/// `ComposerFocusRequest.perform` 把真正的聚焦动作经 `DispatchQueue.main.async`
/// 投递到主队列。CI 上同进程会同时跑上千个用例，主队列可能被别人的工作占住数秒：
/// 2026-11-04 实测投递延迟可达 27 秒（run 41875979953），于是这里出现两类误报——
/// `perform` 的 10 秒内部超时先到期，以及「轮询 1000 次 × 1ms」的预算被慢机器拉长。
/// 因此这里的等待一律用**墙钟预算**，不用「轮询次数」，并与
/// `PermissionStatusProbeTests` 已有的同一范式保持一致。
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct ComposerFocusRequestTests {
    /// 主队列投递的最坏等待余量。
    ///
    /// 这不是产品契约——产品契约是 `perform` 默认的 10 秒超时，见
    /// `productionTimeoutRemainsTenSeconds`。这里只是「测试环境里主队列最坏
    /// 可能排多久」的余量，取实测最坏值（27 秒）的两倍以上。
    nonisolated private static let mainQueueDeliveryBudget = Duration.seconds(60)

    /// 等到 `condition` 成立或预算耗尽。
    ///
    /// 超时只用来兜住真正的死锁，不能短到把「主线程正忙」判成失败；
    /// 与 `PermissionStatusProbeTests.waitUntil` 同一范式。
    private static func waitUntil(
        timeout: TimeInterval = 60,
        _ description: String,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out waiting for \(description)")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

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
        try await Self.waitUntil("the self focus completion") { !results.isEmpty }
        #expect(results == [false])
    }

    @Test func macroSelfFocusCompletesInsteadOfTimingOut() async throws {
        let focused = try await ComposerFocusRequest.perform(
            timeout: ComposerFocusRequestTests.mainQueueDeliveryBudget
        ) { gate, requestID, completion in
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
            let value = try await ComposerFocusRequest.perform(
                timeout: ComposerFocusRequestTests.mainQueueDeliveryBudget
            ) { _, _, completion in
                callback = completion
                return true
            }
            finished = true
            return value
        }
        try await Self.waitUntil("the focus callback") { callback != nil }
        #expect(!finished)
        let completion = try #require(callback)
        completion(focused)
        completion(!focused)
        #expect(try await task.value == focused)
    }

    @Test func rejectedRequestReturnsFailure() async throws {
        #expect(try await !ComposerFocusRequest.perform(
            timeout: ComposerFocusRequestTests.mainQueueDeliveryBudget
        ) { _, _, _ in false })
    }

    @Test func cancellationInvalidatesFocusAndIgnoresLateCallback() async throws {
        var callback: ((Bool) -> Void)?
        var gate: ApplicationFocusRequestGate?
        var requestID: UInt64?
        let task = Task {
            try await ComposerFocusRequest.perform(
                timeout: ComposerFocusRequestTests.mainQueueDeliveryBudget
            ) { value, identifier, completion in
                gate = value; requestID = identifier; callback = completion
                return true
            }
        }
        try await Self.waitUntil("the focus callback") { callback != nil }
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

    /// 产品契约：默认超时仍是 10 秒。
    ///
    /// 用例里的等待预算被放宽到 60 秒只是为了让测试扛住 CI 上主队列的排队延迟，
    /// 不能因此把生产端的超时一起放宽。这里按仓库既有的源码守卫范式锁定默认值。
    @Test func productionTimeoutRemainsTenSeconds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/ComposerFocusRequest.swift"),
            encoding: .utf8
        )
        #expect(source.contains("timeout: Duration = .seconds(10)"))
    }
}
