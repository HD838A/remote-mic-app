import Foundation
import Testing
@testable import RemoteMic

struct ApplicationInstanceGuardTests {
    @Test func onlyOneHolderCanOwnTheInstanceLock() throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMicInstanceLockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false)

        var firstLock: ApplicationInstanceLock?
        switch ApplicationInstanceLock.acquire(at: lockURL) {
        case let .acquired(lock):
            firstLock = lock
        case .alreadyLocked:
            Issue.record("The first lock acquisition unexpectedly found an existing holder")
        case let .failed(reason):
            Issue.record("The first lock acquisition failed: \(reason)")
        }
        #expect(firstLock != nil)

        switch ApplicationInstanceLock.acquire(at: lockURL) {
        case .acquired:
            Issue.record("A second lock holder was admitted while the first was alive")
        case .alreadyLocked:
            break
        case let .failed(reason):
            Issue.record("The second lock acquisition failed unexpectedly: \(reason)")
        }

        firstLock = nil
        switch ApplicationInstanceLock.acquire(at: lockURL) {
        case let .acquired(lock):
            withExtendedLifetime(lock) {}
        case .alreadyLocked:
            Issue.record("The lock remained held after its owner was released")
        case let .failed(reason):
            Issue.record("Reacquiring the released lock failed: \(reason)")
        }
    }

    @Test func defaultLockUsesTheHistoricalApplicationSupportDirectory() throws {
        let lockURL = try #require(ApplicationInstanceGuard.defaultLockURL())

        #expect(lockURL.lastPathComponent == ".app-instance.lock")
        #expect(lockURL.deletingLastPathComponent().lastPathComponent == "RemoteMic")
    }
}
