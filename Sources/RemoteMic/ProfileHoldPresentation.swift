import Foundation

/// 键位方案页按住标签的解析结果。
///
/// 方案页浏览的方案和按键页正在编辑的方案可以不同，因此动作必须跟着
/// `profileID` 解析，不能读取 `editingMappingProfileID`。
struct ProfileHoldPresentation: Equatable {
    let mode: RemoteButtonHoldMode
    let action: ConfiguredButtonAction
    let isExplicit: Bool

    var rawMode: String { mode.rawValue }

    var trigger: ButtonTrigger {
        (mode == .repeatLong || mode == .longHold) ? .longPress : .singleClick
    }

    func summary(
        actionSummary: (ConfiguredButtonAction) -> String,
        text: (String) -> String
    ) -> String {
        guard mode != .once else {
            return text("button_mapping.hold.profile.once")
        }
        let prefixKey: String = switch mode {
        case .repeatSingle, .once: "button_mapping.hold.profile.repeat_prefix"
        case .repeatLong: "button_mapping.hold.profile.repeat_long_prefix"
        case .singleHold: "button_mapping.hold.profile.single_hold_prefix"
        case .longHold: "button_mapping.hold.profile.long_hold_prefix"
        }
        return text(prefixKey) + actionSummary(action)
    }
}

enum ProfileHoldPresentationResolver {
    static func resolve(
        button: RemoteButton,
        profileID: UUID?,
        profileMode: (UUID, RemoteButton) -> MappingDisplayValue<RemoteButtonHoldMode>,
        baseMode: (RemoteButton) -> RemoteButtonHoldMode?,
        profileAction: (UUID, RemoteButton, ButtonTrigger) -> ConfiguredButtonAction,
        baseAction: (RemoteButton, ButtonTrigger) -> ConfiguredButtonAction
    ) -> ProfileHoldPresentation? {
        func presentation(
            mode: RemoteButtonHoldMode?,
            isExplicit: Bool
        ) -> ProfileHoldPresentation? {
            guard let mode else { return nil }
            // 继承的基础 `.once` 表示没有按住效果，不应在方案页出现标签。
            guard isExplicit || mode != .once else { return nil }
            let trigger: ButtonTrigger = (mode == .repeatLong || mode == .longHold)
                ? .longPress
                : .singleClick
            let action = profileID.map {
                profileAction($0, button, trigger)
            } ?? baseAction(button, trigger)
            return ProfileHoldPresentation(mode: mode, action: action, isExplicit: isExplicit)
        }

        guard let profileID else {
            return presentation(mode: baseMode(button), isExplicit: false)
        }
        switch profileMode(profileID, button) {
        case let .explicit(mode):
            return presentation(mode: mode, isExplicit: true)
        case .inherited:
            return presentation(mode: baseMode(button), isExplicit: false)
        case .unavailable:
            return nil
        }
    }
}
