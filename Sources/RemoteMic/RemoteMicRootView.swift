import SwiftUI

struct RemoteMicRootView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject private var settings: AppSettings
    let checkForUpdates: () -> Void
    let setDockIconVisible: (Bool) -> Void

    init(
        model: BridgeAppModel,
        checkForUpdates: @escaping () -> Void,
        setDockIconVisible: @escaping (Bool) -> Void
    ) {
        self.model = model
        settings = model.settings
        self.checkForUpdates = checkForUpdates
        self.setDockIconVisible = setDockIconVisible
    }

    var body: some View {
        Group {
            if settings.isOnboardingComplete {
                SettingsView(
                    model: model,
                    checkForUpdates: checkForUpdates,
                    setDockIconVisible: setDockIconVisible
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
