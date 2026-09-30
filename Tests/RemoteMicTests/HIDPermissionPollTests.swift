import Foundation
import Testing
@testable import RemoteMic

@Suite("HID permission poll")
struct HIDPermissionPollTests {
    @Test func multipleSubscribersShareOneRepeatingTimer() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(scheduler: scheduler, logger: { _ in })
        var firstCalls = 0
        var secondCalls = 0
        let first = poll.subscribe { firstCalls += 1 }
        let second = poll.subscribe { secondCalls += 1 }

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
        let poll = HIDPermissionPoll(scheduler: scheduler, logger: { _ in })
        var firstCalls = 0
        var secondCalls = 0
        let first = poll.subscribe { firstCalls += 1 }
        let second = poll.subscribe { secondCalls += 1 }

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
        let poll = HIDPermissionPoll(scheduler: scheduler, logger: { _ in })
        let first = poll.subscribe {}

        first.cancel()
        #expect(scheduler.activeTaskCount == 0)
        #expect(scheduler.cancelCount == 1)

        let second = poll.subscribe {}
        #expect(scheduler.scheduleCount == 2)
        #expect(scheduler.activeTaskCount == 1)
        second.cancel()
    }

    @Test func subscriptionDeinitAutomaticallyUnsubscribes() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(scheduler: scheduler, logger: { _ in })
        var subscription: HIDPermissionPoll.Subscription? = poll.subscribe {}
        weak let weakSubscription = subscription

        subscription = nil
        #expect(weakSubscription == nil)
        #expect(scheduler.activeTaskCount == 0)
        #expect(scheduler.cancelCount == 1)
    }

    @Test func repeatedCancellationIsIdempotent() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(scheduler: scheduler, logger: { _ in })
        let subscription = poll.subscribe {}

        subscription.cancel()
        subscription.cancel()
        #expect(scheduler.cancelCount == 1)
        #expect(scheduler.activeTaskCount == 0)
    }

    @Test func callbacksRunOutsideThePollLock() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(scheduler: scheduler, logger: { _ in })
        var subscription: HIDPermissionPoll.Subscription?
        subscription = poll.subscribe {
            subscription?.cancel()
        }

        scheduler.fire()
        #expect(scheduler.activeTaskCount == 0)
        subscription = nil
    }

    @Test func lifecycleLogsContainOnlyCountsAndTimerTransitions() {
        let scheduler = HIDPermissionPollTestScheduler()
        var logs: [String] = []
        let poll = HIDPermissionPoll(scheduler: scheduler, logger: { logs.append($0) })
        let first = poll.subscribe {}
        let second = poll.subscribe {}

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
