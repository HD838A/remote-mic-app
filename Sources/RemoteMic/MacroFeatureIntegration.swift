import Combine
import SwiftUI

#if canImport(SayAllMacroRemoteMic)
import SayAllMacroCore
import SayAllMacroRemoteMic
#endif
#if canImport(SayAllButtonProfiles)
import SayAllButtonProfiles
#endif
#if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
import SayAllSiriRemote
#endif

struct ButtonProfileHostAction: Equatable {
    let id: String
    let title: String
    let detail: String?
    let systemImage: String
    let payload: Data
    let isAvailable: Bool
}

struct ButtonProfileHostActionSection: Equatable {
    let id: String
    let title: String
    let actions: [ButtonProfileHostAction]
}

final class MacroFeatureIntegration: ObservableObject {
    @Published private(set) var isFeatureVisible = false
    @Published private(set) var isButtonProfilesVisible = false
    @Published private(set) var shouldShowEnrollment = false
    @Published private(set) var isEditorActive = false
    private var subscriptions = Set<AnyCancellable>()
    private var enrollmentRevealRequested = false

#if canImport(SayAllMacroRemoteMic)
    private let feature: SayAllMacroRemoteMicFeature
#endif
#if canImport(SayAllButtonProfiles)
    private let buttonProfilesFeature: SayAllButtonProfilesFeature
#endif

    init(localeIdentifier: String = Locale.current.identifier) {
        #if canImport(SayAllMacroRemoteMic)
        feature = SayAllMacroRemoteMicFeature(localeIdentifier: localeIdentifier)
        #endif
#if canImport(SayAllButtonProfiles)
        buttonProfilesFeature = SayAllButtonProfilesFeature(
            localeIdentifier: localeIdentifier
        )
#endif
        #if canImport(SayAllMacroRemoteMic)
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
        #endif
#if canImport(SayAllButtonProfiles)
        isButtonProfilesVisible = true
        buttonProfilesFeature.$isButtonProfileBindingEditorActive
            .removeDuplicates()
            .sink { [weak self] active in
                self?.setEditorActive(active)
            }
            .store(in: &subscriptions)
#endif
    }

    var libraryActions: [ButtonLibraryAction] {
        #if canImport(SayAllMacroRemoteMic) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        feature.libraryActions.map { ButtonLibraryAction(id: $0.id, name: $0.name) }
        #else
        []
        #endif
    }

    func mappingProfiles(device: UUID?) -> [ButtonMappingProfile] {
        #if canImport(SayAllButtonProfiles) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        buttonProfilesFeature.profiles(for: device).map { ButtonMappingProfile(id: $0.id, name: buttonProfilesFeature.profileDisplayName($0)) }
        #else
        []
        #endif
    }

    func prepareMappingDevice(_ device: UUID?) {
        #if canImport(SayAllButtonProfiles) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        buttonProfilesFeature.prepareMappingDevice(device)
        #endif
    }

    func activeMappingProfileID(device: UUID?) -> UUID? {
        #if canImport(SayAllButtonProfiles) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        buttonProfilesFeature.activeProfileID(for: device)
        #else
        nil
        #endif
    }

    func profileBinding(device: UUID?, profile: UUID? = nil, button: RemoteButton,
                        trigger: ButtonTrigger) -> ConfiguredButtonAction? {
        #if canImport(SayAllButtonProfiles) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        guard let binding = buttonProfilesFeature.binding(device: device, profile: profile,
            button: button.rawValue, trigger: trigger.rawValue) else { return nil }
        switch binding {
        case let .host(reference):
            // Corrupt or unknown explicit bindings are consumed, never inherited.
            return (try? JSONDecoder().decode(ConfiguredButtonAction.self, from: reference.payload)) ?? .disabled
        case let .macro(reference):
            return ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: reference.macroID)
        case let .shortcut(key):
            guard let shortcut = buttonProfilesFeature.shortcut(id: key) else { return .disabled }
            var flags: NSEvent.ModifierFlags = []
            for modifier in shortcut.modifiers {
                switch modifier {
                case "command": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "option": flags.insert(.option)
                case "control": flags.insert(.control)
                case "function": flags.insert(.function)
                default: return .disabled
                }
            }
            return ConfiguredButtonAction(action: .customShortcut,
                shortcut: CustomKeyboardShortcut(keyCode: shortcut.keyCode, modifierFlags: flags, keyLabel: ""))
        }
        #else
        return nil
        #endif
    }

    func setProfileBinding(_ configured: ConfiguredButtonAction?, profile: UUID,
                           button: RemoteButton, trigger: ButtonTrigger, displayName: String? = nil) {
        #if canImport(SayAllButtonProfiles) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        let binding: RemoteMicButtonProfileBinding?
        if let configured {
            if configured.action == .combinationAction, let id = configured.macroID,
               let version = feature.savedMacroVersion(id: id) {
                binding = .macro(MacroReference(macroID: id, version: version))
            } else {
                guard let data = try? JSONEncoder().encode(configured) else { return }
                binding = .host(RemoteMicHostActionReference(id: "host.action.\(configured.action.rawValue)",
                    displayName: displayName ?? configured.action.rawValue, payload: data))
            }
        } else { binding = nil }
        buttonProfilesFeature.setBinding(binding, profile: profile, button: button.rawValue, trigger: trigger.rawValue)
        #endif
    }

    func executeMacro(id: String?) -> Bool {
        #if canImport(SayAllMacroRemoteMic) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        guard let id else { return false }
        let accepted = feature.executeMacro(id: id)
        AppLogger.shared.write("BUTTON ACTION phase=\(accepted ? "submitted" : "failed") result=\(accepted ? "accepted" : "unavailable_or_busy")")
        return accepted
        #else
        return false
        #endif
    }

    func attachBindings(to settings: AppSettings, onProfileChange: @escaping (UUID?) -> Void) {
        settings.configuredActionOverride = { [weak self, weak settings] device, button, trigger in
            guard let settings, settings.customMappingEnabled else { return nil }
            return self?.profileBinding(device: device, button: button, trigger: trigger)
        }
        #if canImport(SayAllMacroRemoteMic) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        feature.executionEvents.receive(on: DispatchQueue.main).sink { event in
            AppLogger.shared.write("MACRO ACTION operation_id=\(event.0) phase=\(event.1) result=\(event.2) elapsed_ms=\(event.3)")
        }.store(in: &subscriptions)
        feature.changes.receive(on: DispatchQueue.main).sink { [weak self, weak settings] in
            guard let self, let settings else { return }
            DispatchQueue.main.async {
                guard self.feature.hasLoadedLibrary else { return }
                let legacy = self.feature.legacyBindings.compactMap { value -> UnifiedButtonBinding? in
                    guard let button = RemoteButton(rawValue: value.button),
                          let trigger = ButtonTrigger(rawValue: value.trigger) else { return nil }
                    return UnifiedButtonBinding(remoteProfileID: value.device, button: button, trigger: trigger,
                        configured: ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: value.macroID))
                }
                do { try settings.migrateLegacyMacroBindings(legacy) }
                catch { AppLogger.shared.write("BUTTON CONFIGURATION phase=failed result=migration_backup_failed") }
                self.objectWillChange.send()
            }
        }.store(in: &subscriptions)
        #endif
        #if canImport(SayAllButtonProfiles) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
        var lastActiveProfiles: [UUID?: UUID] = [:]
        buttonProfilesFeature.changes.receive(on: DispatchQueue.main).sink { [weak self, weak settings] in
            DispatchQueue.main.async {
                guard let self, let settings else { return }
                let devices: [UUID?] = [nil] + settings.remoteDeviceProfiles.map { Optional($0.id) }
                for device in devices {
                    let active = self.activeMappingProfileID(device: device)
                    if active != lastActiveProfiles[device] {
                        lastActiveProfiles[device] = active
                        onProfileChange(device)
                    }
                }
                self.objectWillChange.send()
                settings.objectWillChange.send()
            }
        }.store(in: &subscriptions)
        #endif
    }

    #if canImport(SayAllMacroRemoteMic) && SAYALL_UNIFIED_BUTTON_CONFIGURATION
    private func bindingUsages(_ settings: AppSettings) -> [RemoteMicBindingUsage] {
        let localization = LocalizationStore(settings: settings)
        func deviceName(_ id: UUID?) -> String {
            guard let profile = settings.remoteDeviceProfiles.first(where: { $0.id == id }) else {
                return localization.text("button_mapping.base_profile")
            }
            return RemoteDeviceNamePolicy.displayName(for: profile, among: settings.remoteDeviceProfiles,
                defaultName: localization.text(profile.displayNameFallbackKey))
        }
        var usages = settings.unifiedBaseBindings.compactMap { binding -> RemoteMicBindingUsage? in
            guard binding.configured.action == .combinationAction, let id = binding.configured.macroID else { return nil }
            return RemoteMicBindingUsage(
                id: "base.\(binding.remoteProfileID?.uuidString ?? "default").\(binding.button.rawValue).\(binding.trigger.rawValue)",
                macroID: id, title: deviceName(binding.remoteProfileID) + " · " + localization.text("button_mapping.base_profile") + " · " + binding.button.displayName(using: localization) + " · " + binding.trigger.displayName(using: localization),
                device: binding.remoteProfileID, profile: nil, button: binding.button.rawValue, trigger: binding.trigger.rawValue)
        }
        #if canImport(SayAllButtonProfiles)
        for profile in buttonProfilesFeature.allProfiles {
            for (key, binding) in profile.bindings {
                let id: String?
                switch binding {
                case let .macro(reference): id = reference.macroID
                case let .host(reference):
                    let configured = try? JSONDecoder().decode(ConfiguredButtonAction.self, from: reference.payload)
                    id = configured?.action == .combinationAction ? configured?.macroID : nil
                case .shortcut: id = nil
                }
                guard let id else { continue }
                usages.append(RemoteMicBindingUsage(id: "\(profile.id).\(key.button.rawValue).\(key.trigger.rawValue)",
                    macroID: id, title: deviceName(profile.remoteProfileID) + " · " + buttonProfilesFeature.profileDisplayName(profile) + " · " + (RemoteButton(rawValue: key.button.rawValue)?.displayName(using: localization) ?? key.button.rawValue) + " · " + (ButtonTrigger(rawValue: key.trigger.rawValue)?.displayName(using: localization) ?? key.trigger.rawValue),
                    device: profile.remoteProfileID, profile: profile.id, button: key.button.rawValue, trigger: key.trigger.rawValue))
            }
        }
        #endif
        return usages
    }
    #endif

    var sectionTitle: String {
        #if canImport(SayAllMacroRemoteMic)
        feature.sectionTitle
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

    var buttonProfilesSectionTitle: String {
        #if canImport(SayAllButtonProfiles)
        buttonProfilesFeature.buttonProfilesSectionTitle
        #else
        ""
        #endif
    }

    var buttonProfilesSectionSystemImage: String {
        #if canImport(SayAllButtonProfiles)
        buttonProfilesFeature.buttonProfilesSectionSystemImage
        #else
        "rectangle.3.group"
        #endif
    }

    func updateLocaleIdentifier(_ identifier: String) {
        #if canImport(SayAllMacroRemoteMic)
        feature.updateLocaleIdentifier(identifier)
        objectWillChange.send()
        #endif
        #if canImport(SayAllButtonProfiles)
        buttonProfilesFeature.updateLocaleIdentifier(identifier)
        objectWillChange.send()
        #endif
    }

    func refreshAccessIfNeeded(force: Bool = false) {
#if canImport(SayAllMacroRemoteMic)
        feature.refreshAccessIfNeeded(force: force)
#endif
#if canImport(SayAllButtonProfiles)
        buttonProfilesFeature.refreshAccessIfNeeded(force: force)
#endif
    }

    func updateButtonProfilesAccess(_ decision: HostButtonProfilesAccessDecision) {
        #if canImport(SayAllButtonProfiles)
        #if SAYALL_TEST_BUTTON_PROFILES_FREE
        buttonProfilesFeature.updateButtonProfilesAccess(
            .allowed(validUntil: .distantFuture)
        )
        #else
        let packageDecision: ButtonProfilesAccessDecision
        switch decision {
        case let .allowed(validUntil):
            packageDecision = .allowed(validUntil: validUntil)
        case let .temporarilyOffline(validUntil):
            packageDecision = .temporarilyOffline(validUntil: validUntil)
        case .requiresPlus:
            packageDecision = .requiresPlus
        case .unavailable:
            packageDecision = .unavailable
        }
        buttonProfilesFeature.updateButtonProfilesAccess(packageDecision)
        #endif
        #endif
    }

    func setEditorActive(_ active: Bool) {
        isEditorActive = active && (isFeatureVisible || isButtonProfilesVisible)
    }

    func revealEnrollment() {
#if canImport(SayAllMacroRemoteMic)
        enrollmentRevealRequested = true
        shouldShowEnrollment = true
#endif
    }

    func settingsView(
        selectedRemoteProfileID: UUID?,
        remoteModel: XiaomiRemoteModel?,
        configuredActionTitle: @escaping (String, String) -> String?,
        settings: AppSettings? = nil,
        onEditBinding: @escaping (UUID?, UUID?, RemoteButton, ButtonTrigger) -> Void = { _, _, _, _ in }
    ) -> AnyView {
        #if SAYALL_UNIFIED_BUTTON_CONFIGURATION && canImport(SayAllMacroRemoteMic)
        return feature.settingsView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            remotePresentation: combinationActionsRemotePresentation(for: remoteModel),
            configuredActionTitle: configuredActionTitle,
            usages: settings.map(bindingUsages) ?? [],
            onEditBinding: { usage in
                guard let button = RemoteButton(rawValue: usage.button),
                      let trigger = ButtonTrigger(rawValue: usage.trigger) else { return }
                onEditBinding(usage.device, usage.profile, button, trigger)
            })
        #else

        #if canImport(SayAllMacroRemoteMic)
        #if SAYALL_MACRO_REMOTE_CAPABILITIES
        feature.settingsView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            remotePresentation: combinationActionsRemotePresentation(for: remoteModel),
            configuredActionTitle: configuredActionTitle,
            onBindingEditorActivityChanged: { [weak self] active in
                self?.setEditorActive(active)
            }
        )
        #else
        feature.settingsView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            configuredActionTitle: configuredActionTitle,
            onBindingEditorActivityChanged: { [weak self] active in
                self?.setEditorActive(active)
            }
        )
        #endif
        #else
        AnyView(EmptyView())
        #endif
        #endif
    }

    func enrollmentView() -> AnyView {
        #if canImport(SayAllMacroRemoteMic)
        feature.enrollmentView()
        #else
        AnyView(EmptyView())
        #endif
    }

    func buttonProfilesView(
        selectedRemoteProfileID: UUID?,
        remoteModel: XiaomiRemoteModel?,
        hostActionSections: [ButtonProfileHostActionSection],
        onEditKeys: @escaping (UUID) -> Void = { _ in }
    ) -> AnyView {
        #if SAYALL_UNIFIED_BUTTON_CONFIGURATION && canImport(SayAllButtonProfiles)
        return buttonProfilesFeature.buttonProfilesView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            remotePresentation: buttonProfilesRemotePresentation(for: remoteModel),
            hostActionSections: [],
            onEditKeys: onEditKeys)
        #else

        #if canImport(SayAllButtonProfiles)
        #if SAYALL_MACRO_REMOTE_CAPABILITIES
        return buttonProfilesFeature.buttonProfilesView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            remotePresentation: buttonProfilesRemotePresentation(for: remoteModel),
            hostActionSections: hostActionSections.map { section in
                RemoteMicHostActionSection(
                    id: section.id,
                    title: section.title,
                    actions: section.actions.map { action in
                        RemoteMicHostActionDescriptor(
                            reference: RemoteMicHostActionReference(
                                id: action.id,
                                displayName: action.title,
                                payload: action.payload
                            ),
                            detail: action.detail,
                            systemImage: action.systemImage,
                            isAvailable: action.isAvailable
                        )
                    }
                )
            }
        )
        #else
        return buttonProfilesFeature.buttonProfilesView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            hostActionSections: hostActionSections.map { section in
                RemoteMicHostActionSection(
                    id: section.id,
                    title: section.title,
                    actions: section.actions.map { action in
                        RemoteMicHostActionDescriptor(
                            reference: RemoteMicHostActionReference(
                                id: action.id,
                                displayName: action.title,
                                payload: action.payload
                            ),
                            detail: action.detail,
                            systemImage: action.systemImage,
                            isAvailable: action.isAvailable
                        )
                    }
                )
            }
        )
        #endif
        #else
        return AnyView(EmptyView())
        #endif
        #endif
    }

    #if SAYALL_MACRO_REMOTE_CAPABILITIES && canImport(SayAllMacroRemoteMic)
    private func combinationActionsRemotePresentation(
        for model: XiaomiRemoteModel?
    ) -> SayAllMacroRemoteMic.RemoteMicRemotePresentation {
        switch model {
        case .rc001:
            return SayAllMacroRemoteMic.RemoteMicRemotePresentation.xiaomiRC001(displayName: "RC001")
        case .rc003, .chromecastVoiceRemote, .unknown, nil:
            return SayAllMacroRemoteMic.RemoteMicRemotePresentation.xiaomiRC003(displayName: "RC003")
        case .appleSiriRemoteA2854, .appleSiriRemoteA2540:
            #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
            let siriModel: SayAllSiriRemoteModel = model == .appleSiriRemoteA2540
                ? .a2540
                : .a2854
            let source = SayAllSiriRemoteDevicePresentation.presentation(for: siriModel)
            let capabilities = SayAllMacroRemoteMic.RemoteMicRemoteModelCatalog.capabilities(
                for: source.model.stableModelID
            )!
            let anchors = Dictionary(uniqueKeysWithValues: source.anchors.compactMap {
                controlID, anchor in
                combinationActionsMacroButton(forSiriControlID: controlID).map { ($0, anchor) }
            })
            return SayAllMacroRemoteMic.RemoteMicRemotePresentation(
                capabilities: capabilities,
                displayName: source.displayName,
                image: source.image,
                aspectRatio: source.aspectRatio,
                anchors: anchors
            )
            #else
            let modelID = model == .appleSiriRemoteA2540
                ? SayAllMacroRemoteMic.RemoteMicRemoteModelID.appleSiriRemoteA2540
                : SayAllMacroRemoteMic.RemoteMicRemoteModelID.appleSiriRemoteA2854
            return SayAllMacroRemoteMic.RemoteMicRemotePresentation(
                capabilities: SayAllMacroRemoteMic.RemoteMicRemoteModelCatalog.capabilities(for: modelID)!,
                displayName: "Siri Remote",
                image: nil,
                aspectRatio: 423.0 / 1510.0,
                anchors: [:]
            )
            #endif
        }
    }

    private func combinationActionsMacroButton(
        forSiriControlID controlID: String
    ) -> SayAllMacroRemoteMic.RemoteMicMacroButton? {
        switch controlID {
        case "power": .power
        case "up": .up
        case "left": .left
        case "select": .ok
        case "right": .right
        case "down": .down
        case "back": .back
        case "tv": .tv
        case "play_pause": .playPause
        case "volume_up": .volumeUp
        case "mute": .mute
        case "volume_down": .volumeDown
        default: nil
        }
    }

    #if canImport(SayAllButtonProfiles)
    private func buttonProfilesRemotePresentation(
        for model: XiaomiRemoteModel?
    ) -> SayAllButtonProfiles.RemoteMicRemotePresentation {
        switch model {
        case .rc001:
            return .xiaomiRC001(displayName: "RC001")
        case .rc003, .chromecastVoiceRemote, .unknown, nil:
            return .xiaomiRC003(displayName: "RC003")
        case .appleSiriRemoteA2854, .appleSiriRemoteA2540:
            let modelID = model == .appleSiriRemoteA2540
                ? SayAllButtonProfiles.RemoteMicRemoteModelID.appleSiriRemoteA2540
                : SayAllButtonProfiles.RemoteMicRemoteModelID.appleSiriRemoteA2854
            return SayAllButtonProfiles.RemoteMicRemotePresentation(
                capabilities: SayAllButtonProfiles.RemoteMicRemoteModelCatalog.capabilities(
                    for: modelID
                )!,
                displayName: "Siri Remote",
                image: nil,
                aspectRatio: 423.0 / 1510.0,
                anchors: [:]
            )
        }
    }
    #endif
    #endif

    func hasActiveBinding(profileID: UUID?, button: RemoteButton, trigger: ButtonTrigger) -> Bool {
        #if SAYALL_UNIFIED_BUTTON_CONFIGURATION
        return false
        #else
        #if canImport(SayAllButtonProfiles)
        if buttonProfilesFeature.hasActiveBinding(remoteProfileID: profileID, button: button.rawValue, trigger: trigger.rawValue) { return true }
        #endif
        #if canImport(SayAllMacroRemoteMic)
        return feature.hasActiveBinding(remoteProfileID: profileID, button: button.rawValue, trigger: trigger.rawValue)
        #else
        return false
        #endif
        #endif
    }

    func noteButtonInteraction(button: RemoteButton) {
#if canImport(SayAllMacroRemoteMic)
        feature.noteButtonInteraction(button: button.rawValue)
#endif
#if canImport(SayAllButtonProfiles)
        buttonProfilesFeature.noteButtonInteraction(button: button.rawValue)
#endif
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
    func executeBoundAction(profileID: UUID?, button: RemoteButton, trigger: ButtonTrigger,
                           hostActionPerformer: (Data) -> Bool,
                           shortcutPerformer: (UInt16, [String]) -> Bool) -> Bool {
        #if SAYALL_UNIFIED_BUTTON_CONFIGURATION
        return false
        #else
        #if canImport(SayAllButtonProfiles)
        if buttonProfilesFeature.executeBoundAction(remoteProfileID: profileID, button: button.rawValue,
            trigger: trigger.rawValue, hostActionPerformer: hostActionPerformer, shortcutPerformer: shortcutPerformer) { return true }
        #endif
        return executeBoundMacro(profileID: profileID, button: button, trigger: trigger)
        #endif
    }

    func stop() {
#if canImport(SayAllMacroRemoteMic)
        feature.stop()
#endif
#if canImport(SayAllButtonProfiles)
        buttonProfilesFeature.stop()
#endif
    }
}
