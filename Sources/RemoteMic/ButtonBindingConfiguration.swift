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
