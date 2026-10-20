#if SAYALL_MACRO_HOST_SHORTCUTS && canImport(SayAllMacroRemoteMic)
import CoreGraphics
import Testing
import SayAllMacroCore
@testable import RemoteMic

struct MacroShortcutDeliveryTests {
    @Test func macroBridgeUsesSameRightCommandTransactionAndFiltersNavigationFn() {
        var events: [CGEvent] = []
        let result = MacroFeatureIntegration.performKeyboardShortcut(
            keyCode: 37, modifiers: ["command"], deviceModifierFlags: 0x10,
            accessibilityTrusted: { true }, shortcutSender: { shortcut in
                KeyboardInjector.send(.customShortcut, shortcut: shortcut,
                    accessibilityTrusted: { true },
                    shortcutEventPoster: { events.append($0); return true },
                    shortcutHardwareFlags: { CGEventFlags(rawValue: 0x00A0_0100) })
            })
        if case .userResultUnknown = result {} else { Issue.record("Submission must retain unknown target result") }
        #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [54, 37, 37, 54])
        #expect(events.allSatisfy { !$0.flags.contains(.maskSecondaryFn) })
        #expect(events.last?.flags.isEmpty == true)
    }

    @Test func macroBridgeRejectsInvalidDataAndPermissionAndReportsDeliveryFailure() {
        #expect(MacroFeatureIntegration.performKeyboardShortcut(
            keyCode: 37, modifiers: ["command"], deviceModifierFlags: 0,
            accessibilityTrusted: { false }, shortcutSender: { _ in
                Issue.record("Denied request must not send"); return true
            }) == .permissionDenied("需要辅助功能权限"))
        #expect(MacroFeatureIntegration.performKeyboardShortcut(
            keyCode: 37, modifiers: ["unknown"], deviceModifierFlags: 0,
            accessibilityTrusted: { true }, shortcutSender: { _ in
                Issue.record("Invalid request must not send"); return true
            }) == .failed("快捷键配置无效"))
        #expect(MacroFeatureIntegration.performKeyboardShortcut(
            keyCode: 11, modifiers: ["command", "option"], deviceModifierFlags: 0,
            accessibilityTrusted: { true }, shortcutSender: { _ in false }) == .failed("快捷键投递失败"))
    }
}
#endif
