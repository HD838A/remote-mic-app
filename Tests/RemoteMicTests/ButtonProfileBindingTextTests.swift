import Foundation
import Testing
@testable import RemoteMic

/// 按键页取方案文案的通路：接线不崩、语义正确。
///
/// 私有组件缺失或版本早于 `2.6.2` 时整块不参与编译，公开构建保持零依赖。
#if canImport(SayAllButtonProfiles) && SAYALL_BUTTON_PROFILE_BINDING_TEXT
@Suite("Button profile binding text")
@MainActor
struct ButtonProfileBindingTextTests {
    private func makeFeature() -> MacroFeatureIntegration {
        let feature = MacroFeatureIntegration()
        feature.updateButtonProfilesAccess(.allowed(validUntil: .distantFuture))
        return feature
    }

    /// 方案覆盖了按键时，按键页拿到的是非空文案，且完整形态比紧凑形态更长。
    @Test func coveredButtonReturnsCompactAndDetailedText() throws {
        let feature = makeFeature()
        let profile = try #require(feature.createMappingProfile(named: "Chrome"))
        var configured = ConfiguredButtonAction(action: .customShortcut, shortcut: nil)
        configured.action = .customShortcut
        configured.shortcut = CustomKeyboardShortcut(
            keyCode: 116, modifierFlags: [], keyLabel: "Page Up")
        feature.setProfileBinding(configured, profile: profile, button: .up,
            trigger: .singleClick, displayName: "Page Up")

        let text = try #require(feature.profileBindingText(
            device: nil, profile: profile, button: .up, trigger: .singleClick))
        #expect(!text.compact.isEmpty)
        #expect(!text.detailed.isEmpty)
    }

    /// 方案没有覆盖的按键必须返回 nil，由按键页回落到基础映射。
    @Test func uncoveredButtonReturnsNil() throws {
        let feature = makeFeature()
        let profile = try #require(feature.createMappingProfile(named: "Chrome"))
        #expect(feature.profileBindingText(
            device: nil, profile: profile, button: .menu, trigger: .singleClick) == nil)
    }
}
#endif
