import Combine
import SwiftUI

#if canImport(SayAllMacroRemoteMic)
import SayAllMacroRemoteMic
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
        #if canImport(SayAllMacroRemoteMic)
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
        configuredActionTitle: @escaping (String, String) -> String?
    ) -> AnyView {
        #if canImport(SayAllMacroRemoteMic)
        feature.settingsView(
            selectedRemoteProfileID: selectedRemoteProfileID,
            configuredActionTitle: configuredActionTitle,
            onBindingEditorActivityChanged: { [weak self] active in
                self?.setEditorActive(active)
            }
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

    func buttonProfilesView(
        selectedRemoteProfileID: UUID?,
        hostActionSections: [ButtonProfileHostActionSection]
    ) -> AnyView {
        #if canImport(SayAllMacroRemoteMic)
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
        #else
        return AnyView(EmptyView())
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
