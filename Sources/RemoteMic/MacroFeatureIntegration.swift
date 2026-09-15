import Combine
import SwiftUI

#if canImport(SayAllMacroRemoteMic)
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
        #if canImport(SayAllButtonProfiles) && canImport(SayAllMembershipCore)
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
        configuredActionTitle: @escaping (String, String) -> String?
    ) -> AnyView {
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
        hostActionSections: [ButtonProfileHostActionSection]
    ) -> AnyView {
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
    }

    #if SAYALL_MACRO_REMOTE_CAPABILITIES && canImport(SayAllMacroRemoteMic)
    private func combinationActionsRemotePresentation(
        for model: XiaomiRemoteModel?
    ) -> SayAllMacroRemoteMic.RemoteMicRemotePresentation {
        switch model {
        case .rc001:
            return SayAllMacroRemoteMic.RemoteMicRemotePresentation.xiaomiRC001(displayName: "RC001")
        case .rc003, .unknown, nil:
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
        case .rc003, .unknown, nil:
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

    func hasActiveBinding(
        profileID: UUID?,
        button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        let freeBinding: Bool
        #if canImport(SayAllMacroRemoteMic)
        freeBinding = feature.hasActiveBinding(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue
        )
        #else
        freeBinding = false
        #endif
        #if canImport(SayAllButtonProfiles)
        return buttonProfilesFeature.hasActiveBinding(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue
        ) || freeBinding
        #else
        return freeBinding
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
    func executeBoundAction(
        profileID: UUID?,
        button: RemoteButton,
        trigger: ButtonTrigger,
        hostActionPerformer: (Data) -> Bool,
        shortcutPerformer: (UInt16, [String]) -> Bool
    ) -> Bool {
        #if canImport(SayAllButtonProfiles)
        if buttonProfilesFeature.executeBoundAction(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue,
            hostActionPerformer: hostActionPerformer,
            shortcutPerformer: shortcutPerformer
        ) {
            return true
        }
        #endif
        #if canImport(SayAllMacroRemoteMic)
        return feature.executeBoundMacro(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue
        )
        #else
        return false
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
