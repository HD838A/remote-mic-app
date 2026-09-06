import AppleRemoteHCIProtocol
#if SAYALL_SIRI_REMOTE_ENABLED
import Testing

struct AppleRemoteHCILeaseStateTests {
    private enum TestError: Error {
        case enableFailed
        case restoreFailed
    }

    @Test func multipleLeasesEnableAndRestoreOnlyAtOuterEdges() throws {
        var state = AppleRemoteHCILeaseState()
        var enableCount = 0
        var restoreCount = 0

        state.acquire { enableCount += 1 }
        state.acquire { enableCount += 1 }
        #expect(state.activeLeaseCount == 2)
        #expect(enableCount == 1)

        state.release { restoreCount += 1 }
        #expect(state.activeLeaseCount == 1)
        #expect(restoreCount == 0)

        state.release { restoreCount += 1 }
        #expect(state.activeLeaseCount == 0)
        #expect(restoreCount == 1)
    }

    @Test func failedEnableDoesNotCreateLease() {
        var state = AppleRemoteHCILeaseState()

        #expect(throws: TestError.enableFailed) {
            try state.acquire { throw TestError.enableFailed }
        }
        #expect(state.activeLeaseCount == 0)
    }

    @Test func failedFinalRestoreKeepsLeaseForRetry() {
        var state = AppleRemoteHCILeaseState()
        state.acquire {}

        #expect(throws: TestError.restoreFailed) {
            try state.release { throw TestError.restoreFailed }
        }
        #expect(state.activeLeaseCount == 1)

        state.release {}
        #expect(state.activeLeaseCount == 0)
    }

    @Test func duplicateReleaseIsIdempotent() {
        var state = AppleRemoteHCILeaseState()
        var restoreCount = 0

        state.release { restoreCount += 1 }
        #expect(state.activeLeaseCount == 0)
        #expect(restoreCount == 0)
    }
}
#endif
