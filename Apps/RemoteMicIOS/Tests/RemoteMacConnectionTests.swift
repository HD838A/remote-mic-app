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
    }
}
