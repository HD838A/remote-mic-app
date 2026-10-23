import Foundation
import Testing
@testable import RemoteMic

/// 权限探测的线程契约与合并策略。
///
/// 这两个不变量共同保证「1 Hz 刷新权限」不会把主线程钉死：查询必须在后台队列上跑，
/// 结果才回主线程交付；tccd 卡住时到达的请求必须合并，不能在恢复后一次性补跑几十次。
@Suite("Permission status probe")
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

    private static func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out waiting for the permission probe")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
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

        probe.fetch { recorder.recordDelivery($0) }
        try await Self.waitUntil { recorder.deliveries == 1 }

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
        try await Self.waitUntil { recorder.runCount == 1 }

        probe.fetch { recorder.recordDelivery($0) }
        probe.fetch { recorder.recordDelivery($0) }

        // 第一次查询仍卡在 gate 里：后两个请求只能排队，不会并发查询。
        #expect(recorder.runCount == 1)
        #expect(recorder.maxConcurrentQueries == 1)

        gate.signal()
        try await Self.waitUntil { recorder.runCount == 2 }
        gate.signal()
        // 三个调用方的回调都要被交付，只是由两次查询共同完成。
        try await Self.waitUntil { recorder.deliveries == 3 }
        #expect(recorder.maxConcurrentQueries == 1)
    }
}
