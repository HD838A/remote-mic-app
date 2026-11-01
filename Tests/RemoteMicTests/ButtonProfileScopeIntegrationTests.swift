import Foundation
import Testing
@testable import RemoteMic

/// 按键页「保存为键位方案」依赖的适配层通路：建方案 → 写按住 → 回读 → 删除。
/// 私有组件缺失或未开启测试放行时不参与编译，公开构建保持零依赖。
#if canImport(SayAllButtonProfiles) && SAYALL_TEST_BUTTON_PROFILES_FREE
@Suite("Button profile scope integration")
@MainActor
struct ButtonProfileScopeIntegrationTests {
    @Test func createsWritesAndDeletesAScopeProfile() throws {
        let feature = MacroFeatureIntegration()
        // 测试放行宏会把任何决策强制改成 allowed。
        feature.updateButtonProfilesAccess(.allowed(validUntil: .distantFuture))
        let created = try #require(feature.createMappingProfile(named: "Snapshot"))
        #expect(feature.mappingProfiles(device: nil).contains { $0.id == created })
        #expect(feature.isMappingProfileEditable(created))

        feature.setProfileHoldMode(.repeatSingle, profile: created, button: .back)
        #expect(feature.profileHoldMode(profile: created, button: .back) == "repeatSingle")

        feature.deleteMappingProfile(created)
        #expect(!feature.mappingProfiles(device: nil).contains { $0.id == created })
    }

    @Test func reportedProfileButtonSupportMatchesTheTenKeyContract() {
        let feature = MacroFeatureIntegration()
        for button in [RemoteButton.up, .down, .left, .right, .ok, .back, .home, .volumeUp, .volumeDown, .power] {
            #expect(feature.supportsProfileButton(button.rawValue))
        }
    }
}
#endif

/// 「保存为键位方案」的覆盖名单必须在界面上点名具体按键。
/// 旧文案写「10 个普通按键」，用户无从知道是哪 10 个，也不知道菜单键不在其中。
@Suite("Button profile scope summary")
struct ButtonProfileScopeSummaryTests {
    @Test func mergesTheFourDirectionsIntoOneEntry() {
        let items = RemoteButton.profileScopeItems(for: [
            .power, .up, .down, .left, .right, .ok, .back, .home, .volumeUp, .volumeDown,
        ])
        #expect(items == [
            .button(.power), .directions, .button(.ok), .button(.back),
            .button(.home), .button(.volumeUp), .button(.volumeDown),
        ])
    }

    @Test func listsDirectionsIndividuallyWhenOnlySomeAreSupported() {
        #expect(RemoteButton.profileScopeItems(for: [.up, .ok]) == [.button(.up), .button(.ok)])
    }

    @Test func keepsUnorderedButtonsAtTheEnd() {
        #expect(RemoteButton.profileScopeItems(for: [.menu, .power]) == [.button(.power), .button(.menu)])
    }

    @Test func reportsNothingWhenNoButtonIsSupported() {
        #expect(RemoteButton.profileScopeItems(for: []).isEmpty)
    }

    @Test func reusesTheMappingPageSymbols() {
        #expect(RemoteButton.power.systemImage == "power")
        #expect(RemoteButton.ok.systemImage == "circle.circle")
        #expect(ButtonProfileScopeItem.directions.systemImage == "dpad")
    }
}
