import Combine
import SwiftUI

#if canImport(SayAllAI)
import SayAllAI
#endif

final class PrivateFeatureIntegration: ObservableObject {
    @Published private(set) var isFeatureVisible = false
    @Published private(set) var shouldShowEnrollment = false
    @Published private(set) var hudShouldBeVisible = false

    #if canImport(SayAllAI)
    private let feature: SayAllAIFeature
    private var hudController: SayAllAIHUDController?
    private var subscriptions = Set<AnyCancellable>()
    #endif

    init(localeIdentifier: String = Locale.current.identifier) {
        #if canImport(SayAllAI)
        feature = SayAllAIFeature(
            localeIdentifier: localeIdentifier,
            logger: { AppLogger.shared.write($0) }
        )
        feature.$isFeatureVisible
            .removeDuplicates()
            .assign(to: &$isFeatureVisible)
        feature.$shouldShowEnrollment
            .removeDuplicates()
            .assign(to: &$shouldShowEnrollment)
        feature.$hudShouldBeVisible
            .removeDuplicates()
            .assign(to: &$hudShouldBeVisible)
        #endif
    }

    var sectionTitle: String {
        #if canImport(SayAllAI)
        feature.sectionTitle
        #else
        ""
        #endif
    }

    var isAvailable: Bool {
        #if canImport(SayAllAI)
        true
        #else
        false
        #endif
    }

    var sectionSystemImage: String {
        #if canImport(SayAllAI)
        feature.sectionSystemImage
        #else
        "sparkles"
        #endif
    }

    func updateLocaleIdentifier(_ identifier: String) {
        #if canImport(SayAllAI)
        feature.updateLocaleIdentifier(identifier)
        objectWillChange.send()
        #endif
    }

    func settingsView() -> AnyView {
        #if canImport(SayAllAI)
        AnyView(SayAllAISettingsView(feature: feature))
        #else
        AnyView(EmptyView())
        #endif
    }

    func enrollmentView() -> AnyView {
        #if canImport(SayAllAI)
        AnyView(SayAllAIEnrollmentView(feature: feature))
        #else
        AnyView(EmptyView())
        #endif
    }

    func refreshAccessIfNeeded(force: Bool = false) {
        #if canImport(SayAllAI)
        feature.refreshAccessIfNeeded(force: force)
        #endif
    }

    func startVoiceSession() {
        #if canImport(SayAllAI)
        feature.startVoiceSession()
        #endif
    }

    func finishVoiceSession() {
        #if canImport(SayAllAI)
        feature.finishVoiceSession()
        #endif
    }

    func stop() {
        #if canImport(SayAllAI)
        feature.stop()
        #endif
    }

    @MainActor
    func setHUDVisible(_ visible: Bool) {
        #if canImport(SayAllAI)
        if visible {
            let controller = hudController ?? SayAllAIHUDController(feature: feature)
            hudController = controller
            controller.setVisible(true)
        } else {
            hudController?.setVisible(false)
        }
        #endif
    }

    @MainActor
    func hideHUDImmediately() {
        #if canImport(SayAllAI)
        hudController?.hideImmediately()
        #endif
    }
}
