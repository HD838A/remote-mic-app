import Foundation
import Testing
@testable import RemoteMic

@Suite("HID permission poll")
struct HIDPermissionPollTests {
    @Test func multipleSubscribersEvaluatePermissionOncePerTick() {
        let scheduler = HIDPermissionPollTestScheduler()
        var permissionEvaluationCount = 0
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in
                permissionEvaluationCount += 1
                completion(false)
            },
            logger: { _ in }
        )
        var firstResults: [Bool] = []
        var secondResults: [Bool] = []
        let first = poll.subscribe { firstResults.append($0) }
        let second = poll.subscribe { secondResults.append($0) }

        scheduler.fire()

        #expect(permissionEvaluationCount == 1)
        #expect(firstResults == [false])
        #expect(secondResults == [false])
        first.cancel()
        second.cancel()
    }

    @Test func multipleSubscribersShareOneRepeatingTimer() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in completion(true) },
            logger: { _ in }
        )
        var firstCalls = 0
        var secondCalls = 0
        let first = poll.subscribe { _ in firstCalls += 1 }
        let second = poll.subscribe { _ in secondCalls += 1 }

        #expect(scheduler.scheduleCount == 1)
        #expect(scheduler.activeTaskCount == 1)
        scheduler.fire()
        #expect(firstCalls == 1)
        #expect(secondCalls == 1)

        first.cancel()
        second.cancel()
    }

    @Test func partialCancellationKeepsTimerAndStopsCancelledCallback() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in completion(true) },
            logger: { _ in }
        )
        var firstCalls = 0
        var secondCalls = 0
        let first = poll.subscribe { _ in firstCalls += 1 }
        let second = poll.subscribe { _ in secondCalls += 1 }

        first.cancel()
        #expect(scheduler.activeTaskCount == 1)
        scheduler.fire()
        #expect(firstCalls == 0)
        #expect(secondCalls == 1)

        second.cancel()
        #expect(scheduler.activeTaskCount == 0)
        #expect(scheduler.cancelCount == 1)
    }

    @Test func lastCancellationStopsTimerAndNextSubscriptionCreatesOneTimer() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in completion(true) },
            logger: { _ in }
        )
        let first = poll.subscribe { _ in }

        first.cancel()
        #expect(scheduler.activeTaskCount == 0)
        #expect(scheduler.cancelCount == 1)

        let second = poll.subscribe { _ in }
        #expect(scheduler.scheduleCount == 2)
        #expect(scheduler.activeTaskCount == 1)
        second.cancel()
    }

    @Test func subscriptionDeinitAutomaticallyUnsubscribes() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in completion(true) },
            logger: { _ in }
        )
        var subscription: HIDPermissionPoll.Subscription? = poll.subscribe { _ in }
        weak let weakSubscription = subscription

        subscription = nil
        #expect(weakSubscription == nil)
        #expect(scheduler.activeTaskCount == 0)
        #expect(scheduler.cancelCount == 1)
    }

    @Test func repeatedCancellationIsIdempotent() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in completion(true) },
            logger: { _ in }
        )
        let subscription = poll.subscribe { _ in }

        subscription.cancel()
        subscription.cancel()
        #expect(scheduler.cancelCount == 1)
        #expect(scheduler.activeTaskCount == 0)
    }

    @Test func callbacksRunOutsideThePollLock() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in completion(true) },
            logger: { _ in }
        )
        var subscription: HIDPermissionPoll.Subscription?
        subscription = poll.subscribe { _ in
            subscription?.cancel()
        }

        scheduler.fire()
        #expect(scheduler.activeTaskCount == 0)
        subscription = nil
    }

    /// 定时器只负责发起查询：权限判定本身是同步 IPC 到 tccd，不能占用触发线程。
    @Test func permissionQueryDoesNotBlockTheTimerThread() {
        let scheduler = HIDPermissionPollTestScheduler()
        var pending: ((Bool) -> Void)?
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in pending = completion },
            logger: { _ in }
        )
        var delivered = false
        let subscription = poll.subscribe { _ in delivered = true }

        scheduler.fire()

        // 查询在本次 tick 内发起，结果还没回来：触发线程没有被同步判定卡住。
        #expect(pending != nil)
        #expect(delivered == false)

        // 结果回来之后才交付给订阅者。
        pending?(false)
        #expect(delivered == true)
        subscription.cancel()
    }

    /// 结果延迟到达时，已经取消的订阅不应再收到通知。
    @Test func cancelledSubscribersAreNotNotifiedWhenDeliveryIsDeferred() {
        let scheduler = HIDPermissionPollTestScheduler()
        var pending: ((Bool) -> Void)?
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in pending = completion },
            logger: { _ in }
        )
        var firstCalls = 0
        var secondCalls = 0
        let first = poll.subscribe { _ in firstCalls += 1 }
        let second = poll.subscribe { _ in secondCalls += 1 }

        scheduler.fire()
        first.cancel()
        pending?(false)

        #expect(firstCalls == 0)
        #expect(secondCalls == 1)
        second.cancel()
    }

    @Test func delayedResultDoesNotReachAReplacementSubscription() {
        let scheduler = HIDPermissionPollTestScheduler()
        var pending: ((Bool) -> Void)?
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { pending = $0 },
            logger: { _ in }
        )
        let original = poll.subscribe { _ in }
        scheduler.fire()
        original.cancel()
        var results: [Bool] = []
        let replacement = poll.subscribe { results.append($0) }

        pending?(false)
        #expect(results.isEmpty)
        scheduler.fire()
        pending?(true)
        #expect(results == [true])
        replacement.cancel()
    }

    @Test func pendingQueryCoalescesTimerTicksAndResumesAfterDelivery() {
        let scheduler = HIDPermissionPollTestScheduler()
        var pending: ((Bool) -> Void)?
        var queryCount = 0
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { queryCount += 1; pending = $0 },
            logger: { _ in }
        )
        var results: [Bool] = []
        let subscription = poll.subscribe { results.append($0) }
        for _ in 0..<100 { scheduler.fire() }
        #expect(queryCount == 1)
        pending?(true)
        #expect(results == [true])
        scheduler.fire()
        #expect(queryCount == 2)
        pending?(false)
        #expect(results == [true, false])
        subscription.cancel()
    }

    @Test func lifecycleLogsContainOnlyCountsAndTimerTransitions() {
        let scheduler = HIDPermissionPollTestScheduler()
        var logs: [String] = []
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { completion in completion(true) },
            logger: { logs.append($0) }
        )
        let first = poll.subscribe { _ in }
        let second = poll.subscribe { _ in }

        first.cancel()
        second.cancel()

        #expect(logs == [
            "HID PERMISSION POLL phase=subscribed result=active " +
                "subscriber_count=1 timer_started=true",
            "HID PERMISSION POLL phase=subscribed result=active " +
                "subscriber_count=2 timer_started=false",
            "HID PERMISSION POLL phase=unsubscribed result=active " +
                "subscriber_count=1 timer_stopped=false",
            "HID PERMISSION POLL phase=unsubscribed result=stopped " +
                "subscriber_count=0 timer_stopped=true",
        ])
    }
}

private final class HIDPermissionPollTestScheduler: HIDRemoteScheduling {
    private final class Task: HIDRemoteScheduledTask {
        let action: () -> Void
        private let onCancel: () -> Void
        private(set) var isCancelled = false

        init(action: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.action = action
            self.onCancel = onCancel
        }

        func cancel() {
            guard !isCancelled else { return }
            isCancelled = true
            onCancel()
        }
    }

    private var tasks: [Task] = []
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    var activeTaskCount: Int {
        tasks.lazy.filter { !$0.isCancelled }.count
    }

    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask {
        #expect(afterMilliseconds == HIDRemoteTiming.permissionPollMilliseconds)
        #expect(repeatingEveryMilliseconds == HIDRemoteTiming.permissionPollMilliseconds)
        scheduleCount += 1
        let task = Task(action: action) { [weak self] in
            self?.cancelCount += 1
        }
        tasks.append(task)
        return task
    }

    func fire() {
        let activeTasks = tasks.filter { !$0.isCancelled }
        activeTasks.forEach { $0.action() }
    }
}
