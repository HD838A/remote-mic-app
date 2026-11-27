import AppKit
import CoreGraphics

/// 用户拖到过的 HUD 位置。只记录归一化坐标，换显示器或改分辨率后按比例还原，
/// 不做像素级复刻。
struct ActionFeedbackPlacement: Codable, Equatable, Sendable {
    var normalizedX: Double
    var normalizedY: Double
}

/// 按显示器分别记住 HUD 位置。
///
/// 位置属于本机使用习惯，不进入可导出的便携配置：换一台 Mac 时默认落点仍然
/// 是底部居中，不会把 A 机的位置带到屏幕布局不同的 B 机。
struct ActionFeedbackPlacementStore {
    static let defaultsKey = "actionFeedback.hudPlacement.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func placement(displayID: CGDirectDisplayID) -> ActionFeedbackPlacement? {
        entries()[Self.key(for: displayID)]
    }

    func save(_ placement: ActionFeedbackPlacement, displayID: CGDirectDisplayID) {
        var current = entries()
        current[Self.key(for: displayID)] = placement
        guard let data = try? JSONEncoder().encode(current) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// 显示器不在当前布局中时返回 nil，由调用方回退到默认位置。
    private func entries() -> [String: ActionFeedbackPlacement] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode(
                  [String: ActionFeedbackPlacement].self,
                  from: data
              )
        else { return [:] }
        return decoded
    }

    private static func key(for displayID: CGDirectDisplayID) -> String {
        String(displayID)
    }
}

extension NSScreen {
    /// 公开的显示器编号，只用于本机位置记忆，不写入日志。
    var actionFeedbackDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
