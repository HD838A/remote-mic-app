import Foundation
import Testing
@testable import RemoteMic

private final class SleepTransportFake: RemoteSleepConnectionTransport {
    var requests: [UUID] = []
    var completion: ((Bool) -> Void)?
    var cancellations = 0
    var restorations = 0
    func isolate(_ identifier: UUID, completion: @escaping (Bool) -> Void) {
        requests.append(identifier)
        self.completion = completion
    }
    func cancelPendingIsolation() { cancellations += 1 }
    func restore() { restorations += 1 }
}

@Suite("Remote sleep acknowledgement", .serialized)
@MainActor
struct RemoteSleepConnectionControllerTests {
    @Test func successfulDisconnectAcknowledgesSleepOnceAndDisableReleasesTarget() {
        let controller = RemoteSleepConnectionController()
        let transport = SleepTransportFake()
        var enabledTarget: UUID? = UUID()
        var protected: UUID?
        var acknowledgements: [Int] = []
        controller.selectedTarget = { enabledTarget }
        controller.makeAdapter = { transport }
        controller.isSupported = { true }
        controller.setProtectedTarget = { protected = $0 }
        controller.acknowledge = { acknowledgements.append($0) }
        controller.handle(0xe0000280, argument: UnsafeMutableRawPointer(bitPattern: 101))
        #expect(protected == enabledTarget)
        #expect(transport.requests == [enabledTarget!])
        #expect(acknowledgements.isEmpty)
        transport.completion?(true)
        transport.completion?(true)
        #expect(acknowledgements == [101])
        enabledTarget = nil
        controller.configurationChanged()
        #expect(protected == nil)
        #expect(transport.restorations == 1)
        controller.stop()
        #expect(acknowledgements == [101])
    }

    @Test func timeoutAcknowledgesWithoutVetoAndCancelsPendingConnection() async throws {
        let controller = RemoteSleepConnectionController()
        let transport = SleepTransportFake()
        let target = UUID()
        var protected: UUID?
        var acknowledgements: [Int] = []
        var statuses: [String] = []
        controller.selectedTarget = { target }
        controller.makeAdapter = { transport }
        controller.isSupported = { true }
        controller.isolationTimeout = 0.01
        controller.setProtectedTarget = { protected = $0 }
        controller.acknowledge = { acknowledgements.append($0) }
        controller.onStatus = { statuses.append($0) }
        controller.handle(0xe0000280, argument: UnsafeMutableRawPointer(bitPattern: 102))
        try await Task.sleep(for: .milliseconds(100))
        #expect(acknowledgements == [102])
        #expect(transport.cancellations == 1)
        #expect(protected == target) // Gate app retries despite failed system isolation.
        #expect(statuses.last == "sleep_connection.status.failed")
        transport.completion?(true) // Late completion cannot turn failure into success.
        #expect(statuses.last == "sleep_connection.status.failed")
        controller.stop()
        #expect(protected == nil)
        #expect(transport.restorations == 1)
    }

    @Test func unavailableOptionAndDefaultOffNeverHangSleep() {
        let controller = RemoteSleepConnectionController()
        let transport = SleepTransportFake()
        var acknowledgements: [Int] = []
        controller.makeAdapter = { transport }
        controller.isSupported = { false }
        controller.acknowledge = { acknowledgements.append($0) }
        controller.handle(0xe0000280, argument: UnsafeMutableRawPointer(bitPattern: 103))
        #expect(acknowledgements == [103])
        #expect(transport.requests.isEmpty)
        controller.selectedTarget = { UUID() }
        controller.handle(0xe0000280, argument: UnsafeMutableRawPointer(bitPattern: 104))
        #expect(acknowledgements == [103, 104])
        #expect(transport.requests.isEmpty)
        controller.stop()
    }

    @Test func sleepCancelledBeforeDisconnectInvalidatesCompletionAndRestores() {
        let controller = RemoteSleepConnectionController()
        let transport = SleepTransportFake()
        var protected: UUID?
        var acknowledgements: [Int] = []
        controller.selectedTarget = { UUID() }
        controller.makeAdapter = { transport }
        controller.isSupported = { true }
        controller.setProtectedTarget = { protected = $0 }
        controller.acknowledge = { acknowledgements.append($0) }
        controller.handle(0xe0000280, argument: UnsafeMutableRawPointer(bitPattern: 105))
        controller.handle(0xe0000290, argument: nil)
        transport.completion?(true)
        #expect(acknowledgements == [105])
        #expect(protected == nil)
        #expect(transport.restorations == 1)
        controller.stop()
    }
}
