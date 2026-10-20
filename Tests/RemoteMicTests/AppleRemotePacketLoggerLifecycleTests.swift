import AppleRemotePacketLogger
import Foundation
import Testing

@Suite("Apple Remote packet logger lifecycle")
struct AppleRemotePacketLoggerLifecycleTests {
    @Test func releasesOnStateQueue() {
        let queue = DispatchQueue(label: "test.packetLogger.state")
        queue.sync {
            var client: AppleRemotePacketLoggerClient? = makeClient(stateQueue: queue)
            weak var releasedClient = client
            client = nil
            #expect(releasedClient == nil)
        }
    }

    @Test func releasesOutsideStateQueue() {
        let queue = DispatchQueue(label: "test.packetLogger.state")
        var client: AppleRemotePacketLoggerClient? = makeClient(stateQueue: queue)
        weak var releasedClient = client
        client = nil
        #expect(releasedClient == nil)
    }

    @Test func clientsCanShareStateQueue() {
        let queue = DispatchQueue(label: "test.packetLogger.shared")
        queue.sync {
            var first: AppleRemotePacketLoggerClient? = makeClient(stateQueue: queue)
            var second: AppleRemotePacketLoggerClient? = makeClient(stateQueue: queue)
            weak var releasedFirst = first
            weak var releasedSecond = second
            first = nil
            second = nil
            #expect(releasedFirst == nil)
            #expect(releasedSecond == nil)
        }
    }

    @Test func releasesAfterQueuedCallback() {
        let queue = DispatchQueue(label: "test.packetLogger.state")
        let ownerReleased = DispatchSemaphore(value: 0)
        var client: AppleRemotePacketLoggerClient? = makeClient(stateQueue: queue)
        weak var releasedClient = client
        // Model a callback holding the final reference after its owner stops.
        queue.async { [retainedClient = client!] in
            #expect(ownerReleased.wait(timeout: .now() + 5) == .success)
            withExtendedLifetime(retainedClient) {}
        }
        client = nil
        ownerReleased.signal()
        queue.sync {}
        #expect(releasedClient == nil)
    }

    @Test func explicitStopsEmitEventsButDeinitDoesNot() {
        let queue = DispatchQueue(label: "test.packetLogger.state")
        let callbackQueue = DispatchQueue(label: "test.packetLogger.callback")
        var events: [AppleRemotePacketLoggerClient.Event] = []
        var client: AppleRemotePacketLoggerClient? = AppleRemotePacketLoggerClient(
            stateQueue: queue,
            callbackQueue: callbackQueue,
            onPacket: { _ in },
            onEvent: { events.append($0) }
        )
        client?.stop()
        client?.stop()
        queue.sync {}
        callbackQueue.sync { #expect(events == [.stopped, .stopped]) }
        weak var releasedClient = client
        client = nil
        #expect(releasedClient == nil)
        callbackQueue.sync { #expect(events == [.stopped, .stopped]) }
    }

    private func makeClient(stateQueue: DispatchQueue) -> AppleRemotePacketLoggerClient {
        AppleRemotePacketLoggerClient(
            stateQueue: stateQueue,
            callbackQueue: DispatchQueue(label: "test.packetLogger.callback"),
            onPacket: { _ in },
            onEvent: { _ in }
        )
    }
}
