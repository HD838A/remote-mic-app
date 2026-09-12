import Combine
import SwiftUI

#if canImport(SayAllMacroRemoteMic)
import SayAllMacroRemoteMic
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
    @Published private(set) var shouldShowEnrollment = false
    @Published private(set) var isEditorActive = false

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
        #if canImport(SayAllMacroRemoteMic)
        feature.buttonProfilesSectionTitle
        #else
        ""
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

    func updateButtonProfilesAccess(_ decision: HostButtonProfilesAccessDecision) {
        #if canImport(SayAllMacroRemoteMic) && canImport(SayAllMembershipCore)
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
        feature.updateButtonProfilesAccess(packageDecision)
        #endif
    }

    func setEditorActive(_ active: Bool) {
        isEditorActive = active && isFeatureVisible
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
            remotePresentation: remotePresentation(for: remoteModel),
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
        #if canImport(SayAllMacroRemoteMic)
        #if SAYALL_MACRO_REMOTE_CAPABILITIES
        return feature.buttonProfilesView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            remotePresentation: remotePresentation(for: remoteModel),
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
        return feature.buttonProfilesView(
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
    private func remotePresentation(
        for model: XiaomiRemoteModel?
    ) -> RemoteMicRemotePresentation {
        switch model {
        case .rc001:
            return .xiaomiRC001(displayName: "RC001")
        case .rc003, .unknown, nil:
            return .xiaomiRC003(displayName: "RC003")
        case .appleSiriRemoteA2854, .appleSiriRemoteA2540:
            #if SAYALL_SIRI_REMOTE_ENABLED && canImport(SayAllSiriRemote)
            let siriModel: SayAllSiriRemoteModel = model == .appleSiriRemoteA2540
                ? .a2540
                : .a2854
            let source = SayAllSiriRemoteDevicePresentation.presentation(for: siriModel)
            let capabilities = RemoteMicRemoteModelCatalog.capabilities(
                for: source.model.stableModelID
            )!
            let anchors = Dictionary(uniqueKeysWithValues: source.anchors.compactMap {
                controlID, anchor in
                macroButton(forSiriControlID: controlID).map { ($0, anchor) }
            })
            return RemoteMicRemotePresentation(
                capabilities: capabilities,
                displayName: source.displayName,
                image: source.image,
                aspectRatio: source.aspectRatio,
                anchors: anchors
            )
            #else
            let modelID = model == .appleSiriRemoteA2540
                ? RemoteMicRemoteModelID.appleSiriRemoteA2540
                : RemoteMicRemoteModelID.appleSiriRemoteA2854
            return RemoteMicRemotePresentation(
                capabilities: RemoteMicRemoteModelCatalog.capabilities(for: modelID)!,
                displayName: "Siri Remote",
                image: nil,
                aspectRatio: 423.0 / 1510.0,
                anchors: [:]
            )
            #endif
        }
    }

    private func macroButton(forSiriControlID controlID: String) -> RemoteMicMacroButton? {
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
    #endif

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
        #if canImport(SayAllMacroRemoteMic)
        return feature.executeBoundAction(
            remoteProfileID: profileID,
            button: button.rawValue,
            trigger: trigger.rawValue,
            hostActionPerformer: hostActionPerformer,
            shortcutPerformer: shortcutPerformer
        )
        #else
        return false
        #endif
    }

    func stop() {
        #if canImport(SayAllMacroRemoteMic)
        feature.stop()
        #endif
    }
}
