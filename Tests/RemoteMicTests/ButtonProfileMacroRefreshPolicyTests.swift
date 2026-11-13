import Foundation
import Testing
@testable import RemoteMic

/// 进入按键页和键位方案页时要重读组合动作库。
///
/// 键位方案页的绑定文案来自按键方案组件自己那份宏库快照。同一进程内改名由组件内部
/// 的通知刷新；跨进程写入（另一份安装包、测试包、配置恢复流程）收不到通知，
/// 宿主只能在进入这两个页面时主动重读一次。
@Suite("Button profile macro refresh policy")
struct ButtonProfileMacroRefreshPolicyTests {
    @Test func refreshesOnTheMappingPage() {
        #expect(ButtonProfileMacroRefreshPolicy.shouldRefresh(section: .mapping))
    }

    @Test func refreshesOnTheButtonProfilePage() {
        #expect(ButtonProfileMacroRefreshPolicy.shouldRefresh(section: .buttonProfiles))
    }

    @Test func doesNotRefreshOnOtherPages() {
        for section in SettingsSection.allCases {
            guard section != .mapping, section != .buttonProfiles else { continue }
            #expect(!ButtonProfileMacroRefreshPolicy.shouldRefresh(section: section))
        }
    }
}
