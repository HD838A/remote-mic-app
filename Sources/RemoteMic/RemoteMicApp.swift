import AppKit
import Combine
import CoreBluetooth
import Darwin
import Sparkle
import SwiftUI

struct UpdateFeedSelection {
    let stableFeedURLString: String?
    private(set) var preReleaseFeedURL: URL?

    init(stableFeedURLString: String?) {
        self.stableFeedURLString = stableFeedURLString
    }

    mutating func usePreReleaseFeed(_ url: URL) {
        preReleaseFeedURL = url
    }

    mutating func useStableFeed() {
        preReleaseFeedURL = nil
    }

    func feedURLString(checksForPreReleaseUpdates: Bool) -> String? {
        if checksForPreReleaseUpdates, let preReleaseFeedURL {
            return preReleaseFeedURL.absoluteString
        }
        return stableFeedURLString
    }

    var appcastAssetName: String {
        guard let stableFeedURLString,
              let name = URL(string: stableFeedURLString)?.lastPathComponent,
              !name.isEmpty
        else { return "appcast.xml" }
        return name
    }
}

struct UpdateCheckPolicy: Equatable {
    let checksForPreReleaseUpdates: Bool

    var startsUpdaterAutomatically: Bool {
        !checksForPreReleaseUpdates
    }

    var allowsBackgroundUpdatePrompts: Bool {
        !checksForPreReleaseUpdates
    }

    var refreshesAboutInformationOnAppear: Bool {
        !checksForPreReleaseUpdates
    }
}

enum SettingsWindowActivationPolicy {
    static func value(
        showDockIcon: Bool,
        isSettingsWindowOpen: Bool
    ) -> NSApplication.ActivationPolicy {
        showDockIcon || isSettingsWindowOpen ? .regular : .accessory
    }
}

@main
enum RemoteMicApp {
    @MainActor
    static func main() {
        if let screenshotDirectory = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_DIR"
        ] {
            do {
                try SettingsScreenshotRenderer.renderAll(
                    to: URL(fileURLWithPath: screenshotDirectory, isDirectory: true),
                    sizeValue: ProcessInfo.processInfo.environment[
                        "REMOTE_MIC_SETTINGS_SCREENSHOT_SIZE"
                    ],
                    appearanceName: ProcessInfo.processInfo.environment[
                        "REMOTE_MIC_SETTINGS_SCREENSHOT_APPEARANCE"
                    ],
                    languageName: ProcessInfo.processInfo.environment[
                        "REMOTE_MIC_SETTINGS_SCREENSHOT_LANGUAGE"
                    ]
                )
            } catch {
                fputs("Settings screenshot rendering failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if let screenshotDirectory = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_ONBOARDING_SCREENSHOT_DIR"
        ] {
            do {
                try OnboardingScreenshotRenderer.renderAll(
                    to: URL(fileURLWithPath: screenshotDirectory, isDirectory: true),
                    appearanceName: ProcessInfo.processInfo.environment[
                        "REMOTE_MIC_ONBOARDING_SCREENSHOT_APPEARANCE"
                    ]
                )
            } catch {
                fputs("Onboarding screenshot rendering failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? ApplicationInstanceGuard.fallbackBundleIdentifier
        var instanceLock: ApplicationInstanceLock?
        if let lockURL = ApplicationInstanceGuard.defaultLockURL() {
            switch ApplicationInstanceLock.acquire(at: lockURL) {
            case let .acquired(lock):
                instanceLock = lock
            case .alreadyLocked:
                ApplicationInstanceGuard.existingApplication(
                    bundleIdentifier: bundleIdentifier
                )?.activate(options: [.activateAllWindows])
                return
            case let .failed(reason):
                fputs("Single-instance lock unavailable: \(reason)\n", stderr)
            }
        } else {
            fputs("Single-instance lock unavailable: application_support_missing\n", stderr)
        }

        if let existingApplication = ApplicationInstanceGuard.existingApplication(
            bundleIdentifier: bundleIdentifier,
            requiresFinishedLaunch: true
        ) {
            existingApplication.activate(options: [.activateAllWindows])
            return
        }

        let application = NSApplication.shared
        let delegate = RemoteMicAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(delegate.activationPolicy)
        withExtendedLifetime(instanceLock) {
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}

@MainActor
private final class RemoteMicAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
    NSWindowDelegate, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate
{
    private enum UpdateCheckPurpose {
        case information
        case userInitiated
    }

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/HD838A/remote-mic-app/releases?per_page=30"
    )!
    private static let preReleaseFeedRefreshInterval: TimeInterval = 6 * 60 * 60

    private let model = BridgeAppModel()
    private let updateInformation = UpdateInformationStore()
    private lazy var localization = LocalizationStore(settings: model.settings)
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: NSWindowController?
    private let settingsNavigationCoordinator = SettingsNavigationCoordinator()
    private var isSettingsWindowOpen = false
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var applicationShortcutMonitor: Any?
    private var workspaceAudioLifecycleObservers: [NSObjectProtocol] = []
    private var updateFeedSelection = UpdateFeedSelection(
        stableFeedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    )
    private var updateFeedRefreshTask: Task<Void, Never>?
    private var updateFeedRefreshTimer: Timer?
    private var updaterStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private let connectionItem = NSMenuItem()
    private let audioItem = NSMenuItem()
    private let hidItem = NSMenuItem()

    var activationPolicy: NSApplication.ActivationPolicy {
        SettingsWindowActivationPolicy.value(
            showDockIcon: model.settings.showDockIcon,
            isSettingsWindowOpen: false
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let completedUpdate = model.settings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: currentBuild,
            sparkleHadLaunchedBefore: UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore")
        )
        observeUpdatePreferences()
        configureUpdater()
        installTerminationSignalHandlers()
        configureApplicationMenu()
        installApplicationKeyboardShortcuts()
        configureStatusItem()
        observeModel()
        observeLocalization()
        observePhoneRemoteButtonTitles()
        installWorkspaceAudioLifecycleObservers()
        model.privateFeature.refreshAccessIfNeeded()
        model.macroFeature.refreshAccessIfNeeded()
        if OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: model.settings.isOnboardingComplete,
            step: model.settings.onboardingStep
        ) {
            model.startIfNeeded()
        }
        if model.settings.isOnboardingComplete,
           BridgeAppModel.shouldRecoverHIDAfterCompletedUpdate(
            completedUpdate: completedUpdate,
            customMappingEnabled: model.settings.customMappingEnabled
        ) {
            model.recoverHIDAfterCompletedUpdate()
        }
        let shouldOpenPermissionRepair = CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: model.settings.isOnboardingComplete,
            completedUpdate: completedUpdate,
            bluetoothGranted: CBManager.authorization == .allowedAlways,
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        if shouldOpenPermissionRepair {
            AppLogger.shared.write(
                "UPDATE PERMISSION_REPAIR bluetooth=\(CBManager.authorization == .allowedAlways) " +
                    "input=\(HIDRemoteMonitor.isInputMonitoringGranted) " +
                    "accessibility=\(KeyboardInjector.isAccessibilityTrusted)"
            )
        }
        refreshMenuStatus()

        if OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: model.settings.isOnboardingComplete,
            completedUpdate: completedUpdate,
            openMainWindowAtLaunch: model.settings.openMainWindowAtLaunch
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if shouldOpenPermissionRepair {
                    self.showSettingsWindow(initialSection: .permissions)
                } else {
                    self.showSettings()
                }
                if completedUpdate {
                    self.showUpdateCompletedAlert()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.privateFeature.hideHUDImmediately()
        model.stop()
        updateFeedRefreshTask?.cancel()
        updateFeedRefreshTimer?.invalidate()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
        if let applicationShortcutMonitor {
            NSEvent.removeMonitor(applicationShortcutMonitor)
            self.applicationShortcutMonitor = nil
        }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceAudioLifecycleObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceAudioLifecycleObservers.removeAll()
        AppLogger.shared.write("SYSTEM AUDIO observers_stopped")
        AppLogger.shared.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.privateFeature.refreshAccessIfNeeded()
        model.macroFeature.refreshAccessIfNeeded()
        model.refreshHIDAfterPermissionChange()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func installWorkspaceAudioLifecycleObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, SystemAudioLifecycleEvent)] = [
            (NSWorkspace.screensDidSleepNotification, .screenDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screenDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
        ]
        workspaceAudioLifecycleObservers = events.map { name, event in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.model.handleSystemAudioLifecycle(event)
                    if event == .systemDidWake {
                        self.model.privateFeature.refreshAccessIfNeeded()
                        self.model.macroFeature.refreshAccessIfNeeded()
                    }
                }
            }
        }
        AppLogger.shared.write(
            "SYSTEM AUDIO observers_started events=\(events.map { $0.1.rawValue }.joined(separator: ","))"
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStatus()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.toolTip = localization.text("app.name")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            if let image = statusImage(isStreaming: false) {
                button.image = image
            } else {
                button.title = localization.text("status_item.accessibility_label")
            }
        }

        connectionItem.isEnabled = false
        audioItem.isEnabled = false
        hidItem.isEnabled = false

        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu?.removeItem(connectionItem)
        statusMenu?.removeItem(audioItem)
        statusMenu?.removeItem(hidItem)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(connectionItem)
        menu.addItem(audioItem)
        menu.addItem(hidItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("connection.action.reconnect", action: #selector(reconnect)))
        menu.addItem(menuItem("menu.open_settings", action: #selector(showSettings)))
        menu.addItem(menuItem("menu.show_logs", action: #selector(showLog)))
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())
        menu.addItem(menuItem("menu.about", action: #selector(showAbout)))
        menu.addItem(versionMenuItem())
        menu.addItem(menuItem("menu.check_for_updates", action: #selector(checkForUpdates)))
        menu.addItem(menuItem("about.support.github", action: #selector(openGitHub)))
        menu.addItem(menuItem("about.support.website", action: #selector(openWebsite)))
        menu.addItem(.separator())
        menu.addItem(menuItem("common.action.quit", action: #selector(quit)))
        statusMenu = menu
        refreshMenuStatus()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: localization.text("app.name"))
        applicationMenu.addItem(menuItem("menu.about", action: #selector(showAbout)))
        applicationMenu.addItem(.separator())
        let hideItem = NSMenuItem(
            title: String(
                format: localization.text("menu.hide_app"),
                locale: localization.locale,
                localization.text("app.name")
            ),
            action: Selector("hide:"),
            keyEquivalent: "h"
        )
        hideItem.target = nil
        applicationMenu.addItem(hideItem)
        applicationMenu.addItem(responderMenuItem(
            "menu.hide_others",
            action: "hideOtherApplications:",
            keyEquivalent: "h",
            modifiers: [.command, .option]
        ))
        applicationMenu.addItem(responderMenuItem(
            "menu.show_all",
            action: "unhideAllApplications:",
            keyEquivalent: ""
        ))
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: localization.text("common.action.quit"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: localization.text("menu.file"))
        let closeItem = NSMenuItem(
            title: localization.text("common.action.close"),
            action: #selector(closeKeyWindow),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        closeItem.target = self
        fileMenu.addItem(menuItem("menu.open_log_folder", action: #selector(showLog)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: localization.text("menu.edit"))
        editMenu.addItem(responderMenuItem("common.action.undo", action: "undo:", keyEquivalent: "z"))
        editMenu.addItem(responderMenuItem("common.action.redo", action: "redo:", keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem("common.action.cut", action: "cut:", keyEquivalent: "x"))
        editMenu.addItem(responderMenuItem("common.action.copy", action: "copy:", keyEquivalent: "c"))
        editMenu.addItem(responderMenuItem("common.action.paste", action: "paste:", keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(responderMenuItem("common.action.select_all", action: "selectAll:", keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(
            title: localization.text("menu.find"),
            action: #selector(focusSettingsSearch),
            keyEquivalent: "f"
        )
        findItem.keyEquivalentModifierMask = .command
        findItem.target = self
        editMenu.addItem(findItem)
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: localization.text("menu.view"))
        let backItem = NSMenuItem(
            title: localization.text("settings.navigation.back"),
            action: #selector(goBackInSettings),
            keyEquivalent: "["
        )
        backItem.keyEquivalentModifierMask = .command
        backItem.target = self
        viewMenu.addItem(backItem)
        let forwardItem = NSMenuItem(
            title: localization.text("settings.navigation.forward"),
            action: #selector(goForwardInSettings),
            keyEquivalent: "]"
        )
        forwardItem.keyEquivalentModifierMask = .command
        forwardItem.target = self
        viewMenu.addItem(forwardItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: localization.text("menu.window"))
        windowMenu.addItem(responderMenuItem(
            "menu.minimize",
            action: "performMiniaturize:",
            keyEquivalent: "m"
        ))
        windowMenu.addItem(responderMenuItem(
            "menu.zoom",
            action: "performZoom:",
            keyEquivalent: ""
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(responderMenuItem(
            "menu.bring_all_to_front",
            action: "arrangeInFront:",
            keyEquivalent: ""
        ))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackInSettings):
            return isSettingsWindowOpen && settingsNavigationCoordinator.canGoBack
        case #selector(goForwardInSettings):
            return isSettingsWindowOpen && settingsNavigationCoordinator.canGoForward
        case #selector(focusSettingsSearch):
            // `.searchFocused` only exists on macOS 15+; keep the shortcut honest on 14.
            guard #available(macOS 15.0, *) else { return false }
            return isSettingsWindowOpen
        default:
            return true
        }
    }

    @objc private func goBackInSettings() {
        settingsNavigationCoordinator.goBack()
    }

    @objc private func goForwardInSettings() {
        settingsNavigationCoordinator.goForward()
    }

    @objc private func focusSettingsSearch() {
        settingsNavigationCoordinator.focusSearch()
    }

    private func responderMenuItem(
        _ titleKey: String,
        action: String,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: localization.text(titleKey),
            action: Selector(action),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifiers
        // A nil target lets AppKit route the standard action to the focused responder.
        item.target = nil
        return item
    }

    private func installApplicationKeyboardShortcuts() {
        applicationShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let relevantModifiers = event.modifierFlags.intersection([
                .command, .control, .option, .shift,
            ])
            guard relevantModifiers == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q":
                self?.quit()
                return nil
            case "w":
                self?.closeKeyWindow()
                return nil
            default:
                return event
            }
        }
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: localization.text(title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func languageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: localization.text("menu.language"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let title: String
            switch language {
            case .system:
                title = localization.text("language.system")
            case .simplifiedChinese, .english:
                title = language.nativeDisplayName
            }
            let languageItem = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = language.rawValue
            languageItem.state = language == localization.language ? .on : .off
            submenu.addItem(languageItem)
        }
        item.submenu = submenu
        return item
    }

    private func versionMenuItem() -> NSMenuItem {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let title = build.map {
            String(
                format: localization.text("app.version_with_build"),
                locale: localization.locale,
                arguments: [shortVersion, $0]
            )
        } ?? String(
            format: localization.text("app.version"),
            locale: localization.locale,
            arguments: [shortVersion]
        )
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func observeModel() {
        Publishers.CombineLatest4(
            model.$connectionStatus,
            model.$audioStatus,
            model.$hidStatus,
            model.$isStreaming
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refreshMenuStatus()
        }
        .store(in: &subscriptions)

        model.privateFeature.$hudShouldBeVisible
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] isVisible in
            self?.setPrivateFeatureHUDVisible(isVisible)
        }
        .store(in: &subscriptions)
    }

    private func setPrivateFeatureHUDVisible(_ isVisible: Bool) {
        model.privateFeature.setHUDVisible(isVisible)
    }

    private func observeLocalization() {
        localization.$locale
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem?.button?.toolTip = self.localization.text("app.name")
                self.settingsWindowController?.window?.title = self.localization.text("app.name")
                self.model.privateFeature.updateLocaleIdentifier(
                    self.localization.locale.identifier
                )
                self.model.macroFeature.updateLocaleIdentifier(
                    self.localization.locale.identifier
                )
                self.configureApplicationMenu()
                self.rebuildStatusMenu()
                self.updateInformation.reloadReleaseNotes(
                    localeIdentifier: self.localization.locale.identifier
                )
            }
            .store(in: &subscriptions)
    }

    private func observePhoneRemoteButtonTitles() {
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                model.settings.$buttonBindings,
                model.settings.$buttonShortcuts,
                model.settings.$buttonApplicationProfileIDs,
                model.settings.$customApplicationProfiles
            ),
            localization.$locale
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] values, _ in
            guard let self else { return }
            let (bindings, shortcuts, applicationProfileIDs, customApplicationProfiles) = values
            model.updatePhoneRemoteButtonTitles(
                bindings: bindings,
                shortcuts: shortcuts,
                applicationProfileIDs: applicationProfileIDs,
                customApplicationProfiles: customApplicationProfiles,
                localization: localization
            )
        }
        .store(in: &subscriptions)
    }

    private func observeUpdatePreferences() {
        model.settings.$checksForPreReleaseUpdates
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                updateFeedRefreshTask?.cancel()
                updateFeedSelection.useStableFeed()
                updateInformation.reset()
                configurePreReleaseFeedRefreshTimer(isEnabled: isEnabled)
                let policy = UpdateCheckPolicy(checksForPreReleaseUpdates: isEnabled)
                if updaterStarted {
                    updaterController.updater.automaticallyChecksForUpdates =
                        policy.allowsBackgroundUpdatePrompts
                }
                if policy.startsUpdaterAutomatically {
                    startUpdaterIfNeeded()
                    updaterController.updater.resetUpdateCycleAfterShortDelay()
                    refreshUpdateInformation()
                }
            }
            .store(in: &subscriptions)
    }

    private func configureUpdater() {
        let checksForPreReleaseUpdates = model.settings.checksForPreReleaseUpdates
        configurePreReleaseFeedRefreshTimer(isEnabled: checksForPreReleaseUpdates)
        guard checksForPreReleaseUpdates else {
            startUpdaterIfNeeded()
            return
        }
        refreshPreReleaseFeed()
    }

    private func startUpdaterIfNeeded() {
        guard !updaterStarted else { return }
        updaterController.updater.automaticallyChecksForUpdates =
            UpdateCheckPolicy(
                checksForPreReleaseUpdates: model.settings.checksForPreReleaseUpdates
            ).allowsBackgroundUpdatePrompts
        updaterController.startUpdater()
        updaterStarted = true
    }

    private func configurePreReleaseFeedRefreshTimer(isEnabled: Bool) {
        updateFeedRefreshTimer?.invalidate()
        updateFeedRefreshTimer = nil
        guard isEnabled else { return }
        updateFeedRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.preReleaseFeedRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPreReleaseFeed(resetUpdateCycleWhenChanged: true)
            }
        }
    }

    private func refreshPreReleaseFeed(resetUpdateCycleWhenChanged: Bool = false) {
        updateFeedRefreshTask?.cancel()
        updateFeedRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolvedFeed = try await Self.latestReleaseFeed(
                    assetName: updateFeedSelection.appcastAssetName,
                    includePreRelease: true
                )
                let resolvedURL = resolvedFeed.url
                guard !Task.isCancelled, model.settings.checksForPreReleaseUpdates else { return }
                let feedChanged = updateFeedSelection.preReleaseFeedURL != resolvedURL
                updateFeedSelection.usePreReleaseFeed(resolvedURL)
                AppLogger.shared.write("UPDATE FEED prerelease_enabled=true resolved=true")
                if feedChanged, resetUpdateCycleWhenChanged, updaterStarted {
                    updaterController.updater.resetUpdateCycleAfterShortDelay()
                }
            } catch {
                guard !Task.isCancelled else { return }
                updateFeedSelection.useStableFeed()
                AppLogger.shared.write(
                    "UPDATE FEED prerelease_enabled=true resolved=false fallback=none " +
                        AppLogger.errorFields(error)
                )
                if updaterStarted, resetUpdateCycleWhenChanged {
                    updaterController.updater.resetUpdateCycleAfterShortDelay()
                }
            }
        }
    }

    private static func latestReleaseFeed(
        assetName: String,
        includePreRelease: Bool
    ) async throws -> UpdateFeedResolver.ResolvedFeed {
        if let testFeed = UpdateFeedResolver.testInjectedFeed(
            environment: ProcessInfo.processInfo.environment,
            assetName: assetName,
            includePreRelease: includePreRelease
        ) {
            return testFeed
        }
        var request = URLRequest(url: releasesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RemoteMic", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateFeedResolutionError.invalidResponse
        }
        return try UpdateFeedResolver.latestFeed(
            from: data,
            assetName: assetName,
            includePreRelease: includePreRelease
        )
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        let includePreRelease = model.settings.checksForPreReleaseUpdates
        if let testFeed = UpdateFeedResolver.testInjectedFeed(
            environment: ProcessInfo.processInfo.environment,
            assetName: updateFeedSelection.appcastAssetName,
            includePreRelease: includePreRelease
        ) {
            return testFeed.url.absoluteString
        }
        return updateFeedSelection.feedURLString(
            checksForPreReleaseUpdates: includePreRelease
        )
    }

    private func refreshMenuStatus() {
        connectionItem.title = model.connectionStatus.text(using: localization)
        audioItem.title = model.isStreaming
            ? localization.text("connection.status.voice_active")
            : model.audioStatus.text(using: localization)
        hidItem.title = model.hidStatus.text(using: localization)
        statusItem?.button?.image = statusImage(isStreaming: model.isStreaming)
    }

    private func statusImage(isStreaming: Bool) -> NSImage? {
        let resourceName = isStreaming ? "StatusIconActiveTemplate" : "StatusIconTemplate"
        let fallbackSymbol = isStreaming ? "mic.fill" : "dot.radiowaves.left.and.right"
        let accessibilityDescription = localization.text(
            isStreaming ? "status_item.voice_active_accessibility" : "status_item.accessibility_label"
        )
        let image = NSImage(named: NSImage.Name(resourceName))
            ?? NSImage(
                systemSymbolName: fallbackSymbol,
                accessibilityDescription: accessibilityDescription
            )
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = accessibilityDescription
        return image
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            showSettings()
        }
    }

    private func showStatusMenu() {
        guard let statusItem, let statusMenu else { return }
        refreshMenuStatus()
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func reconnect() {
        model.reconnect()
    }

    @objc private func showSettings() {
        showSettingsWindow(initialSection: .connection)
    }

    private func showSettingsWindow(initialSection: SettingsSection) {
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController(
                initialSettingsSection: initialSection
            )
        }
        guard let windowController = settingsWindowController,
              let window = windowController.window else { return }
        isSettingsWindowOpen = true
        updateDockActivationPolicy()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController(
        initialSettingsSection: SettingsSection = .connection
    ) -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: RemoteMicRootView(
                model: model,
                updateInformation: updateInformation,
                checkForUpdates: { [weak self] in self?.checkForUpdates() },
                refreshUpdateInformation: { [weak self] in
                    self?.refreshUpdateInformation()
                },
                setDockIconVisible: { [weak self] isVisible in
                    self?.setDockIconVisible(isVisible)
                },
                initialSettingsSection: initialSettingsSection,
                navigationCoordinator: settingsNavigationCoordinator
            )
            .environmentObject(localization)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localization.text("app.name")
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        // A settings window must remain visible when the user switches to another app.
        // Closing it remains an explicit red-button or Command-W action.
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 650)
        window.setContentSize(NSSize(width: 920, height: 700))
        window.setFrameAutosaveName("RemoteMicSettings")
        // Keep the system-restored frame when one exists; only center on first launch.
        if !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        return NSWindowController(window: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window
        else { return }
        model.macroFeature.setEditorActive(false)
        isSettingsWindowOpen = false
        updateDockActivationPolicy()
    }

    func applicationDidHide(_ notification: Notification) {
        model.macroFeature.setEditorActive(false)
    }

    @objc private func showLog() {
        model.openLogFolder()
    }

    @objc private func showAbout() {
        showSettingsWindow(initialSection: .about)
        settingsNavigationCoordinator.selectSection(.about)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue)
        else { return }
        localization.select(language)
    }

    @objc private func checkForUpdates() {
        performUpdateCheck(.userInitiated)
    }

    private func refreshUpdateInformation() {
        performUpdateCheck(.information)
    }

    private func performUpdateCheck(_ purpose: UpdateCheckPurpose) {
        updateFeedRefreshTask?.cancel()
        updateFeedRefreshTask = Task { [weak self] in
            guard let self else { return }
            updateInformation.beginChecking()
            let includePreRelease = model.settings.checksForPreReleaseUpdates
            do {
                let resolvedFeed = try await Self.latestReleaseFeed(
                    assetName: updateFeedSelection.appcastAssetName,
                    includePreRelease: includePreRelease
                )
                guard !Task.isCancelled,
                      model.settings.checksForPreReleaseUpdates == includePreRelease
                else { return }
                if includePreRelease {
                    updateFeedSelection.usePreReleaseFeed(resolvedFeed.url)
                    AppLogger.shared.write("UPDATE CHECK prerelease_enabled=true resolved=true")
                } else {
                    updateFeedSelection.useStableFeed()
                    AppLogger.shared.write("UPDATE CHECK prerelease_enabled=false resolved=true")
                }

                let currentVersion = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? ""
                guard UpdateVersion.isNewer(resolvedFeed.version, than: currentVersion) else {
                    startUpdaterIfNeeded()
                    updateInformation.setUpToDate()
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                updateFeedSelection.useStableFeed()
                updateInformation.setUnavailable()
                AppLogger.shared.write(
                    "UPDATE CHECK prerelease_enabled=\(includePreRelease) resolved=false " +
                        "user_alert=false " + AppLogger.errorFields(error)
                )
                return
            }
            startUpdaterIfNeeded()
            guard !updaterController.updater.sessionInProgress else { return }
            switch purpose {
            case .information:
                updateInformation.beginChecking()
                updaterController.updater.checkForUpdateInformation()
            case .userInitiated:
                updaterController.checkForUpdates(nil)
            }
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateInformation.setAvailable(
            displayVersion: item.displayVersionString,
            buildVersion: item.versionString,
            archiveURL: item.fileURL,
            fallbackDescription: item.itemDescription,
            localeIdentifier: localization.locale.identifier
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateInformation.setUpToDate()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let sparkleError = error as NSError
        guard let latestItem = sparkleError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem,
              let currentVersion = Bundle.main.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let currentBuild = Bundle.main.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              let candidateBuild = Int(latestItem.versionString),
              let installedBuild = Int(currentBuild),
              candidateBuild < installedBuild,
              UpdateVersion.isNewer(
                  latestItem.displayVersionString,
                  than: currentVersion
              )
        else {
            updateInformation.setUpToDate()
            return
        }

        updateInformation.setAvailable(
            displayVersion: latestItem.displayVersionString,
            buildVersion: latestItem.versionString,
            archiveURL: latestItem.fileURL,
            fallbackDescription: latestItem.itemDescription,
            localeIdentifier: localization.locale.identifier
        )
        AppLogger.shared.write(
            "UPDATE CHECK semantic_newer_but_sparkle_rejected " +
                "display_version=\(latestItem.displayVersionString) " +
                "candidate_build=\(latestItem.versionString) " +
                "installed_build=\(currentBuild)"
        )
    }

    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool {
        false
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if error != nil, updateInformation.state == .checking {
            updateInformation.setUnavailable()
        }
    }

    private func showUpdateCompletedAlert() {
        guard let window = settingsWindowController?.window else { return }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
        let alert = NSAlert()
        alert.messageText = localization.text("update.completed.title")
        alert.informativeText = String(
            format: localization.text("update.completed.message"),
            locale: localization.locale,
            arguments: [version]
        )
        alert.addButton(withTitle: localization.text("common.action.ok"))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func setDockIconVisible(_ isVisible: Bool) {
        model.settings.showDockIcon = isVisible
        updateDockActivationPolicy()
    }

    private func updateDockActivationPolicy() {
        NSApp.setActivationPolicy(SettingsWindowActivationPolicy.value(
            showDockIcon: model.settings.showDockIcon,
            isSettingsWindowOpen: isSettingsWindowOpen
        ))
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(AppLinks.githubRepository)
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(localization.localizedWebsiteURL)
    }

    @objc private func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
