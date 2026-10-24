import Foundation
import Testing
@testable import RemoteMic

@Suite("HID permission poll")
struct HIDPermissionPollTests {
    @Test @MainActor func sharedPollCallsActualPermissionAPIsOncePerTick() async {
        let scheduler = HIDPermissionPollTestScheduler()
        var inputCalls = 0
        var accessibilityCalls = 0
        let reader = RuntimePermissionReader(inputMonitoring: {
            inputCalls += 1
            return HIDRemoteMonitor.isInputMonitoringGranted
        }, accessibility: {
            accessibilityCalls += 1
            return KeyboardInjector.isAccessibilityTrusted
        })
        var completed: (() -> Void)?
        let poll = RuntimePermissionPoll(scheduler: scheduler, permissionQuery: { needsAX, completion in
            reader.query(needsAccessibility: needsAX) { snapshot in
                completion(snapshot)
                completed?()
            }
        }, logger: { _ in })
        let hid = poll.subscribe { _ in }
        let siri = poll.subscribeInputMonitoring { _ in }
        for _ in 0..<10 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                completed = { continuation.resume() }
                scheduler.fire()
            }
        }
        #expect(inputCalls == 10)
        #expect(accessibilityCalls == 10)
        #expect(scheduler.scheduleCount == 1)
        hid.cancel()
        siri.cancel()
        #expect(scheduler.activeTaskCount == 0)
    }

    @Test @MainActor func systemQueriesRunOffMainAndOnlyReadRequestedPermissions() async {
        var inputCalls = 0
        var accessibilityCalls = 0
        let reader = RuntimePermissionReader(inputMonitoring: {
            #expect(!Thread.isMainThread)
            inputCalls += 1
            return true
        }, accessibility: {
            #expect(!Thread.isMainThread)
            accessibilityCalls += 1
            return false
        })
        for needsAccessibility in [false, true] {
            let snapshot = await withCheckedContinuation { continuation in
                reader.query(needsAccessibility: needsAccessibility) {
                    #expect(Thread.isMainThread)
                    continuation.resume(returning: $0)
                }
            }
            #expect(snapshot.inputMonitoringGranted)
            #expect(!snapshot.accessibilityTrusted)
        }
        #expect(inputCalls == 2)
        #expect(accessibilityCalls == 1)
    }

    @Test func slowQueriesDoNotAccumulateOrDeliverOldResultsToNewSubscribers() {
        let scheduler = HIDPermissionPollTestScheduler()
        var completions: [(RuntimePermissionSnapshot) -> Void] = []
        var queryNeedsAccessibility: [Bool] = []
        let poll = RuntimePermissionPoll(scheduler: scheduler, permissionQuery: { needsAX, completion in
            queryNeedsAccessibility.append(needsAX)
            completions.append(completion)
        }, logger: { _ in })
        var inputResults: [Bool] = []
        var hidResults: [Bool] = []
        let input = poll.subscribeInputMonitoring { inputResults.append($0) }
        scheduler.fire()
        let hid = poll.subscribe { hidResults.append($0) }
        for _ in 0..<100 { scheduler.fire() }
        #expect(queryNeedsAccessibility == [false])
        completions[0](RuntimePermissionSnapshot(inputMonitoringGranted: true, accessibilityTrusted: false))
        #expect(inputResults == [true])
        #expect(hidResults.isEmpty)
        scheduler.fire()
        #expect(queryNeedsAccessibility == [false, true])
        completions[1](RuntimePermissionSnapshot(inputMonitoringGranted: true, accessibilityTrusted: true))
        #expect(inputResults == [true])
        #expect(hidResults == [true])
        input.cancel()
        hid.cancel()
        #expect(scheduler.activeTaskCount == 0)
    }

    @Test func cancellationAndRestartIsolateInFlightQueries() {
        let scheduler = HIDPermissionPollTestScheduler()
        var completions: [(RuntimePermissionSnapshot) -> Void] = []
        let poll = RuntimePermissionPoll(scheduler: scheduler, permissionQuery: { _, completion in
            completions.append(completion)
        }, logger: { _ in })
        var oldResults: [Bool] = []
        var newResults: [Bool] = []
        let old = poll.subscribe { oldResults.append($0) }
        scheduler.fire()
        old.cancel()
        let new = poll.subscribe { newResults.append($0) }
        scheduler.fire()
        #expect(completions.count == 1)
        completions[0](RuntimePermissionSnapshot(inputMonitoringGranted: false, accessibilityTrusted: false))
        #expect(oldResults.isEmpty)
        #expect(newResults.isEmpty)
        scheduler.fire()
        #expect(completions.count == 2)
        new.cancel()
        completions[1](RuntimePermissionSnapshot(inputMonitoringGranted: true, accessibilityTrusted: true))
        #expect(newResults.isEmpty)
    }

    @Test func observersReceiveOnlyTheirRelevantStateChanges() {
        let scheduler = HIDPermissionPollTestScheduler()
        var snapshot = RuntimePermissionSnapshot(inputMonitoringGranted: true, accessibilityTrusted: false)
        let poll = RuntimePermissionPoll(scheduler: scheduler, permissionQuery: { _, completion in
            completion(snapshot)
        }, logger: { _ in })
        var inputResults: [Bool] = []
        var hidResults: [Bool] = []
        let input = poll.subscribeInputMonitoring { inputResults.append($0) }
        let hid = poll.subscribe { hidResults.append($0) }
        scheduler.fire()
        scheduler.fire()
        snapshot = RuntimePermissionSnapshot(inputMonitoringGranted: true, accessibilityTrusted: true)
        scheduler.fire()
        snapshot = RuntimePermissionSnapshot(inputMonitoringGranted: false, accessibilityTrusted: true)
        scheduler.fire()
        #expect(inputResults == [true, false])
        #expect(hidResults == [false, true, false])
        input.cancel()
        hid.cancel()
    }

    @Test func multipleSubscribersEvaluatePermissionOncePerTick() {
        let scheduler = HIDPermissionPollTestScheduler()
        var permissionEvaluationCount = 0
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionEvaluator: {
                permissionEvaluationCount += 1
                return false
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

    @Test func inputMonitoringSubscribersReceiveOnlyInputMonitoringState() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = RuntimePermissionPoll(
            scheduler: scheduler,
            permissionQuery: { _, completion in
                completion(RuntimePermissionSnapshot(
                    inputMonitoringGranted: true,
                    accessibilityTrusted: false
                ))
            },
            logger: { _ in }
        )
        var results: [Bool] = []
        let subscription = poll.subscribeInputMonitoring { results.append($0) }

        scheduler.fire()

        #expect(results == [true])
        subscription.cancel()
    }

    @Test func multipleSubscribersShareOneRepeatingTimer() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(scheduler: scheduler, permissionEvaluator: { true }, logger: { _ in })
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
        let poll = HIDPermissionPoll(scheduler: scheduler, permissionEvaluator: { true }, logger: { _ in })
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
        let poll = HIDPermissionPoll(scheduler: scheduler, permissionEvaluator: { true }, logger: { _ in })
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
        let poll = HIDPermissionPoll(scheduler: scheduler, permissionEvaluator: { true }, logger: { _ in })
        var subscription: HIDPermissionPoll.Subscription? = poll.subscribe { _ in }
        weak let weakSubscription = subscription

        subscription = nil
        #expect(weakSubscription == nil)
        #expect(scheduler.activeTaskCount == 0)
        #expect(scheduler.cancelCount == 1)
    }

    @Test func repeatedCancellationIsIdempotent() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(scheduler: scheduler, permissionEvaluator: { true }, logger: { _ in })
        let subscription = poll.subscribe { _ in }

        subscription.cancel()
        subscription.cancel()
        #expect(scheduler.cancelCount == 1)
        #expect(scheduler.activeTaskCount == 0)
    }

    @Test func callbacksRunOutsideThePollLock() {
        let scheduler = HIDPermissionPollTestScheduler()
        let poll = HIDPermissionPoll(scheduler: scheduler, permissionEvaluator: { true }, logger: { _ in })
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
        var pending: ((RuntimePermissionSnapshot) -> Void)?
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { _, completion in pending = completion },
            logger: { _ in }
        )
        var delivered = false
        let subscription = poll.subscribe { _ in delivered = true }

        scheduler.fire()

        // 查询在本次 tick 内发起，结果还没回来：触发线程没有被同步判定卡住。
        #expect(pending != nil)
        #expect(delivered == false)

        // 结果回来之后才交付给订阅者。
        pending?(RuntimePermissionSnapshot(inputMonitoringGranted: false, accessibilityTrusted: false))
        #expect(delivered == true)
        subscription.cancel()
    }

    /// 结果延迟到达时，已经取消的订阅不应再收到通知。
    @Test func cancelledSubscribersAreNotNotifiedWhenDeliveryIsDeferred() {
        let scheduler = HIDPermissionPollTestScheduler()
        var pending: ((RuntimePermissionSnapshot) -> Void)?
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { _, completion in pending = completion },
            logger: { _ in }
        )
        var firstCalls = 0
        var secondCalls = 0
        let first = poll.subscribe { _ in firstCalls += 1 }
        let second = poll.subscribe { _ in secondCalls += 1 }

        scheduler.fire()
        first.cancel()
        pending?(RuntimePermissionSnapshot(inputMonitoringGranted: false, accessibilityTrusted: false))

        #expect(firstCalls == 0)
        #expect(secondCalls == 1)
        second.cancel()
    }

    @Test func delayedResultDoesNotReachAReplacementSubscription() {
        let scheduler = HIDPermissionPollTestScheduler()
        var pending: ((RuntimePermissionSnapshot) -> Void)?
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { _, completion in pending = completion },
            logger: { _ in }
        )
        let original = poll.subscribe { _ in }
        scheduler.fire()
        original.cancel()
        var results: [Bool] = []
        let replacement = poll.subscribe { results.append($0) }

        pending?(RuntimePermissionSnapshot(inputMonitoringGranted: false, accessibilityTrusted: false))
        #expect(results.isEmpty)
        scheduler.fire()
        pending?(RuntimePermissionSnapshot(inputMonitoringGranted: true, accessibilityTrusted: true))
        #expect(results == [true])
        replacement.cancel()
    }

    @Test func pendingQueryCoalescesTimerTicksAndResumesAfterDelivery() {
        let scheduler = HIDPermissionPollTestScheduler()
        var pending: ((RuntimePermissionSnapshot) -> Void)?
        var queryCount = 0
        let poll = HIDPermissionPoll(
            scheduler: scheduler,
            permissionQuery: { _, completion in queryCount += 1; pending = completion },
            logger: { _ in }
        )
        var results: [Bool] = []
        let subscription = poll.subscribe { results.append($0) }
        for _ in 0..<100 { scheduler.fire() }
        #expect(queryCount == 1)
        pending?(RuntimePermissionSnapshot(inputMonitoringGranted: true, accessibilityTrusted: true))
        #expect(results == [true])
        scheduler.fire()
        #expect(queryCount == 2)
        pending?(RuntimePermissionSnapshot(inputMonitoringGranted: false, accessibilityTrusted: false))
        #expect(results == [true, false])
        subscription.cancel()
    }

    @Test func lifecycleLogsContainOnlyCountsAndTimerTransitions() {
        let scheduler = HIDPermissionPollTestScheduler()
        var logs: [String] = []
        let poll = HIDPermissionPoll(scheduler: scheduler, permissionEvaluator: { true }, logger: { logs.append($0) })
        let first = poll.subscribe { _ in }
        let second = poll.subscribe { _ in }

        first.cancel()
        second.cancel()

        #expect(logs == [
            "RUNTIME PERMISSION POLL phase=subscribed result=active " +
                "subscriber_count=1 timer_started=true",
            "RUNTIME PERMISSION POLL phase=subscribed result=active " +
                "subscriber_count=2 timer_started=false",
            "RUNTIME PERMISSION POLL phase=unsubscribed result=active " +
                "subscriber_count=1 timer_stopped=false",
            "RUNTIME PERMISSION POLL phase=unsubscribed result=stopped " +
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
