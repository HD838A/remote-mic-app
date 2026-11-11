import SwiftUI

struct RemoteMicRootView: View {
    let model: BridgeAppModel
    @ObservedObject private var buttonProfileImportRequests: ButtonProfileImportRequestStore
    /// AppKit 菜单与 ⌘1–⌘9 的导航桥，由 AppDelegate 持有并注入。
    @ObservedObject private var settingsNavigation: SettingsNavigationStore
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var updateInformation: UpdateInformationStore
    @ObservedObject private var hardwareAnnouncements: HardwareAnnouncementStore
    let checkForUpdates: () -> Void
    let refreshUpdateInformation: () -> Void
    let setDockIconVisible: (Bool) -> Void
    let setStatusBarIconVisible: (Bool) -> Void
    let syncEntryPointVisibility: () -> Void
    private let initialSettingsSection: SettingsSection?

    init(
        model: BridgeAppModel,
        buttonProfileImportRequests: ButtonProfileImportRequestStore = ButtonProfileImportRequestStore(),
        settingsNavigation: SettingsNavigationStore = SettingsNavigationStore(),
        updateInformation: UpdateInformationStore,
        hardwareAnnouncements: HardwareAnnouncementStore = HardwareAnnouncementStore(),
        checkForUpdates: @escaping () -> Void,
        refreshUpdateInformation: @escaping () -> Void,
        setDockIconVisible: @escaping (Bool) -> Void,
        setStatusBarIconVisible: @escaping (Bool) -> Void,
        syncEntryPointVisibility: @escaping () -> Void,
        initialSettingsSection: SettingsSection? = nil
    ) {
        self.model = model
        self.buttonProfileImportRequests = buttonProfileImportRequests
        self.settingsNavigation = settingsNavigation
        settings = model.settings
        self.updateInformation = updateInformation
        self.hardwareAnnouncements = hardwareAnnouncements
        self.checkForUpdates = checkForUpdates
        self.refreshUpdateInformation = refreshUpdateInformation
        self.setDockIconVisible = setDockIconVisible
        self.setStatusBarIconVisible = setStatusBarIconVisible
        self.syncEntryPointVisibility = syncEntryPointVisibility
        self.initialSettingsSection = initialSettingsSection
    }

    var body: some View {
        Group {
            if settings.isOnboardingComplete {
                SettingsView(
                    model: model,
                    buttonProfileImportRequests: buttonProfileImportRequests,
                    settingsNavigation: settingsNavigation,
                    updateInformation: updateInformation,
                    hardwareAnnouncements: hardwareAnnouncements,
                    checkForUpdates: checkForUpdates,
                    refreshUpdateInformation: refreshUpdateInformation,
                    setDockIconVisible: setDockIconVisible,
                    setStatusBarIconVisible: setStatusBarIconVisible,
                    syncEntryPointVisibility: syncEntryPointVisibility,
                    initialSection: initialSettingsSection
                )
            } else {
                OnboardingView(model: model)
            }
        }
        // 窗口根挂一次：气泡覆盖整个窗口，`noticeAnchor` 上报的坐标也在这套坐标系里换算。
        .noticeHost()
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
