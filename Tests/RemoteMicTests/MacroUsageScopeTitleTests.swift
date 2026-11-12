import Foundation
import Testing
@testable import RemoteMic

/// 组合动作页「使用此动作的位置」里方案条目的作用域名称。
///
/// 方案条目不能显示「基础映射」：那是基础映射作用域的文案，出现在方案条目上
/// 会让人以为这个动作配在基础映射里，而不是配在键位方案里。
@Suite("Macro usage scope title")
struct MacroUsageScopeTitleTests {
    @Test func usesTheProfileScopeLabelWhenTheProfileHasNoDevice() {
        #expect(
            MacroUsageScopeTitle.profile(deviceName: nil, profileScopeLabel: "键位方案") == "键位方案"
        )
    }

    @Test func keepsTheDeviceNameWhenTheProfileBelongsToADevice() {
        #expect(
            MacroUsageScopeTitle.profile(deviceName: "小米蓝牙遥控器 2", profileScopeLabel: "键位方案")
                == "小米蓝牙遥控器 2"
        )
    }

    @Test func neverFallsBackToTheBaseMappingLabel() {
        let scope = MacroUsageScopeTitle.profile(deviceName: nil, profileScopeLabel: "键位方案")
        #expect(scope != "基础映射")
        #expect(scope != "Default Mapping")
    }
}
