import XCTest
@testable import RemoteMicIOS

final class RemoteCommandTests: XCTestCase {
    func testConfigurableCommandsUseExpectedWireNames() {
        let mappings: [(RemoteCommand, String)] = [
            (.power, "power"),
            (.up, "up"),
            (.down, "down"),
            (.left, "left"),
            (.right, "right"),
            (.confirm, "ok"),
            (.back, "back"),
            (.home, "home"),
            (.menu, "menu"),
            (.television, "tv"),
            (.volumeUp, "volume_up"),
            (.volumeDown, "volume_down"),
        ]

        for (command, wireName) in mappings {
            XCTAssertEqual(command.wireName, wireName)
        }
    }

    func testLocalOnlyCommandsAreNotSentAsButtonCommands() {
        XCTAssertNil(RemoteCommand.chooseDevice.wireName)
        XCTAssertNil(RemoteCommand.voiceStart.wireName)
        XCTAssertNil(RemoteCommand.voiceStop.wireName)
    }

    func testCustomTitlesResolveForEveryConfigurableButton() {
        let titles = [
            "power": "1",
            "up": "2",
            "down": "3",
            "left": "4",
            "right": "5",
            "ok": "6",
            "back": "7",
            "home": "8",
            "menu": "9",
            "tv": "10",
            "volume_up": "11",
            "volume_down": "12",
        ]
        let commands: [RemoteCommand] = [
            .power, .up, .down, .left, .right, .confirm,
            .back, .home, .menu, .television, .volumeUp, .volumeDown,
        ]

        for (index, command) in commands.enumerated() {
            XCTAssertEqual(
                RemoteMacConnection.buttonTitle(for: command, in: titles),
                String(index + 1)
            )
        }
        XCTAssertNil(RemoteMacConnection.buttonTitle(for: .voiceStart, in: titles))
    }

    func testEveryConfigurableButtonSendsPressAndReleaseEventsToSupportedMacs() throws {
        let commands: [RemoteCommand] = [
            .power, .up, .down, .left, .right, .confirm,
            .back, .home, .menu, .television, .volumeUp, .volumeDown,
        ]

        for command in commands {
            let press = try XCTUnwrap(RemoteMacConnection.buttonMessage(
                for: command,
                phase: .press,
                supportsButtonEvents: true
            ))
            let release = try XCTUnwrap(RemoteMacConnection.buttonMessage(
                for: command,
                phase: .release,
                supportsButtonEvents: true
            ))

            XCTAssertEqual(press.type, "buttonEvent")
            XCTAssertEqual(press.command, command.wireName)
            XCTAssertEqual(press.buttonPhase, "press")
            XCTAssertEqual(release.type, "buttonEvent")
            XCTAssertEqual(release.command, command.wireName)
            XCTAssertEqual(release.buttonPhase, "release")
        }
    }

    func testLegacyMacReceivesOneSingleClickCommandOnRelease() throws {
        XCTAssertNil(RemoteMacConnection.buttonMessage(
            for: .power,
            phase: .press,
            supportsButtonEvents: false
        ))
        let release = try XCTUnwrap(RemoteMacConnection.buttonMessage(
            for: .power,
            phase: .release,
            supportsButtonEvents: false
        ))
        XCTAssertEqual(release.type, "command")
        XCTAssertEqual(release.command, "power")
        XCTAssertNil(release.buttonPhase)
    }

    @MainActor
    func testPrimaryPressCommandsUseEmphasizedHaptics() {
        XCTAssertEqual(RemoteCommand.confirm.hapticStrength, .emphasized)
        XCTAssertEqual(RemoteCommand.power.hapticStrength, .emphasized)
        XCTAssertEqual(RemoteCommand.voiceStart.hapticStrength, .emphasized)
    }

    @MainActor
    func testVoiceReleaseUsesReleaseHaptic() {
        XCTAssertEqual(RemoteCommand.voiceStop.hapticStrength, .release)
    }

    @MainActor
    func testRegularRemoteButtonsUseStandardHaptics() {
        let commands: [RemoteCommand] = [
            .chooseDevice, .up, .down, .left, .right,
            .back, .home, .menu, .television, .volumeUp, .volumeDown,
        ]

        for command in commands {
            XCTAssertEqual(command.hapticStrength, .standard)
        }
    }
}
