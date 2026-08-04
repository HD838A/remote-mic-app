import XCTest
@testable import RemoteMicIOS

final class RemoteControlLayoutTests: XCTestCase {
    func testMiddleControlsKeepConfirmedTwoRowOrder() {
        XCTAssertEqual(
            RemoteControlScreen.middleControlRows.map { $0.map(\.command) },
            [
                [.back, .menu, .volumeUp],
                [.home, .television, .volumeDown],
            ]
        )
    }

    func testMiddleControlsKeepExpectedTitlesAndIcons() {
        XCTAssertEqual(
            RemoteControlScreen.middleControlRows,
            [
                [
                    .init(title: "返回", systemImage: "chevron.left", command: .back),
                    .init(title: "菜单", systemImage: "line.3.horizontal", command: .menu),
                    .init(title: "增大音量", systemImage: "speaker.plus.fill", command: .volumeUp),
                ],
                [
                    .init(title: "主页", systemImage: "house", command: .home),
                    .init(title: "TV", systemImage: "tv", command: .television),
                    .init(title: "减小音量", systemImage: "speaker.minus.fill", command: .volumeDown),
                ],
            ]
        )
    }
}
