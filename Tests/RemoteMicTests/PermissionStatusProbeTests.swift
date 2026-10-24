import Foundation
import Testing
@testable import RemoteMic

/// 权限探测的线程契约与合并策略。
///
/// 这两个不变量共同保证「1 Hz 刷新权限」不会把主线程钉死：查询必须在后台队列上跑，
/// 结果才回主线程交付；tccd 卡住时到达的请求必须合并，不能在恢复后一次性补跑几十次。
@Suite("Permission status probe", .timeLimit(.minutes(3)))
struct PermissionStatusProbeTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var runs = 0
        private var activeQueries = 0
        private var peakConcurrentQueries = 0
        private var deliveryCount = 0
        private var queryOnMainThread: Bool?
        private var deliveryOnMainThread: Bool?
        private var lastSnapshot: PermissionStatusProbe.Snapshot?

        func beginQuery() {
            lock.lock()
            runs += 1
            activeQueries += 1
            peakConcurrentQueries = max(peakConcurrentQueries, activeQueries)
            lock.unlock()
        }

        func endQuery() {
            lock.lock()
            activeQueries -= 1
            lock.unlock()
        }

        func noteQueryThread() {
            lock.lock()
            queryOnMainThread = Thread.isMainThread
            lock.unlock()
        }

        func recordDelivery(_ snapshot: PermissionStatusProbe.Snapshot) {
            lock.lock()
            deliveryCount += 1
            deliveryOnMainThread = Thread.isMainThread
            lastSnapshot = snapshot
            lock.unlock()
        }

        var runCount: Int { locked { runs } }
        var deliveries: Int { locked { deliveryCount } }
        var maxConcurrentQueries: Int { locked { peakConcurrentQueries } }
        var queryRanOnMainThread: Bool? { locked { queryOnMainThread } }
        var deliveryRanOnMainThread: Bool? { locked { deliveryOnMainThread } }
        var snapshot: PermissionStatusProbe.Snapshot? { locked { lastSnapshot } }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    /// 交付固定走主线程，而 CI 上会同时跑几百个测试，主队列可能被别人的工作占住数秒。
    /// 超时只用来兜住真正的死锁，不能短到把「主线程正忙」判成失败；
    /// 2026-10-23 的 macOS CI 就是在这里用 5 秒超时误报过一次。
    private static func waitUntil(
        timeout: TimeInterval = 20,
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

    @Test
    func onboardingDoesNotQueryPermissionsDuringViewInitialization() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/OnboardingView.swift"),
            encoding: .utf8
        )
        // SwiftUI 可在每次父视图刷新时重新构造值；初始化不能同步访问 TCC。
        for query in [
            "CBManager.authorization",
            "HIDRemoteMonitor.isInputMonitoringGranted",
            "KeyboardInjector.isAccessibilityTrusted"
        ] {
            #expect(!source.contains(query))
        }
    }

    @Test
    func fetchQueriesOffTheMainThreadAndDeliversOnIt() async throws {
        let recorder = Recorder()
        let probe = PermissionStatusProbe(label: "test.permission-probe.threads") {
            recorder.beginQuery()
            recorder.noteQueryThread()
            recorder.endQuery()
            return PermissionStatusProbe.Snapshot(
                bluetooth: .allowedAlways,
                inputMonitoring: true,
                accessibility: false
            )
        }

        // 等待真实回调；其他套件可能占用主线程超过 5 秒。
        await withCheckedContinuation { continuation in
            probe.fetch {
                recorder.recordDelivery($0)
                continuation.resume()
            }
        }

        #expect(recorder.queryRanOnMainThread == false)
        #expect(recorder.deliveryRanOnMainThread == true)
        #expect(recorder.snapshot == PermissionStatusProbe.Snapshot(
            bluetooth: .allowedAlways,
            inputMonitoring: true,
            accessibility: false
        ))
    }

    @Test
    func requestsDuringAnInFlightQueryCoalesceIntoOneRerun() async throws {
        let gate = DispatchSemaphore(value: 0)
        let recorder = Recorder()
        let probe = PermissionStatusProbe(label: "test.permission-probe.coalesce") {
            recorder.beginQuery()
            gate.wait()
            recorder.endQuery()
            return PermissionStatusProbe.Snapshot(
                bluetooth: .denied,
                inputMonitoring: false,
                accessibility: false
            )
        }

        probe.fetch { recorder.recordDelivery($0) }
        try await Self.waitUntil("the first in-flight query") { recorder.runCount == 1 }

        probe.fetch { recorder.recordDelivery($0) }
        probe.fetch { recorder.recordDelivery($0) }

        // 第一次查询仍卡在 gate 里：后两个请求只能排队，不会并发查询。
        #expect(recorder.runCount == 1)
        #expect(recorder.maxConcurrentQueries == 1)

        gate.signal()
        try await Self.waitUntil("the coalesced rerun") { recorder.runCount == 2 }
        gate.signal()
        // 三个调用方的回调都要被交付，只是由两次查询共同完成。
        try await Self.waitUntil("all three deliveries") { recorder.deliveries == 3 }
        #expect(recorder.maxConcurrentQueries == 1)
    }
}
