import Foundation

/// One entry in the function panel. The panel only draws a large icon and a name;
/// every other detail stays out of the floating strip.
struct FunctionPanelItem: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let configuredAction: ConfiguredButtonAction
    let unavailableReasonKey: String?
    let unavailableReasonText: String?

    var isAvailable: Bool { unavailableReasonKey == nil }
}

struct FunctionPanelMacro: Equatable {
    let id: String
    let name: String
    let stepCount: Int
}

struct FunctionPanelCatalogEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let systemImage: String
    let configuredAction: ConfiguredButtonAction
    let detail: String?
}

struct FunctionPanelCatalogSection: Identifiable, Equatable {
    let id: String
    let title: String
    let entries: [FunctionPanelCatalogEntry]
}

/// Localized strings used by the panel and the favorites sheet. Keeping this a
/// plain value type lets the ordering and dedupe rules run without a window.
struct FunctionPanelText {
    let actionTitle: (ButtonAction) -> String
    let macroTitle: (String) -> String
    let configuredTitle: (ConfiguredButtonAction) -> String
    let categoryTitle: (ButtonActionCategory) -> String
    let combinationTitle: String
    let commonPhrasesTitle: String
    let macroStepCount: (Int) -> String
    let reasonText: (String) -> String
}

/// Availability checks are pure inputs. The app model supplies permission and
/// installation state; tests supply their own values.
struct FunctionPanelAvailability {
    var accessibilityTrusted: Bool
    var membershipAvailable: Bool
    var experimentalRecordingEnabled: Bool
    var installedBundleIdentifiers: Set<String>
    var customApplicationExists: (UUID?) -> Bool
    var customApplicationInstalled: (UUID?) -> Bool
    var macroAvailable: (String) -> Bool
    var macroFeatureVisible: Bool

    func reasonKey(for configured: ConfiguredButtonAction) -> String? {
        let action = configured.action
        if action == .disabled || action == .openFunctionPanel {
            return "function_panel.unavailable.disabled"
        }
        if action == .combinationAction {
            guard let macroID = configured.macroID else {
                return "function_panel.unavailable.macro_deleted"
            }
            if macroAvailable(macroID) { return nil }
            return macroFeatureVisible
                ? "function_panel.unavailable.macro_deleted"
                : "function_panel.unavailable.macro_unavailable"
        }
        if action == .toggleLongRecording, !experimentalRecordingEnabled {
            return "function_panel.unavailable.disabled"
        }
        if action == .openCommonPhrases, !membershipAvailable {
            return "function_panel.unavailable.membership"
        }
        if action == .customShortcut, configured.shortcut == nil {
            return "function_panel.unavailable.shortcut_missing"
        }
        if action == .openCustomApplication {
            if !customApplicationExists(configured.applicationProfileID) {
                return "function_panel.unavailable.app_not_set"
            }
            if !customApplicationInstalled(configured.applicationProfileID) {
                return "function_panel.unavailable.app_missing"
            }
            return nil
        }
        if let application = action.presetApplication,
           !installedBundleIdentifiers.contains(application.bundleIdentifier) {
            return "function_panel.unavailable.app_missing"
        }
        if action == .focusInput, !accessibilityTrusted {
            return "function_panel.unavailable.focus_input"
        }
        if Self.requiresAccessibility(action), !accessibilityTrusted {
            return "function_panel.unavailable.accessibility"
        }
        return nil
    }

    static func requiresAccessibility(_ action: ButtonAction) -> Bool {
        if action == .disabled ||
            action == .openCommonPhrases ||
            action == .openFunctionPanel ||
            action == .toggleLongRecording ||
            action == .openCustomApplication ||
            action == .combinationAction ||
            action.presetApplication != nil {
            return false
        }
        return true
    }
}

enum FunctionPanelCatalog {
    static let actionPrefix = "action:"
    static let macroPrefix = "macro:"

    static func actionID(_ action: ButtonAction) -> String {
        actionPrefix + action.rawValue
    }

    static func macroID(_ id: String) -> String {
        macroPrefix + id
    }

    static func id(for configured: ConfiguredButtonAction) -> String {
        switch configured.action {
        case .combinationAction:
            return macroID(configured.macroID ?? "")
        case .customShortcut:
            let key = configured.shortcut.map {
                "\($0.keyCode):\($0.modifierFlags.rawValue)"
            } ?? "unset"
            return actionPrefix + "customShortcut:" + key
        case .openCustomApplication:
            return actionPrefix + "openCustomApplication:" +
                (configured.applicationProfileID?.uuidString ?? "unset")
        default:
            return actionID(configured.action)
        }
    }

    /// Actions that can live in the panel without a key binding. Shortcut and
    /// custom-app entries are binding-specific, so they stay in the configured list
    /// and cannot be added to the global favorites.
    static func favoritableActions(experimentalRecordingEnabled: Bool) -> [ButtonAction] {
        ButtonAction.allCases.filter { action in
            switch action {
            case .disabled, .combinationAction, .customShortcut,
                 .openCustomApplication, .openFunctionPanel:
                return false
            case .toggleLongRecording:
                return experimentalRecordingEnabled
            default:
                return true
            }
        }
    }

    static func systemImage(for action: ButtonAction) -> String {
        switch action {
        case .combinationAction: return "square.stack.3d.up"
        case .openCommonPhrases: return "text.quote"
        case .openFunctionPanel: return "rectangle.3.group"
        case .customShortcut: return "keyboard"
        case .openCustomApplication: return "app.badge"
        case .focusInput: return "scope"
        case .showDesktop: return "macwindow"
        case .appSwitcher: return "command"
        case .commandCopy: return "doc.on.doc"
        case .commandPaste: return "doc.on.clipboard"
        case .commandCut: return "scissors"
        case .commandUndo: return "arrow.uturn.backward"
        case .commandRedo: return "arrow.uturn.forward"
        case .commandFind: return "magnifyingglass"
        case .commandSave: return "square.and.arrow.down"
        case .commandDelete: return "trash"
        case .commandClose: return "xmark.square"
        case .commandQuit: return "power"
        case .commandSelectAll: return "selection.pin.in.out"
        case .commandMinimize: return "minus.square"
        case .toggleFullScreen: return "arrow.up.left.and.arrow.down.right"
        case .commandNewTab: return "plus.square.on.square"
        case .commandPreviousTab, .commandNextTab: return "arrow.left.arrow.right"
        case .commandNextWindow: return "macwindow.on.rectangle"
        case .commandHide: return "eye.slash"
        case .commandNew: return "plus.rectangle"
        case .arrowUp: return "arrow.up"
        case .arrowDown: return "arrow.down"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        case .scrollUp: return "scroll"
        case .scrollDown: return "scroll"
        case .pageUp, .pageUpHalf: return "arrow.up.doc"
        case .pageDown, .pageDownHalf: return "arrow.down.doc"
        case .scrollToTop: return "arrow.up.to.line"
        case .scrollToBottom: return "arrow.down.to.line"
        case .deleteBackward: return "delete.left"
        case .contextMenu: return "filemenu.and.selection"
        case .missionControl: return "rectangle.3.group"
        case .applicationWindows: return "rectangle.on.rectangle"
        case .spaceLeft, .spaceRight: return "rectangle.split.2x1"
        case .lockScreen: return "lock"
        case .screenshot: return "camera.viewfinder"
        case .volumeUp, .volumeDown, .volumeMute: return "speaker.wave.2"
        case .playPause: return "playpause"
        case .previousCommandLeft: return "backward.end"
        case .nextCommandRight: return "forward.end"
        case .returnKey, .commandReturn, .shiftReturn: return "return"
        case .escape: return "escape"
        case .toggleLongRecording: return "record.circle"
        default:
            return action.presetApplication == nil ? "keyboard" : "app"
        }
    }

    static func favoriteSections(
        macros: [FunctionPanelMacro],
        text: FunctionPanelText,
        availability: FunctionPanelAvailability
    ) -> [FunctionPanelCatalogSection] {
        let actions = favoritableActions(
            experimentalRecordingEnabled: availability.experimentalRecordingEnabled
        )
        var sections: [FunctionPanelCatalogSection] = []
        for category in ButtonActionCategory.allCases {
            if category == .combinations {
                guard !macros.isEmpty else { continue }
                let entries = macros.map { macro in
                    FunctionPanelCatalogEntry(
                        id: macroID(macro.id),
                        title: text.macroTitle(macro.name),
                        systemImage: systemImage(for: .combinationAction),
                        configuredAction: ConfiguredButtonAction(
                            action: .combinationAction,
                            shortcut: nil,
                            macroID: macro.id
                        ),
                        detail: text.macroStepCount(macro.stepCount)
                    )
                }
                sections.append(FunctionPanelCatalogSection(
                    id: category.rawValue,
                    title: text.categoryTitle(category),
                    entries: entries
                ))
                continue
            }
            let grouped = actions.filter { $0.category == category }
            guard !grouped.isEmpty else { continue }
            let entries = grouped.map { action in
                FunctionPanelCatalogEntry(
                    id: actionID(action),
                    title: text.actionTitle(action),
                    systemImage: systemImage(for: action),
                    configuredAction: ConfiguredButtonAction(
                        action: action,
                        shortcut: nil
                    ),
                    detail: nil
                )
            }
            sections.append(FunctionPanelCatalogSection(
                id: category.rawValue,
                title: text.categoryTitle(category),
                entries: entries
            ))
        }
        return sections
    }

    static func items(
        favoriteIDs: [String],
        configuredActions: [ConfiguredButtonAction],
        macros: [FunctionPanelMacro],
        text: FunctionPanelText,
        availability: FunctionPanelAvailability
    ) -> [FunctionPanelItem] {
        let favoriteSet = Set(favoriteIDs)
        var result: [FunctionPanelItem] = []
        var seen = Set<String>()

        let sections = favoriteSections(
            macros: macros,
            text: text,
            availability: availability
        )
        for entry in sections.flatMap(\.entries) where favoriteSet.contains(entry.id) {
            guard seen.insert(entry.id).inserted else { continue }
            result.append(item(
                id: entry.id,
                title: entry.title,
                systemImage: entry.systemImage,
                configured: entry.configuredAction,
                text: text,
                availability: availability
            ))
        }

        // A favorite can outlive its macro. Keep it visible and explain the
        // failure when the user presses OK instead of silently dropping it.
        for id in favoriteIDs where !seen.contains(id) && id.hasPrefix(macroPrefix) {
            seen.insert(id)
            let macroID = String(id.dropFirst(macroPrefix.count))
            result.append(item(
                id: id,
                title: text.combinationTitle,
                systemImage: systemImage(for: .combinationAction),
                configured: ConfiguredButtonAction(
                    action: .combinationAction,
                    shortcut: nil,
                    macroID: macroID
                ),
                text: text,
                availability: availability
            ))
        }

        for configured in configuredActions {
            let id = id(for: configured)
            guard id != actionID(.openFunctionPanel),
                  !favoriteSet.contains(id),
                  seen.insert(id).inserted else { continue }
            result.append(item(
                id: id,
                title: text.configuredTitle(configured),
                systemImage: systemImage(for: configured.action),
                configured: configured,
                text: text,
                availability: availability
            ))
        }

        for macro in macros {
            let id = macroID(macro.id)
            guard !favoriteSet.contains(id), seen.insert(id).inserted else { continue }
            result.append(item(
                id: id,
                title: text.macroTitle(macro.name),
                systemImage: systemImage(for: .combinationAction),
                configured: ConfiguredButtonAction(
                    action: .combinationAction,
                    shortcut: nil,
                    macroID: macro.id
                ),
                text: text,
                availability: availability
            ))
        }
        return result
    }

    static func orderedFavoriteIDs(
        from selection: Set<String>,
        sections: [FunctionPanelCatalogSection]
    ) -> [String] {
        let catalogIDs = sections.flatMap(\.entries).map(\.id)
        let known = Set(catalogIDs)
        var result = catalogIDs.filter { selection.contains($0) }
        result.append(contentsOf: selection.subtracting(known).sorted())
        return result
    }

    private static func item(
        id: String,
        title: String,
        systemImage: String,
        configured: ConfiguredButtonAction,
        text: FunctionPanelText,
        availability: FunctionPanelAvailability
    ) -> FunctionPanelItem {
        let reasonKey = availability.reasonKey(for: configured)
        return FunctionPanelItem(
            id: id,
            title: title,
            systemImage: systemImage,
            configuredAction: configured,
            unavailableReasonKey: reasonKey,
            unavailableReasonText: reasonKey.map(text.reasonText)
        )
    }
}
