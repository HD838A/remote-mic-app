import Foundation

/// A host-owned binding. A missing profile override inherits this base value;
/// `.disabled` is an explicit value and never falls through to another action.
struct UnifiedButtonBinding: Codable, Equatable {
    var remoteProfileID: UUID?
    var button: RemoteButton
    var trigger: ButtonTrigger
    var configured: ConfiguredButtonAction
}

struct ButtonLibraryAction: Identifiable, Equatable {
    var id: String
    var name: String
    var stepCount: Int = 0
}

struct ButtonMappingProfile: Identifiable, Equatable {
    var id: UUID
    var name: String
}

/// 键位方案里一个组合动作绑定在按键页显示的名字。
///
/// 键位方案组件自己持有一份宏库快照，只在启动时读取；组合动作改名或新建后它不会刷新，
/// 卡片会一直显示旧名字，命中不到时还会退化成「原操作已不可用，请重新配置。」。
/// 方案作用域的组合动作因此统一从宏库当前内容取名，与基础映射保持同一来源；
/// 真找不到时给宿主的稳定文案，不把方案组件的旧快照当成结果。
enum ProfileMacroTitle {
    static func resolve(
        macroID: String?,
        library: [ButtonLibraryAction],
        unavailable: String
    ) -> String {
        guard let macroID else { return unavailable }
        return library.first { $0.id == macroID }?.name ?? unavailable
    }
}
