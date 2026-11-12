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

/// 组合动作页「使用此动作的位置」里方案条目的作用域名称。
///
/// 方案条目不能显示「基础映射」：那是基础映射作用域的文案，出现在方案条目上
/// 会让人以为这个动作配在基础映射里，而不是配在键位方案里。
enum MacroUsageScopeTitle {
    /// 方案绑在某个设备下时用设备名；没有设备时用键位方案的作用域名。
    static func profile(deviceName: String?, profileScopeLabel: String) -> String {
        deviceName ?? profileScopeLabel
    }

    /// 基础映射条目的作用域名称：绑定在某个设备下时是「设备 · 基础映射」，
    /// 没有设备归属时只留「基础映射」，不出现「基础映射 · 基础映射」。
    static func base(deviceName: String?, baseLabel: String) -> String {
        guard let deviceName else { return baseLabel }
        return deviceName + " · " + baseLabel
    }
}
