import Foundation
import Testing
@testable import RemoteMic

@Suite("SayAll Deep Link")
struct SayAllDeepLinkTests {
    @Test func acceptsLaunchAndWhitelistedVokieStatus() throws {
        let plain = try #require(SayAllDeepLinkRequest.parse(
            URL(string: "sayall://launch")!
        ))
        #expect(plain.source == nil)
        #expect(plain.status == nil)

        let callback = try #require(SayAllDeepLinkRequest.parse(
            URL(string: "sayall://launch?source=vokie&status=ready&reason=ok_1")!
        ))
        #expect(callback.source == "vokie")
        #expect(callback.status == .ready)
        #expect(callback.reason == "ok_1")
    }

    @Test func rejectsWrongEndpointAndDuplicateParameters() throws {
        #expect(SayAllDeepLinkRequest.parse(
            URL(string: "https://launch?source=vokie")!
        ) == nil)
        #expect(SayAllDeepLinkRequest.parse(
            URL(string: "sayall://other")!
        ) == nil)
        #expect(SayAllDeepLinkRequest.parse(
            URL(string: "sayall://launch?status=ready&status=failed")!
        ) == nil)
    }

    @Test func ignoresUntrustedValuesWithoutEchoingArbitraryText() throws {
        let request = try #require(SayAllDeepLinkRequest.parse(
            URL(string: "sayall://launch?source=attacker&status=owned&reason=Hello%20World")!
        ))
        #expect(request.source == nil)
        #expect(request.status == nil)
        #expect(request.reason == nil)
    }

    @Test func vokieLaunchDoesNotClaimShortcutSynchronization() throws {
        let plan = try #require(OnboardingVoicePairingPlan.resolve(
            tool: .vokie,
            controlSource: .xiaomiRemote
        ))
        let url = try #require(VokieDeepLink.launchURL(for: plan))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        #expect(items["action"] == "handsfree-ptt")
        #expect(items["shortcut"] == nil)
        #expect(items["microphoneId"] == nil)
    }
}
