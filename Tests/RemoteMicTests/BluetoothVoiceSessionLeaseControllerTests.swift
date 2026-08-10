import Foundation
import Testing
@testable import RemoteMic

@Suite("Bluetooth voice session lease")
struct BluetoothVoiceSessionLeaseControllerTests {
    @Test func threeMinuteTrialKeepsTheSessionAliveThenClosesIt() {
        let scheduler = TestBluetoothVoiceLeaseScheduler()
        var isActive = true
        var extensionTimes: [TimeInterval] = []
        var closeTimes: [TimeInterval] = []
        var reconnectTimes: [TimeInterval] = []
        let controller = BluetoothVoiceSessionLeaseController(
            schedule: scheduler.schedule
        )

        controller.start(
            isActive: { isActive },
            requestExtend: {
                extensionTimes.append(scheduler.now)
                return true
            },
            requestClose: {
                closeTimes.append(scheduler.now)
                return true
            },
            reconnect: {
                reconnectTimes.append(scheduler.now)
            },
            log: { _ in }
        )

        scheduler.advance(to: 179)
        #expect(extensionTimes == Array(stride(from: 10.0, through: 170.0, by: 10.0)))
        #expect(closeTimes.isEmpty)

        scheduler.advance(to: 180)
        #expect(closeTimes == [180])
        #expect(extensionTimes.count == 17)

        isActive = false
        controller.stop()
        scheduler.advance(to: 183)
        #expect(reconnectTimes.isEmpty)
    }

    @Test func missingStopConfirmationReconnectsOnlyTheActiveSession() {
        let scheduler = TestBluetoothVoiceLeaseScheduler()
        var reconnectCount = 0
        let controller = BluetoothVoiceSessionLeaseController(
            schedule: scheduler.schedule
        )

        controller.start(
            isActive: { true },
            requestExtend: { true },
            requestClose: { true },
            reconnect: { reconnectCount += 1 },
            log: { _ in }
        )

        scheduler.advance(to: 182)
        #expect(reconnectCount == 1)
    }

    @Test func remoteStopCancelsKeepAliveAndLimitTasks() {
        let scheduler = TestBluetoothVoiceLeaseScheduler()
        var extendCount = 0
        var closeCount = 0
        let controller = BluetoothVoiceSessionLeaseController(
            schedule: scheduler.schedule
        )

        controller.start(
            isActive: { true },
            requestExtend: {
                extendCount += 1
                return true
            },
            requestClose: {
                closeCount += 1
                return true
            },
            reconnect: {},
            log: { _ in }
        )
        scheduler.advance(to: 25)
        controller.stop()
        scheduler.advance(to: 200)

        #expect(extendCount == 2)
        #expect(closeCount == 0)
    }
}

private final class TestBluetoothVoiceLeaseScheduler {
    private final class Task {
        let id: UInt64
        var deadline: TimeInterval
        let interval: TimeInterval?
        let action: () -> Void
        var isCancelled = false

        init(
            id: UInt64,
            deadline: TimeInterval,
            interval: TimeInterval?,
            action: @escaping () -> Void
        ) {
            self.id = id
            self.deadline = deadline
            self.interval = interval
            self.action = action
        }
    }

    private(set) var now: TimeInterval = 0
    private var nextID: UInt64 = 0
    private var tasks: [Task] = []

    func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval?,
        operation: @escaping () -> Void
    ) -> BluetoothVoiceLeaseScheduledTask {
        nextID &+= 1
        let task = Task(
            id: nextID,
            deadline: now + delay,
            interval: interval,
            action: operation
        )
        tasks.append(task)
        return BluetoothVoiceLeaseScheduledTask {
            task.isCancelled = true
        }
    }

    func advance(to target: TimeInterval) {
        while let task = tasks
            .filter({ !$0.isCancelled && $0.deadline <= target })
            .min(by: {
                ($0.deadline, $0.id) < ($1.deadline, $1.id)
            }) {
            now = task.deadline
            task.action()
            if let interval = task.interval, !task.isCancelled {
                task.deadline += interval
            } else {
                task.isCancelled = true
            }
        }
        now = target
    }
}
