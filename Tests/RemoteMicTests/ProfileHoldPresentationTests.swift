import Foundation
import Testing
@testable import RemoteMic

@Suite("Profile hold presentation")
struct ProfileHoldPresentationTests {
    private let profileID = UUID()
    private let profileAction = ConfiguredButtonAction(action: .arrowDown, shortcut: nil)
    private let baseAction = ConfiguredButtonAction(action: .arrowUp, shortcut: nil)

    private func resolve(
        mode: MappingDisplayValue<RemoteButtonHoldMode>,
        baseMode: RemoteButtonHoldMode? = .once
    ) -> ProfileHoldPresentation? {
        ProfileHoldPresentationResolver.resolve(
            button: .up,
            profileID: profileID,
            profileMode: { _, _ in mode },
            baseMode: { _ in baseMode },
            profileAction: { _, _, _ in profileAction },
            baseAction: { _, _ in baseAction }
        )
    }

    @Test func explicitProfileHoldUsesTheViewedProfileAction() {
        let presentation = resolve(mode: .explicit(.repeatSingle), baseMode: .repeatLong)
        #expect(presentation?.mode == .repeatSingle)
        #expect(presentation?.action == profileAction)
    }

    @Test func inheritedBaseHoldUsesTheViewedProfileAction() {
        let presentation = resolve(mode: .inherited, baseMode: .repeatSingle)
        #expect(presentation?.mode == .repeatSingle)
        #expect(presentation?.action == profileAction)
    }

    @Test func inheritedBaseOnceHasNoHoldTag() {
        #expect(resolve(mode: .inherited, baseMode: .once) == nil)
    }

    @Test func explicitOnceStillShowsHoldTag() {
        let presentation = resolve(mode: .explicit(.once), baseMode: .repeatSingle)
        #expect(presentation?.mode == .once)
        #expect(presentation?.summary(actionSummary: { _ in "↑" }, text: { key in
            key == "button_mapping.hold.profile.once" ? "按住" : key
        }) == "按住")
    }

    @Test func unavailableHoldModeHasNoHoldTag() {
        #expect(resolve(mode: .unavailable, baseMode: .repeatSingle) == nil)
    }

    @Test func summaryUsesCompactProfileWordingAndViewedProfileAction() {
        let presentation = resolve(mode: .explicit(.repeatSingle), baseMode: .once)
        let summary = presentation?.summary(
            actionSummary: { $0.action == .arrowDown ? "↓" : "↑" },
            text: { key in
                switch key {
                case "button_mapping.hold.profile.repeat_prefix": "按住：重复 "
                default: key
                }
            }
        )
        #expect(summary == "按住：重复 ↓")
    }
}
