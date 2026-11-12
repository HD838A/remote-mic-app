import Foundation
import Testing
@testable import RemoteMic

/// 按键页方案作用域的组合动作名必须取自宏库当前内容。
///
/// 键位方案组件自己持有一份宏库快照，只在启动时读取；组合动作改名后它仍是旧名字，
/// 命中不到还会退化成「原操作已不可用，请重新配置。」。这里锁住宿主的取值策略：
/// 按稳定 ID 从宏库现取名字，取不到时给宿主文案，不回落到方案组件的旧快照。
@Suite("Profile macro title")
struct ProfileMacroTitleTests {
    private let unavailable = "组合动作不可用，请重新选择"

    @Test func usesTheCurrentLibraryNameAfterRenaming() {
        let title = ProfileMacroTitle.resolve(
            macroID: "local.renamed",
            library: [ButtonLibraryAction(id: "local.renamed", name: "一键三连", stepCount: 3)],
            unavailable: unavailable
        )
        #expect(title == "一键三连")
    }

    @Test func fallsBackToTheHostMessageWhenTheMacroIsGone() {
        let title = ProfileMacroTitle.resolve(
            macroID: "local.deleted",
            library: [ButtonLibraryAction(id: "local.other", name: "另一个动作")],
            unavailable: unavailable
        )
        #expect(title == unavailable)
    }

    @Test func fallsBackWhenTheBindingHasNoMacroIdentifier() {
        #expect(
            ProfileMacroTitle.resolve(macroID: nil, library: [], unavailable: unavailable)
                == unavailable
        )
    }

    @Test func matchesByStableIdentifierInsteadOfName() {
        let library = [
            ButtonLibraryAction(id: "local.a", name: "同名"),
            ButtonLibraryAction(id: "local.b", name: "同名"),
        ]
        #expect(ProfileMacroTitle.resolve(macroID: "local.b", library: library, unavailable: unavailable) == "同名")
        #expect(ProfileMacroTitle.resolve(macroID: "local.c", library: library, unavailable: unavailable) == unavailable)
    }
}
