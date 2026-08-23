import AppKit
import Foundation

enum StatusItemClickPolicy {
    static func opensMenu(
        isRightClick: Bool,
        showDockIcon: Bool,
        openMainWindowAtLaunch: Bool
    ) -> Bool {
        isRightClick || (!showDockIcon && !openMainWindowAtLaunch)
    }
}

struct StatusBarButtonActionSelection: Equatable {
    let button: RemoteButton
    let action: ButtonAction

    func apply(to settings: AppSettings) {
        settings.setAction(action, for: button, trigger: .singleClick)
    }
}

struct StatusBarButtonActionGroup: Equatable {
    let category: ButtonActionCategory
    let actions: [ButtonAction]
}

struct StatusBarButtonMappingMenuActions {
    let toggleMapping: Selector
    let selectRemoteProfile: Selector
    let selectButtonAction: Selector
    let openFullEditor: Selector
}

enum ButtonMappingPresentation {
    static func actionSummary(
        configured: ConfiguredButtonAction,
        customApplicationName: String?,
        using localization: LocalizationStore
    ) -> String {
        guard configured.action != .disabled else {
            return localization.text("button_mapping.action.not_set")
        }
        if configured.action == .customShortcut, let shortcut = configured.shortcut {
            return shortcut.displayName(using: localization)
        }
        if configured.action == .openCustomApplication {
            return customApplicationName
                ?? localization.text("custom_application.not_configured")
        }
        switch configured.action {
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .deleteBackward: return "⌫"
        case .volumeUp: return "+"
        case .volumeDown: return "−"
        case .volumeMute: return "Mute"
        default: return configured.action.displayName(using: localization)
        }
    }

    static func remoteDisplayName(
        _ profile: RemoteDeviceProfile,
        among profiles: [RemoteDeviceProfile],
        using localization: LocalizationStore
    ) -> String {
        let base = localization.text(profile.displayNameFallbackKey)
        let peers = profiles.filter { $0.model == profile.model }
        guard peers.count > 1,
              let index = peers.firstIndex(where: { $0.id == profile.id })
        else { return base }
        return "\(base) \(index + 1)"
    }
}

@MainActor
enum StatusBarButtonMappingMenuFactory {
    static func actionGroups(
        installedBundleIdentifiers: Set<String>,
        currentAction: ButtonAction,
        experimentalContinuousRecordingEnabled: Bool,
        hasConfiguredShortcut: Bool,
        hasConfiguredApplication: Bool
    ) -> [StatusBarButtonActionGroup] {
        let actions = ButtonAction.pickerActions(
            installedBundleIdentifiers: installedBundleIdentifiers,
            current: currentAction,
            experimentalContinuousRecordingEnabled: experimentalContinuousRecordingEnabled
        ).filter { action in
            guard action != .disabled else { return false }
            if action == .customShortcut {
                return hasConfiguredShortcut || currentAction == action
            }
            if action == .openCustomApplication {
                return hasConfiguredApplication || currentAction == action
            }
            return true
        }

        return ButtonActionCategory.allCases.compactMap { category in
            let groupedActions = actions.filter { $0.category == category }
            return groupedActions.isEmpty
                ? nil
                : StatusBarButtonActionGroup(category: category, actions: groupedActions)
        }
    }

    static func makeMenu(
        settings: AppSettings,
        connectedRemoteProfileIDs: Set<UUID>,
        localization: LocalizationStore,
        target: AnyObject,
        actions: StatusBarButtonMappingMenuActions,
        installedBundleIdentifiers: Set<String> = PresetApplication.installedBundleIdentifiers
    ) -> NSMenu {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: localization.text("button_mapping.toggle.enabled"),
            action: actions.toggleMapping,
            keyEquivalent: ""
        )
        toggleItem.target = target
        toggleItem.state = settings.customMappingEnabled ? .on : .off
        menu.addItem(toggleItem)

        addRemoteSelector(
            to: menu,
            settings: settings,
            connectedRemoteProfileIDs: connectedRemoteProfileIDs,
            localization: localization,
            target: target,
            action: actions.selectRemoteProfile
        )
        menu.addItem(.separator())

        for button in RemoteButton.allCases {
            menu.addItem(
                buttonMenuItem(
                    button,
                    settings: settings,
                    localization: localization,
                    target: target,
                    action: actions.selectButtonAction,
                    installedBundleIdentifiers: installedBundleIdentifiers
                )
            )
        }

        menu.addItem(.separator())
        let editorItem = NSMenuItem(
            title: localization.text("menu.button_mapping.open_full_editor"),
            action: actions.openFullEditor,
            keyEquivalent: ""
        )
        editorItem.target = target
        menu.addItem(editorItem)
        return menu
    }

    private static func addRemoteSelector(
        to menu: NSMenu,
        settings: AppSettings,
        connectedRemoteProfileIDs: Set<UUID>,
        localization: LocalizationStore,
        target: AnyObject,
        action: Selector
    ) {
        let profiles = settings.remoteDeviceProfiles.filter {
            connectedRemoteProfileIDs.contains($0.id)
        }
        guard !profiles.isEmpty else {
            let item = NSMenuItem(
                title: localization.text("menu.button_mapping.no_remote"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let remoteItem = NSMenuItem(
            title: localization.text("menu.button_mapping.remote"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        for profile in profiles {
            let item = NSMenuItem(
                title: ButtonMappingPresentation.remoteDisplayName(
                    profile,
                    among: settings.remoteDeviceProfiles,
                    using: localization
                ),
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = profile.id.uuidString
            item.state = profile.id == settings.selectedRemoteProfileID ? .on : .off
            submenu.addItem(item)
        }
        remoteItem.submenu = submenu
        menu.addItem(remoteItem)
    }

    private static func buttonMenuItem(
        _ button: RemoteButton,
        settings: AppSettings,
        localization: LocalizationStore,
        target: AnyObject,
        action: Selector,
        installedBundleIdentifiers: Set<String>
    ) -> NSMenuItem {
        let configured = settings.configuredAction(for: button, trigger: .singleClick)
        let customApplicationName = settings.customApplicationProfile(
            id: configured.applicationProfileID
        )?.displayName
        let summary = ButtonMappingPresentation.actionSummary(
            configured: configured,
            customApplicationName: customApplicationName,
            using: localization
        )
        let title = String(
            format: localization.text("menu.button_mapping.button_format"),
            locale: localization.locale,
            arguments: [button.shortLabel(using: localization), summary]
        )
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let isManagedPowerAction = button == .power &&
            settings.experimentalContinuousRecordingEnabled

        let disabledItem = mappedActionItem(
            title: localization.text("button_mapping.action.disable_switch"),
            button: button,
            action: .disabled,
            selectedAction: configured.action,
            isEnabled: !isManagedPowerAction,
            target: target,
            selector: action
        )
        submenu.addItem(disabledItem)
        submenu.addItem(.separator())

        let groups = actionGroups(
            installedBundleIdentifiers: installedBundleIdentifiers,
            currentAction: configured.action,
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled,
            hasConfiguredShortcut: configured.shortcut != nil,
            hasConfiguredApplication: settings.customApplicationProfile(
                id: configured.applicationProfileID
            ) != nil
        )
        for group in groups {
            let categoryItem = NSMenuItem(
                title: localization.text(group.category.localizationKey),
                action: nil,
                keyEquivalent: ""
            )
            let categoryMenu = NSMenu()
            for mappedAction in group.actions {
                categoryMenu.addItem(
                    mappedActionItem(
                        title: mappedAction.displayName(using: localization),
                        button: button,
                        action: mappedAction,
                        selectedAction: configured.action,
                        isEnabled: !isManagedPowerAction,
                        target: target,
                        selector: action
                    )
                )
            }
            categoryItem.submenu = categoryMenu
            submenu.addItem(categoryItem)
        }
        item.submenu = submenu
        return item
    }

    private static func mappedActionItem(
        title: String,
        button: RemoteButton,
        action: ButtonAction,
        selectedAction: ButtonAction,
        isEnabled: Bool,
        target: AnyObject,
        selector: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        item.representedObject = StatusBarButtonActionSelection(button: button, action: action)
        item.state = action == selectedAction ? .on : .off
        item.isEnabled = isEnabled
        return item
    }
}
