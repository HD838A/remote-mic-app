import SwiftUI

struct RemoteMicRootView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var updateInformation: UpdateInformationStore
    let checkForUpdates: () -> Void
    let refreshUpdateInformation: () -> Void
    let setDockIconVisible: (Bool) -> Void
    private let initialSettingsSection: SettingsSection

    init(
        model: BridgeAppModel,
        updateInformation: UpdateInformationStore,
        checkForUpdates: @escaping () -> Void,
        refreshUpdateInformation: @escaping () -> Void,
        setDockIconVisible: @escaping (Bool) -> Void,
        initialSettingsSection: SettingsSection = .connection
    ) {
        self.model = model
        settings = model.settings
        self.updateInformation = updateInformation
        self.checkForUpdates = checkForUpdates
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.initialSettingsSection = initialSettingsSection
    }

    var body: some View {
        Group {
            if settings.isOnboardingComplete {
                SettingsView(
                    model: model,
                    updateInformation: updateInformation,
                    checkForUpdates: checkForUpdates,
                    refreshUpdateInformation: refreshUpdateInformation,
                    setDockIconVisible: setDockIconVisible,
                    initialSection: initialSettingsSection
                )
            } else {
                OnboardingView(model: model)
            }
        }
        .onAppear {
            startRuntimeIfRequired(for: settings.onboardingStep)
        }
        .onReceive(settings.$onboardingStep) { step in
            startRuntimeIfRequired(for: step)
        }
    }

    private func startRuntimeIfRequired(for step: OnboardingStep) {
        guard OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: settings.isOnboardingComplete,
            step: step
        ) else { return }
        model.startIfNeeded()
    }
}
