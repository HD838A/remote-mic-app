import Foundation
import Testing
@testable import RemoteMic

@Suite("Custom application launch plan")
struct CustomApplicationLaunchPlanTests {
    private static func profile() -> CustomApplicationProfile {
        CustomApplicationProfile(
            displayName: "Example Agent",
            bundleIdentifier: "com.example.agent",
            applicationPath: "/Applications/Example Agent.app",
            focusStrategy: .recordedAccessibility
        )
    }

    @Test func pendingVerificationStillAllowsOpeningTheApplication() {
        let url = URL(fileURLWithPath: "/Applications/Example Agent.app")
        #expect(CustomApplicationLaunchPlan.resolve(
            profile: Self.profile(),
            requiresVerification: true,
            applicationURL: url
        ) == .open(focusAllowed: false))
    }

    @Test func verifiedApplicationKeepsItsFocusStrategy() {
        let url = URL(fileURLWithPath: "/Applications/Example Agent.app")
        #expect(CustomApplicationLaunchPlan.resolve(
            profile: Self.profile(),
            requiresVerification: false,
            applicationURL: url
        ) == .open(focusAllowed: true))
    }

    @Test func missingProfileOrApplicationRemainsUnavailable() {
        let url = URL(fileURLWithPath: "/Applications/Example Agent.app")
        #expect(CustomApplicationLaunchPlan.resolve(
            profile: nil,
            requiresVerification: false,
            applicationURL: url
        ) == .unavailable)
        #expect(CustomApplicationLaunchPlan.resolve(
            profile: Self.profile(),
            requiresVerification: false,
            applicationURL: nil
        ) == .unavailable)
    }

    @Test func pendingCustomApplicationOpensWithoutFocusingItsInput() {
        let profile = Self.profile()
        var opened = 0
        var focused = 0

        let handled = KeyboardInjector.send(
            .openCustomApplication,
            applicationProfile: profile,
            focusCustomApplication: false,
            frontmostApplication: { ("com.example.frontmost", 99) },
            customApplicationURL: { _ in
                URL(fileURLWithPath: "/Applications/Example Agent.app")
            },
            customApplicationOpener: { _, _, completion in
                opened += 1
                completion(4_242, nil)
            },
            customApplicationFocuser: { _, _, _ in
                focused += 1
            }
        )

        #expect(handled)
        #expect(opened == 1)
        #expect(focused == 0)
    }
}
