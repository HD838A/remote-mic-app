import Combine
import SwiftUI

#if canImport(SayAllMacroRemoteMic)
import SayAllMacroRemoteMic
#endif

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
            configuredActionTitle: configuredActionTitle
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

    func stop() {
        #if canImport(SayAllMacroRemoteMic)
        feature.stop()
        #endif
    }
}
