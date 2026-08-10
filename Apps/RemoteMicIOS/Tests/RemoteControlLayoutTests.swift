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
        XCTAssertEqual(
            MacAppInformationScreen.websiteDisplayText(for: .chinese),
            "https://8586ai.com"
        )
        XCTAssertEqual(
            MacAppInformationScreen.websiteDisplayText(for: .english),
            "https://8586ai.com/en"
        )
    }

    func testPublicTestFlightLinkRemainsStable() {
        XCTAssertEqual(MacAppInformationScreen.testFlightURL.scheme, "https")
        XCTAssertEqual(MacAppInformationScreen.testFlightURL.host, "testflight.apple.com")
        XCTAssertEqual(MacAppInformationScreen.testFlightURL.path, "/join/J8k8fb7v")
    }

    func testAppVersionTextIncludesMarketingVersionAndBuildNumber() {
        XCTAssertEqual(
            MacAppInformationScreen.appVersionText(marketingVersion: "0.8.8", buildNumber: "16"),
            "0.8.8 (16)"
        )
        XCTAssertEqual(
            MacAppInformationScreen.appVersionText(marketingVersion: "0.8.8", buildNumber: nil),
            "0.8.8"
        )
    }

    func testEnglishLocalizationContainsCoreRemoteCopy() {
        XCTAssertEqual(
            AppLanguage.english.text("开始录音"),
            "Start Recording"
        )
        XCTAssertEqual(
            AppLanguage.english.text("连接详情"),
            "Connection Details"
        )
        XCTAssertEqual(
            AppLanguage.english.text(RemoteMacConnection.discoveryRecoveryGuidance),
            "Nearby device discovery on this iPhone is temporarily unavailable. Turn Wi-Fi off and back on. If it still cannot connect, restart the iPhone."
        )
    }

    func testVoiceButtonSupportsTapToggleAndHoldToTalk() {
        var tap = VoiceButtonInteractionState()
        XCTAssertEqual(tap.press(at: 10, isVoiceRequested: false), .start)
        XCTAssertEqual(tap.release(at: 10.1), .none)
        XCTAssertTrue(tap.isLatched)
        XCTAssertEqual(tap.press(at: 11, isVoiceRequested: true), .stop)
        XCTAssertEqual(tap.release(at: 11.1), .none)

        var hold = VoiceButtonInteractionState()
        XCTAssertEqual(hold.press(at: 20, isVoiceRequested: false), .start)
        XCTAssertEqual(
            hold.release(at: 20 + VoiceButtonInteractionState.holdThreshold),
            .stop
        )
        XCTAssertFalse(hold.isLatched)
    }
}
