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

    func testForegroundRecoveryKeepsTheLastConnectedPresentationStable() {
        let transientStates: [RemoteMacConnection.State] = [
            .searching,
            .connecting,
            .awaitingApproval,
            .unavailable("连接已断开"),
        ]
        for state in transientStates {
            XCTAssertEqual(
                RemoteMacConnection.presentationState(
                    actual: state,
                    preservingConnected: true
                ),
                .connected
            )
            XCTAssertEqual(
                RemoteMacConnection.presentationState(
                    actual: state,
                    preservingConnected: false
                ),
                state
            )
        }
    }

    func testButtonTitlesSurviveConnectionResetUntilTheServerSnapshotArrives() {
        let cachedTitles = ["menu": "自定义菜单", "ok": "提交"]
        XCTAssertEqual(
            RemoteMacConnection.updatedButtonTitles(
                current: cachedTitles,
                event: .connectionReset
            ),
            cachedTitles
        )
        XCTAssertEqual(
            RemoteMacConnection.updatedButtonTitles(
                current: cachedTitles,
                event: .serverSnapshot(["menu": "新菜单"])
            ),
            ["menu": "新菜单"]
        )
        XCTAssertEqual(
            RemoteMacConnection.updatedButtonTitles(
                current: cachedTitles,
                event: .serverSnapshot([:])
            ),
            [:]
        )
    }

    func testFreshDiscoveryStartsOnTheLocalNetwork() {
        XCTAssertEqual(RemoteMacConnection.discoveryModeForFreshStart(), .localNetwork)
        XCTAssertFalse(RemoteMacConnection.DiscoveryMode.localNetwork.includesPeerToPeer)
        XCTAssertTrue(RemoteMacConnection.DiscoveryMode.peerToPeer.includesPeerToPeer)
    }

    func testLocalNetworkFallsBackToPeerToPeerAfterThreeSecondsWithoutResults() {
        XCTAssertEqual(
            RemoteMacConnection.nextDiscoveryStep(
                mode: .localNetwork,
                attempt: 0,
                state: .searching,
                hasResult: false
            ),
            .init(delaySeconds: 3, action: .switchToPeerToPeer)
        )
    }

    func testDiscoveryResultPreventsModeFallback() {
        XCTAssertNil(
            RemoteMacConnection.nextDiscoveryStep(
                mode: .localNetwork,
                attempt: 0,
                state: .searching,
                hasResult: true
            )
        )
    }

    func testActiveConnectionStatesDoNotChangeDiscoveryMode() {
        let states: [RemoteMacConnection.State] = [
            .connecting,
            .awaitingApproval,
            .connected,
            .connectedWithError("错误"),
            .awaitingLocalNetworkPermission,
            .unavailable("错误"),
        ]
        for state in states {
            XCTAssertNil(
                RemoteMacConnection.nextDiscoveryStep(
                    mode: .localNetwork,
                    attempt: 0,
                    state: state,
                    hasResult: false
                )
            )
        }
    }

    func testPeerToPeerDiscoveryRetriesWithAnUpperLimitThenShowsRecoveryGuidance() {
        XCTAssertEqual(
            RemoteMacConnection.nextDiscoveryStep(
                mode: .peerToPeer,
                attempt: 0,
                state: .searching,
                hasResult: false
            ),
            .init(delaySeconds: 2, action: .retryPeerToPeer)
        )
        XCTAssertEqual(
            RemoteMacConnection.nextDiscoveryStep(
                mode: .peerToPeer,
                attempt: 1,
                state: .searching,
                hasResult: false
            ),
            .init(delaySeconds: 5, action: .retryPeerToPeer)
        )
        XCTAssertEqual(
            RemoteMacConnection.nextDiscoveryStep(
                mode: .peerToPeer,
                attempt: 2,
                state: .searching,
                hasResult: false
            ),
            .init(delaySeconds: 5, action: .showRecoveryGuidance)
        )
        XCTAssertNil(
            RemoteMacConnection.nextDiscoveryStep(
                mode: .peerToPeer,
                attempt: 3,
                state: .searching,
                hasResult: false
            )
        )
    }

    func testDiscoveryRecoveryGuidanceExplainsWifiAndRestartSteps() {
        XCTAssertEqual(
            RemoteMacConnection.discoveryRecoveryGuidance,
            "iPhone 的附近设备发现暂时异常。请关闭并重新打开 Wi-Fi；仍无法连接时，请重启 iPhone。"
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
