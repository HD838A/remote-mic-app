import CryptoKit
import XCTest
@testable import RemoteMicIOS

final class RemoteMacConnectionTests: XCTestCase {
    func testActivationRestartsOnlyAfterTerminalDiscoveryFailure() {
        XCTAssertFalse(RemoteMacConnection.State.searching.shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(RemoteMacConnection.State.connecting.shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(RemoteMacConnection.State.awaitingApproval.shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(RemoteMacConnection.State.connected.shouldRestartDiscoveryOnActivation)
        XCTAssertFalse(RemoteMacConnection.State.connectedWithError("错误").shouldRestartDiscoveryOnActivation)
        XCTAssertTrue(RemoteMacConnection.State.awaitingLocalNetworkPermission.shouldRestartDiscoveryOnActivation)
        XCTAssertTrue(RemoteMacConnection.State.unavailable("错误").shouldRestartDiscoveryOnActivation)
    }

    func testDiscoveryRetryOnlyRebuildsAStuckSearchWithAnUpperLimit() {
        XCTAssertEqual(
            RemoteMacConnection.discoveryRetryDelaySeconds(attempt: 0, state: .searching),
            2
        )
        XCTAssertEqual(
            RemoteMacConnection.discoveryRetryDelaySeconds(attempt: 1, state: .searching),
            5
        )
        XCTAssertNil(RemoteMacConnection.discoveryRetryDelaySeconds(attempt: 2, state: .searching))
        XCTAssertNil(RemoteMacConnection.discoveryRetryDelaySeconds(attempt: 0, state: .connecting))
        XCTAssertNil(RemoteMacConnection.discoveryRetryDelaySeconds(attempt: 0, state: .awaitingApproval))
        XCTAssertNil(RemoteMacConnection.discoveryRetryDelaySeconds(attempt: 0, state: .connected))
        XCTAssertNil(
            RemoteMacConnection.discoveryRetryDelaySeconds(
                attempt: 0,
                state: .awaitingLocalNetworkPermission
            )
        )
    }

    func testKnownMacOperationErrorsBecomeActionableMessages() {
        XCTAssertEqual(
            RemoteMacConnection.userFacingOperationError("Mac 需要辅助功能权限，或该按键当前不可用。"),
            "请在 Mac 的“系统设置 > 隐私与安全性 > 辅助功能”中允许无线麦，或检查该按键配置"
        )
        XCTAssertEqual(
            RemoteMacConnection.userFacingOperationError("Mac 的语音输出当前不可用。"),
            "Mac 的语音输出当前不可用，请检查辅助功能权限和虚拟麦克风后重试"
        )
        XCTAssertEqual(
            RemoteMacConnection.userFacingOperationError("unexpected"),
            "Mac 暂时无法执行这个操作，请稍后重试"
        )
        XCTAssertEqual(
            RemoteMacConnection.userFacingOperationError(nil),
            "Mac 暂时无法执行这个操作，请稍后重试"
        )
    }

    func testPairingCodeAlwaysUsesExactlyTwoDigits() {
        XCTAssertEqual(
            RemoteMacConnection.pairingCode(for: SymmetricKey(data: Data(repeating: 0, count: 32))),
            "00"
        )

        var seven = Data(repeating: 0, count: 32)
        seven[3] = 7
        XCTAssertEqual(RemoteMacConnection.pairingCode(for: SymmetricKey(data: seven)), "07")

        var fortyTwo = Data(repeating: 0, count: 32)
        fortyTwo[3] = 42
        XCTAssertEqual(RemoteMacConnection.pairingCode(for: SymmetricKey(data: fortyTwo)), "42")
    }
}
