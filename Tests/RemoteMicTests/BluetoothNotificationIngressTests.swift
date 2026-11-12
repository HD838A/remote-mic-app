import Foundation
import Testing
@testable import RemoteMic

@Suite("Bluetooth notification ingress")
struct BluetoothNotificationIngressTests {
    @Test func defaultCallbackQueueIsDedicated() {
        #expect(BluetoothNotificationIngress.defaultQueue.label == "RemoteMic.bluetooth")
        #expect(BluetoothNotificationIngress.defaultQueue.label != DispatchQueue.main.label)
    }

    /// Simulates a 24-second RC003 voice session at 66.7 notifications per second
    /// while the main-thread scheduler is held. Every notification must be captured
    /// and later replayed on main in the original order.
    @Test func allFramesWaitForMainAndReplayInOrder() {
        let ingressQueue = DispatchQueue(label: "RemoteMic.tests.bluetooth.ingress")
        var scheduled: [() -> Void] = []
        var delivered: [Data] = []
        let ingress = BluetoothNotificationIngress(
            queue: ingressQueue,
            scheduleOnMain: { operation in scheduled.append(operation) }
        )

        let frameCount = 1_628
        let expected = (0..<frameCount).map {
            Data([UInt8($0 & 0xFF), UInt8(($0 >> 8) & 0xFF)])
        }
        for value in expected {
            ingressQueue.async {
                ingress.receive(value: value, generation: 9) { data, _ in
                    if let data { delivered.append(data) }
                }
            }
        }
        ingressQueue.sync {}

        // The simulated main thread has not run any delivery yet. The callback
        // queue must still have accepted every notification.
        #expect(scheduled.count == frameCount)
        #expect(delivered.isEmpty)

        for operation in scheduled {
            operation()
        }
        #expect(delivered == expected)
    }

    @Test func bridgeWiresTheDedicatedQueueAndCapturesValueBeforeMainHop() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/XiaomiBluetoothBridge.swift"),
            encoding: .utf8
        )
        #expect(source.contains("queue: notificationIngress.queue"))
        #expect(!source.contains("queue: .main"))
        #expect(source.contains("let value = characteristic.value"))
        #expect(source.contains("value: Data?,"))
        #expect(source.contains("notificationIngress.receive("))
        #expect(source.contains("private func onMain("))
    }
}
