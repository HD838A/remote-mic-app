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

    func testLanguageDefaultsToPreferredSystemLanguageUntilUserSelectsOne() {
        XCTAssertEqual(
            AppLanguage.resolve(storedValue: nil, preferredLanguages: ["zh-Hans-CN"]),
            .chinese
        )
        XCTAssertEqual(
            AppLanguage.resolve(storedValue: "", preferredLanguages: ["en-US"]),
            .english
        )
        XCTAssertEqual(
            AppLanguage.resolve(storedValue: AppLanguage.english.rawValue, preferredLanguages: ["zh-Hans-CN"]),
            .english
        )
    }

    func testWebsiteFollowsSelectedAppLanguage() {
        XCTAssertEqual(
            MacAppInformationScreen.websiteURL(for: .chinese).absoluteString,
            "https://8586ai.com/"
        )
        XCTAssertEqual(
            MacAppInformationScreen.websiteURL(for: .english).absoluteString,
            "https://8586ai.com/en/"
        )
    }

    func testPublicTestFlightLinkRemainsStable() {
        XCTAssertEqual(MacAppInformationScreen.testFlightURL.scheme, "https")
        XCTAssertEqual(MacAppInformationScreen.testFlightURL.host, "testflight.apple.com")
        XCTAssertEqual(MacAppInformationScreen.testFlightURL.path, "/join/J8k8fb7v")
    }

    func testEnglishLocalizationContainsCoreRemoteCopy() {
        XCTAssertEqual(
            AppLanguage.english.text("按住说话"),
            "Hold to Talk"
        )
        XCTAssertEqual(
            AppLanguage.english.text("连接详情"),
            "Connection Details"
        )
    }
}
