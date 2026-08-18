import Combine
import SwiftUI

#if canImport(SayAllMacroRemoteMic)
import SayAllMacroRemoteMic
#endif

enum ButtonProfileEditingRoutingPolicy {
    static func shouldPerformAction(isBindingEditorActive: Bool) -> Bool {
        !isBindingEditorActive
    }
}

enum ButtonProfileGlobalControlPolicy {
    static let reservedButton = RemoteButton.tv

    static func configuredAction(
        isEnabled: Bool,
        for button: RemoteButton
    ) -> ConfiguredButtonAction? {
        guard isEnabled, button == reservedButton else { return nil }
        return ConfiguredButtonAction(action: .appSwitcher, shortcut: nil)
    }
}

enum ButtonProfileHostActionCodec {
    static func encode(_ configured: ConfiguredButtonAction) -> Data? {
        try? JSONEncoder().encode(configured)
    }

    static func decode(_ payload: Data) -> ConfiguredButtonAction? {
        try? JSONDecoder().decode(ConfiguredButtonAction.self, from: payload)
    }
}

final class MacroFeatureIntegration: ObservableObject {
    @Published private(set) var isFeatureVisible = false
    @Published private(set) var shouldShowEnrollment = false
    @Published private(set) var isButtonProfileBindingEditorActive = false

#if canImport(SayAllMacroRemoteMic)
    private let feature: SayAllMacroRemoteMicFeature
    private var subscriptions = Set<AnyCancellable>()
    private var enrollmentRevealRequested = false
#endif

    init(localeIdentifier: String = Locale.current.identifier) {
        #if canImport(SayAllMacroRemoteMic)
        feature = SayAllMacroRemoteMicFeature(localeIdentifier: localeIdentifier)
        feature.$isFeatureVisible
            .removeDuplicates()
            .assign(to: &$isFeatureVisible)
        feature.$shouldShowEnrollment
            .removeDuplicates()
            .sink { [weak self] value in
                guard let self else { return }
                self.shouldShowEnrollment = value || self.enrollmentRevealRequested
            }
            .store(in: &subscriptions)
        feature.$isButtonProfileBindingEditorActive
            .removeDuplicates()
            .assign(to: &$isButtonProfileBindingEditorActive)
        #endif
    }

    var sectionTitle: String {
        #if canImport(SayAllMacroRemoteMic)
        feature.sectionTitle
        #else
        ""
        #endif
    }

    var buttonProfilesSectionTitle: String {
        #if canImport(SayAllMacroRemoteMic)
        feature.buttonProfilesSectionTitle
        #else
        ""
        #endif
    }

    var sectionSystemImage: String {
        #if canImport(SayAllMacroRemoteMic)
        feature.sectionSystemImage
        #else
        "command.square"
        #endif
    }

    var buttonProfilesSectionSystemImage: String {
        #if canImport(SayAllMacroRemoteMic)
        feature.buttonProfilesSectionSystemImage
        #else
        "rectangle.3.group"
        #endif
    }

    func updateLocaleIdentifier(_ identifier: String) {
        #if canImport(SayAllMacroRemoteMic)
        feature.updateLocaleIdentifier(identifier)
        objectWillChange.send()
        #endif
    }

    func refreshAccessIfNeeded(force: Bool = false) {
#if canImport(SayAllMacroRemoteMic)
        feature.refreshAccessIfNeeded(force: force)
#endif
    }

    func revealEnrollment() {
#if canImport(SayAllMacroRemoteMic)
        enrollmentRevealRequested = true
        shouldShowEnrollment = true
#endif
    }

    func settingsView(selectedRemoteProfileID: UUID?) -> AnyView {
        actionSequencesView(selectedRemoteProfileID: selectedRemoteProfileID)
    }

    func actionSequencesView(selectedRemoteProfileID: UUID?) -> AnyView {
        #if canImport(SayAllMacroRemoteMic)
        feature.actionSequencesView(selectedRemoteProfileID: selectedRemoteProfileID)
        #else
        AnyView(EmptyView())
        #endif
    }

    func buttonProfilesView(
        selectedRemoteProfileID: UUID?,
        settings: AppSettings,
        localization: LocalizationStore
    ) -> AnyView {
        #if canImport(SayAllMacroRemoteMic)
        feature.buttonProfilesView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            hostActionSections: hostActionSections(
                settings: settings,
                localization: localization
            )
        )
        #else
        AnyView(EmptyView())
        #endif
    }

    func enrollmentView() -> AnyView {
        #if canImport(SayAllMacroRemoteMic)
        feature.enrollmentView()
        #else
        AnyView(EmptyView())
        #endif
    }

    func hasActiveBinding(
        profileID: UUID?,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        #if canImport(SayAllMacroRemoteMic)
        feature.hasActiveBinding(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue
        )
        #else
        false
        #endif
    }

    func noteButtonInteraction(button: RemoteButton) {
        #if canImport(SayAllMacroRemoteMic)
        feature.noteButtonInteraction(button: button.rawValue)
        #endif
    }

    func globalControlAction(for button: RemoteButton) -> ConfiguredButtonAction? {
        ButtonProfileGlobalControlPolicy.configuredAction(
            isEnabled: isFeatureVisible,
            for: button
        )
    }

    @discardableResult
    func executeBoundMacro(
        profileID: UUID?,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        #if canImport(SayAllMacroRemoteMic)
        feature.executeBoundMacro(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue
        )
        #else
        false
        #endif
    }

    @discardableResult
    func executeBoundAction(
        profileID: UUID?,
        button: RemoteButton,
        trigger: ButtonTrigger,
        hostActionPerformer: (Data) -> Bool
    ) -> Bool {
        #if canImport(SayAllMacroRemoteMic)
        feature.executeBoundAction(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue,
            hostActionPerformer: hostActionPerformer,
            shortcutPerformer: { keyCode, modifiers in
                let handled = KeyboardInjector.sendRecordedShortcut(
                    keyCode: keyCode,
                    modifiers: modifiers
                )
                AppLogger.shared.write(
                    "BUTTON PROFILE shortcut key_code=\(keyCode) " +
                        "modifiers=\(modifiers.joined(separator: ",")) handled=\(handled)"
                )
                return handled
            }
        )
        #else
        false
        #endif
    }

    func stop() {
        #if canImport(SayAllMacroRemoteMic)
        feature.stop()
        #endif
    }

    #if canImport(SayAllMacroRemoteMic)
    func hostActionSections(
        settings: AppSettings,
        localization: LocalizationStore
    ) -> [RemoteMicHostActionSection] {
        var actionsByCategory = Dictionary(
            uniqueKeysWithValues: ButtonActionCategory.allCases.map { ($0, [RemoteMicHostActionDescriptor]()) }
        )
        let availableActions = ButtonAction.pickerActions(
            installedBundleIdentifiers: PresetApplication.installedBundleIdentifiers,
            current: .disabled,
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        )
        for action in availableActions where ![.customShortcut, .openCustomApplication].contains(action) {
            let configured = ConfiguredButtonAction(action: action, shortcut: nil)
            guard let payload = ButtonProfileHostActionCodec.encode(configured) else { continue }
            actionsByCategory[action.category, default: []].append(RemoteMicHostActionDescriptor(
                reference: RemoteMicHostActionReference(
                    id: action.rawValue,
                    displayName: action.displayName(using: localization),
                    payload: payload
                ),
                detail: action.presetApplication?.bundleIdentifier,
                systemImage: systemImage(for: action)
            ))
        }

        var savedShortcuts: [String: CustomKeyboardShortcut] = [:]
        for button in RemoteButton.allCases {
            for trigger in ButtonTrigger.allCases {
                let configured = settings.configuredAction(for: button, trigger: trigger)
                guard configured.action == .customShortcut, let shortcut = configured.shortcut else {
                    continue
                }
                let identifier = "customShortcut.\(shortcut.keyCode).\(shortcut.modifierFlagsRawValue)"
                savedShortcuts[identifier] = shortcut
            }
        }
        for (identifier, shortcut) in savedShortcuts.sorted(by: { $0.key < $1.key }) {
            let configured = ConfiguredButtonAction(action: .customShortcut, shortcut: shortcut)
            guard let payload = ButtonProfileHostActionCodec.encode(configured) else { continue }
            actionsByCategory[.custom, default: []].append(RemoteMicHostActionDescriptor(
                reference: RemoteMicHostActionReference(
                    id: identifier,
                    displayName: shortcut.displayName(using: localization),
                    payload: payload
                ),
                detail: localization.text("action.custom_shortcut"),
                systemImage: "command"
            ))
        }

        for profile in settings.customApplicationProfiles {
            let configured = ConfiguredButtonAction(
                action: .openCustomApplication,
                shortcut: nil,
                applicationProfileID: profile.id
            )
            guard let payload = ButtonProfileHostActionCodec.encode(configured) else { continue }
            actionsByCategory[.applications, default: []].append(RemoteMicHostActionDescriptor(
                reference: RemoteMicHostActionReference(
                    id: "customApplication.\(profile.id.uuidString.lowercased())",
                    displayName: profile.displayName,
                    payload: payload
                ),
                detail: profile.bundleIdentifier,
                systemImage: "app.badge"
            ))
        }

        return ButtonActionCategory.allCases.compactMap { category in
            let actions = actionsByCategory[category, default: []]
            guard !actions.isEmpty else { return nil }
            return RemoteMicHostActionSection(
                id: category.rawValue,
                title: localization.text(category.localizationKey),
                actions: actions
            )
        }
    }

    private func systemImage(for action: ButtonAction) -> String {
        if action == .disabled { return "nosign" }
        if action.presetApplication != nil { return "app" }
        switch action.category {
        case .basicKeys: return "keyboard"
        case .systemAndMedia: return "play.rectangle"
        case .custom: return "slider.horizontal.3"
        case .applications: return "app"
        }
    }
    #endif
}
