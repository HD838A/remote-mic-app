import AppKit
import Combine
import CoreBluetooth
import Darwin
import Sparkle
import SwiftUI

struct UpdateFeedSelection {
    let stableFeedURLString: String?

    init(stableFeedURLString: String?) {
        self.stableFeedURLString = stableFeedURLString
    }

    func feedURLString(checksForPreReleaseUpdates: Bool) -> String? {
        guard let stableFeedURL else { return nil }
        return checksForPreReleaseUpdates
            ? preReleaseFeedURL?.absoluteString
            : stableFeedURL.absoluteString
    }

    var appcastAssetName: String {
        guard let name = stableFeedURL?.lastPathComponent
        else { return "appcast.xml" }
        return name
    }

    var validatedStableFeedURL: URL? {
        stableFeedURL
    }

    var validatedPreReleaseFeedURL: URL? {
        preReleaseFeedURL
    }

    private var stableFeedURL: URL? {
        guard let stableFeedURLString,
              let components = URLComponents(string: stableFeedURLString),
              components.scheme == "https",
              components.host == "download.sayall.app",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url,
              ["appcast.xml", "appcast-intel.xml"].contains(url.lastPathComponent),
              components.path == "/mac/channels/stable/\(url.lastPathComponent)"
        else { return nil }
        return url
    }

    private var preReleaseFeedURL: URL? {
        guard let stableFeedURL,
              var components = URLComponents(url: stableFeedURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/mac/channels/preview/\(stableFeedURL.lastPathComponent)"
        return components.url
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
    static func value(showDockIcon: Bool, isSettingsWindowOpen: Bool) -> NSApplication.ActivationPolicy {
        (showDockIcon || isSettingsWindowOpen) ? .regular : .accessory
    }
}

enum AppEntryPointVisibilityPolicy {
    static func shouldShowMainWindow(
        baseLaunchDecision: Bool,
        showDockIcon: Bool,
        showStatusBarIcon: Bool
    ) -> Bool {
        baseLaunchDecision || (!showDockIcon && !showStatusBarIcon)
    }
}

struct ButtonProfileImportRequest: Equatable {
    let url: URL
    let operationID: UInt
}

final class ButtonProfileImportRequestStore: ObservableObject {
    @Published private(set) var pendingRequest: ButtonProfileImportRequest?
    private var nextOperationID: UInt = 0

    @discardableResult
    func enqueue(url: URL) -> ButtonProfileImportRequest {
        nextOperationID += 1
        let request = ButtonProfileImportRequest(url: url, operationID: nextOperationID)
        pendingRequest = request
        return request
    }

    func clear() {
        pendingRequest = nil
    }
}

@main
enum RemoteMicApp {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--agent-configure") {
            let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
            exit(AgentConfigurationCommand.run(arguments: arguments))
        }
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
        let existingInstances = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).count
        AppLogger.shared.write(
            "APP INSTANCE phase=launch bundle_id=\(bundleIdentifier) " +
                "pid=\(ProcessInfo.processInfo.processIdentifier) " +
                "existing_instances=\(existingInstances)"
        )
        var instanceLock: ApplicationInstanceLock?
        if let lockURL = ApplicationInstanceGuard.defaultLockURL() {
            switch ApplicationInstanceLock.acquire(at: lockURL) {
            case let .acquired(lock):
                instanceLock = lock
            case .alreadyLocked:
                AppLogger.shared.write(
                    "APP INSTANCE phase=blocked result=existing_instance reason=lock_held"
                )
                ApplicationInstanceGuard.existingApplication(
                    bundleIdentifier: bundleIdentifier
                )?.activate(options: [.activateAllWindows])
                return
            case let .failed(reason):
                AppLogger.shared.write(
                    "APP INSTANCE phase=warning result=lock_unavailable reason=\(reason)"
                )
                fputs("Single-instance lock unavailable: \(reason)\n", stderr)
            }
        } else {
            AppLogger.shared.write(
                "APP INSTANCE phase=warning result=lock_unavailable reason=application_support_missing"
            )
            fputs("Single-instance lock unavailable: application_support_missing\n", stderr)
        }

        if let existingApplication = ApplicationInstanceGuard.existingApplication(
            bundleIdentifier: bundleIdentifier,
            requiresFinishedLaunch: true
        ) {
            AppLogger.shared.write(
                "APP INSTANCE phase=blocked result=existing_instance reason=finished_launch"
            )
            existingApplication.activate(options: [.activateAllWindows])
            return
        }

        let application = NSApplication.shared
        let delegate = RemoteMicAppDelegate()
        application.delegate = delegate
        delegate.updateDockActivationPolicy(source: "launch")
        withExtendedLifetime(instanceLock) {
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}

@MainActor
private final class RemoteMicAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation,
    NSWindowDelegate, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate
{
    private enum UpdateCheckPurpose {
        case information
        case userInitiated
    }

    /// 设置窗口的默认尺寸与最小尺寸（整窗，含标题栏）。
    ///
    /// 数值取自用户确认的按键页截图（实测整窗 1067×760）。默认值和最小值都绑这一个常量，
    /// 避免两处各写一遍后再次漂移。
    ///
    /// 760 必须等于 `SettingsView.minimumContentSize` 的高度 732 加标题栏 28：内容下限比
    /// 整窗下限高时，SwiftUI 会在首次布局后把窗口压回内容下限，常量就只剩记录作用。
    private static let settingsWindowFrameSize = NSSize(width: 1067, height: 760)

    private let model = BridgeAppModel()
    private lazy var appIconController = AppIconController()
    private let updateInformation = UpdateInformationStore()
    private let hardwareAnnouncements = HardwareAnnouncementStore()
    private lazy var localization = LocalizationStore(settings: model.settings)
    private var statusItem: NSStatusItem?
    private var statusItemPresentation: StatusItemPresentation = .disconnected
    private var appliedStatusItemPresentation: StatusItemPresentation?
    private var statusItemOperationID: UInt = 0
    private var statusItemWarningBlinkTimer: Timer?
    private var statusItemWarningBlinkVisible = true
    private var entryPointOperationID: UInt = 0
    private var statusMenu: NSMenu?
    private var statusMenuOperationID: UInt = 0
    private var activeStatusMenuOperation: (id: UInt, startedAt: TimeInterval, menu: NSMenu)?
    private var settingsWindowController: NSWindowController?
    private var isSettingsWindowOpen = false
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var applicationShortcutMonitor: Any?
    private var workspaceAudioLifecycleObservers: [NSObjectProtocol] = []
    private var updateFeedSelection = UpdateFeedSelection(
        stableFeedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    )
    private var updateCheckTask: Task<Void, Never>?
    private let buttonProfileImportRequests = ButtonProfileImportRequestStore()
    private let searchFocusCoordinator = SearchFocusCoordinator()
    /// 「编辑 > 查找…」当前实例。`configureApplicationMenu()` 在语言切换后会重建菜单，
    /// 因此这里必须保存最新引用，供 `validateMenuItem` 判断。
    private var findMenuItem: NSMenuItem?
    private let settingsNavigation = SettingsNavigationStore()
    /// 「前往」菜单。`configureApplicationMenu()` 在语言切换后会重建菜单，
    /// 因此保存最新引用，供 `menuNeedsUpdate` 识别。
    private var goMenu: NSMenu?
    private var resolvedUpdateFeedURLString: String?
    private var updaterStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private let connectionItem = NSMenuItem()
    private let audioItem = NSMenuItem()
    private let hidItem = NSMenuItem()
    private let macMicrophoneItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.write(
            "APP BUILD diagnostic_schema=3 " +
                AppEnvironmentSnapshot.buildIdentityFields(Bundle.main.infoDictionary ?? [:])
        )
        if let environmentEvent = AppEnvironmentSnapshot.current(
            settings: model.settings
        ).publicEvent {
            AppLogger.shared.record(environmentEvent)
        }
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let completedUpdate = model.settings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: currentBuild,
            sparkleHadLaunchedBefore: UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore")
        )
        observeUpdatePreferences()
        observeAppIconPreference()
        configureUpdater()
        installTerminationSignalHandlers()
        configureApplicationMenu()
        installApplicationKeyboardShortcuts()
        applyStatusBarIconVisibility(
            model.settings.showStatusBarIcon,
            source: "launch"
        )
        observeModel()
        observeLocalization()
        observePhoneRemoteButtonTitles()
        installWorkspaceAudioLifecycleObservers()
        model.privateFeature.refreshAccessIfNeeded()
        model.macroFeature.refreshAccessIfNeeded()
        model.membershipFeature.refreshIfNeeded()
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

        let baseLaunchDecision = OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: model.settings.isOnboardingComplete,
            completedUpdate: completedUpdate,
            openMainWindowAtLaunch: model.settings.openMainWindowAtLaunch
        )
        let shouldShowMainWindow = AppEntryPointVisibilityPolicy.shouldShowMainWindow(
            baseLaunchDecision: baseLaunchDecision,
            showDockIcon: model.settings.showDockIcon,
            showStatusBarIcon: model.settings.showStatusBarIcon
        )
        if shouldShowMainWindow {
            if !baseLaunchDecision {
                AppLogger.shared.write(
                    "UI ENTRY_POINT phase=decision result=required source=launch_recovery " +
                        "show_dock=false show_status_bar=false decision=open_settings"
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if shouldOpenPermissionRepair {
                    self.showSettingsWindow(initialSection: .about)
                } else {
                    self.showSettingsWindow()
                }
                // 升级后不再弹「已成功更新到版本」确认框：完成更新的人已经知道版本变了，
                // 弹窗只是挡住刚打开的窗口。主窗口与权限修复照旧自动呈现。
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.privateFeature.hideHUDImmediately()
        model.stop()
        model.settings.discardOnboardingVoiceTrial()
        updateCheckTask?.cancel()
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
        model.refreshRemoteDeviceNames(reason: .foreground)
        model.privateFeature.refreshAccessIfNeeded()
        model.macroFeature.refreshAccessIfNeeded()
        model.membershipFeature.refreshIfNeeded()
        model.refreshHIDAfterPermissionChange()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettingsWindow()
        AppLogger.shared.write(
            "UI ENTRY_POINT phase=completed result=passed source=application_reopen " +
                "show_dock=\(model.settings.showDockIcon) " +
                "show_status_bar=\(model.settings.showStatusBarIcon) " +
                "decision=open_settings"
        )
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let buttonProfileURL = urls.first(where: {
            $0.isFileURL && $0.pathExtension.caseInsensitiveCompare("sayall") == .orderedSame
        }) {
            let request = buttonProfileImportRequests.enqueue(url: buttonProfileURL)
            AppLogger.shared.write(
                "BUTTON_PROFILE_IMPORT phase=requested result=accepted " +
                    "source=finder_file operation_id=button_profile_import_\(request.operationID)"
            )
            showSettingsWindow()
        }

        guard let request = urls.lazy.compactMap(SayAllDeepLinkRequest.parse).first else {
            return
        }
        AppLogger.shared.write(
            "DEEPLINK SAYALL source=\(request.source ?? "unknown") " +
                "status=\(request.status?.rawValue ?? "none") " +
                "reason=\(request.reason ?? "none")"
        )
        NotificationCenter.default.post(
            name: .sayAllDeepLinkReceived,
            object: request
        )
        showSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
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
                        self.model.membershipFeature.refreshIfNeeded()
                    }
                }
            }
        }
        AppLogger.shared.write(
            "SYSTEM AUDIO observers_started events=\(events.map { $0.1.rawValue }.joined(separator: ","))"
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let findMenuItem, menuItem === findMenuItem {
            // 纯状态查询：打开「编辑」菜单本身不得产生聚焦副作用。
            return searchFocusCoordinator.hasRegisteredSearchField
        }
        return menuItem !== macMicrophoneItem || model.macMicrophoneState != .stopping
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            StatusMenuBatterySection.update(
                in: menu, before: audioItem, profiles: model.settings.remoteDeviceProfiles,
                connectedIDs: model.connectedRemoteProfileIDs, levels: model.remoteBatteryLevels,
                powerStates: model.remotePowerStates, localization: localization
            )
            return
        }
        guard let goMenu, menu === goMenu else { return }
        menu.removeAllItems()
        for section in settingsNavigation.visibleSections {
            let shortcut = SettingsPageBehavior.sidebarShortcutOrder.firstIndex(of: section)
            let item = NSMenuItem(
                title: settingsSectionTitle(section),
                action: #selector(selectSettingsSection(_:)),
                keyEquivalent: ""
            )
            item.representedObject = section.rawValue
            if let shortcut {
                item.keyEquivalent = String(shortcut + 1)
                item.keyEquivalentModifierMask = .command
            }
            item.target = self
            menu.addItem(item)
        }
    }

    /// 私有页签的标题由私有组件提供（`SettingsSection.titleKey` 对它们返回空串），
    /// 这里现算，避免语言切换后菜单里出现空白标题。
    private func settingsSectionTitle(_ section: SettingsSection) -> String {
        switch section {
        case .macros: return model.macroFeature.sectionTitle
        case .buttonProfiles: return model.macroFeature.buttonProfilesSectionTitle
        case .membership: return model.membershipFeature.sectionTitle
        case .privateFeature: return model.privateFeature.sectionTitle
        default: return localization.text(section.titleKey)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        finishStatusMenuOperation(result: "cancelled", reason: "menu_replaced")
        statusMenuOperationID &+= 1
        let operationID = statusMenuOperationID
        let source: String
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp: source = "left_click"
        case .rightMouseDown, .rightMouseUp: source = "right_click"
        case .keyDown, .keyUp: source = "keyboard"
        default: source = "other"
        }
        activeStatusMenuOperation = (operationID, ProcessInfo.processInfo.systemUptime, menu)
        AppLogger.shared.write(
            "UI STATUS_MENU operation_id=\(operationID) phase=requested source=\(source)"
        )
        refreshMenuStatus()
        AppLogger.shared.write(
            "UI STATUS_MENU operation_id=\(operationID) phase=started result=opening"
        )
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let operation = activeStatusMenuOperation, menu === operation.menu else { return }
        finishStatusMenuOperation(result: "closed", reason: "menu_did_close")
    }

    @discardableResult
    private func configureStatusItem() -> Bool {
        guard statusItem == nil else {
            rebuildStatusMenu()
            refreshStatusItemPresentation()
            return false
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        connectionItem.isEnabled = false
        audioItem.isEnabled = false
        hidItem.isEnabled = false

        statusItem = item
        appliedStatusItemPresentation = nil
        statusItemPresentation = .resolve(
            physicalConnected: model.isConnected,
            phoneConnected: model.isPhoneRemoteConnected,
            watchConnected: model.isWatchRemoteConnected,
            webState: model.webRemoteState,
            isStreaming: model.isStreaming,
            voiceWarningLevel: model.voiceSessionWarningLevel
        )
        refreshStatusItemPresentation()
        rebuildStatusMenu()
        return true
    }

    @discardableResult
    private func removeStatusItem() -> Bool {
        guard let statusItem else { return false }
        finishStatusMenuOperation(result: "cancelled", reason: "status_item_hidden")
        stopStatusItemWarningBlinking()
        statusMenu?.removeItem(connectionItem)
        statusMenu?.removeItem(audioItem)
        statusMenu?.removeItem(hidItem)
        statusMenu?.removeItem(macMicrophoneItem)
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        statusMenu = nil
        appliedStatusItemPresentation = nil
        return true
    }

    private func applyStatusBarIconVisibility(_ isVisible: Bool, source: String) {
        entryPointOperationID &+= 1
        let operationID = entryPointOperationID
        AppLogger.shared.write(
            "UI ENTRY_POINT operation_id=\(operationID) phase=requested source=\(source) " +
                "show_dock=\(model.settings.showDockIcon) show_status_bar=\(isVisible)"
        )
        let changed = isVisible ? configureStatusItem() : removeStatusItem()
        AppLogger.shared.write(
            "UI ENTRY_POINT operation_id=\(operationID) phase=completed result=passed " +
                "source=\(source) show_dock=\(model.settings.showDockIcon) show_status_bar=\(isVisible) " +
                "change=\(changed ? (isVisible ? "created" : "removed") : "none")"
        )
    }

    private func rebuildStatusMenu() {
        statusMenu?.removeItem(connectionItem)
        statusMenu?.removeItem(audioItem)
        statusMenu?.removeItem(hidItem)
        statusMenu?.removeItem(macMicrophoneItem)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("menu.open_settings", action: #selector(showSettingsFromStatusMenu)))
        menu.addItem(.separator())
        menu.addItem(connectionItem)
        menu.addItem(audioItem)
        menu.addItem(hidItem)
        menu.addItem(.separator())
        macMicrophoneItem.target = self
        macMicrophoneItem.action = #selector(toggleMacMicrophone)
        menu.addItem(macMicrophoneItem)
        menu.addItem(menuItem("connection.action.reconnect", action: #selector(reconnect)))
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
        statusItem?.menu = menu
        refreshMenuStatus()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: localization.text("app.name"))
        applicationMenu.addItem(menuItem("menu.about", action: #selector(showAbout)))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(responderMenuItem(
            "common.action.hide",
            action: "hide:",
            keyEquivalent: "h"
        ))
        applicationMenu.addItem(responderMenuItem(
            "common.action.hide_others",
            action: "hideOtherApplications:",
            keyEquivalent: "h",
            modifierMask: [.command, .option]
        ))
        applicationMenu.addItem(responderMenuItem(
            "common.action.show_all",
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
            title: localization.text("common.action.find"),
            action: #selector(focusVisibleSearchField),
            keyEquivalent: "f"
        )
        findItem.keyEquivalentModifierMask = [.command]
        // 不能用 responderMenuItem：它会把 target 置 nil，让 AppKit 把动作路由到
        // 当前聚焦的文本框；而 ⌘F 需要由宿主统一决定聚焦哪个搜索框。
        findItem.target = self
        editMenu.addItem(findItem)
        findMenuItem = findItem
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let goMenuItem = NSMenuItem()
        let goMenu = NSMenu(title: localization.text("menu.go"))
        // 页签可见性随会员开通、私有功能启停与 supplemental 动态页变化，
        // 因此每次打开菜单时按当前可见页签重建，避免标题或快捷键标签陈旧。
        goMenu.delegate = self
        goMenuItem.submenu = goMenu
        self.goMenu = goMenu
        mainMenu.addItem(goMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: localization.text("menu.window"))
        windowMenu.addItem(responderMenuItem(
            "common.action.minimize",
            action: "performMiniaturize:",
            keyEquivalent: "m"
        ))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func responderMenuItem(
        _ titleKey: String,
        action: String,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: localization.text(titleKey),
            action: Selector(action),
            keyEquivalent: keyEquivalent
        )
        item.keyEquivalentModifierMask = modifierMask
        // A nil target lets AppKit route the standard editing action to the focused text field.
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
            case "f":
                // 与既有 ⌘Q / ⌘W 同一范式：本地监听先于菜单 keyEquivalent 派发，
                // 返回 nil 后按键路径由此统一处理，菜单项保留 ⌘F 用于显示与鼠标点击。
                // 无条件吞掉也保证没有可用搜索框时静默（灰掉的菜单项不会再引发
                // AppKit 对未处理 ⌘F 的提示音）；是否聚焦由内部 guard 决定。
                self?.performSearchFocus()
                return nil
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                // 与 ⌘Q / ⌘W 同一范式：本地监听先于菜单 keyEquivalent 派发，
                // 返回 nil 后按键路径由此统一处理，菜单项保留 ⌘N 用于显示与鼠标点击。
                self?.requestSettingsSection(from: event)
                return nil
            default:
                return event
            }
        }
    }

    @objc private func focusVisibleSearchField() {
        performSearchFocus()
    }

    /// 菜单项与本地监听共用同一条路径，重复调用幂等。
    /// 没有可用搜索框时既不广播也不吞掉已有焦点。
    private func performSearchFocus() {
        // 「常用语浮窗」等独立窗口也复用带搜索框的页面；只有设置窗口是 key window
        // 时才聚焦，避免把浮窗里的搜索框抢过来。
        guard settingsWindowController?.window?.isKeyWindow == true,
              searchFocusCoordinator.hasRegisteredSearchField
        else { return }
        searchFocusCoordinator.requestFocus()
    }

    private func requestSettingsSection(from event: NSEvent) {
        guard let digit = event.charactersIgnoringModifiers?.first,
              let index = Int(String(digit)),
              index <= SettingsPageBehavior.sidebarShortcutOrder.count
        else { return }
        let section = SettingsPageBehavior.sidebarShortcutOrder[index - 1]
        requestSettingsSection(rawValue: section.rawValue)
    }

    @objc private func selectSettingsSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        requestSettingsSection(rawValue: raw)
    }

    private func requestSettingsSection(rawValue: String) {
        let section = SettingsSection(rawValue: rawValue)
        // 不可见的目标不生效，也不跳到别的页签；「前往」菜单本身就只列可见页签。
        guard settingsNavigation.visibleSections.contains(section) else { return }
        settingsNavigation.request(section: section)
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
        model.$macMicrophoneState.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuStatus() }
            .store(in: &subscriptions)
        StatusItemPresentation.publisher(
            physicalConnected: model.$isConnected.eraseToAnyPublisher(),
            phoneConnected: model.$isPhoneRemoteConnected.eraseToAnyPublisher(),
            watchConnected: model.$isWatchRemoteConnected.eraseToAnyPublisher(),
            webState: model.$webRemoteState.eraseToAnyPublisher(),
            isStreaming: model.$isStreaming.eraseToAnyPublisher(),
            voiceWarningLevel: model.$voiceSessionWarningLevel.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] presentation in
            // Consume the published snapshot, not properties that @Published has yet to set.
            self?.statusItemPresentation = presentation
            self?.refreshStatusItemPresentation()
        }
        .store(in: &subscriptions)

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
                self.refreshStatusItemPresentation()
                self.settingsWindowController?.window?.title = self.localization.text("app.name")
                self.model.privateFeature.updateLocaleIdentifier(
                    self.localization.locale.identifier
                )
                self.model.macroFeature.updateLocaleIdentifier(
                    self.localization.locale.identifier
                )
                self.model.membershipFeature.updateLocaleIdentifier(
                    self.localization.locale.identifier
                )
                self.configureApplicationMenu()
                if self.statusItem != nil {
                    self.rebuildStatusMenu()
                }
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
            self.refreshPhoneRemoteButtonTitles(
                bindings: values.0,
                shortcuts: values.1,
                applicationProfileIDs: values.2,
                customApplicationProfiles: values.3
            )
        }
        .store(in: &subscriptions)

        model.macroFeature.buttonProfileChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.refreshPhoneRemoteButtonTitles()
            }
            .store(in: &subscriptions)
    }

    private func refreshPhoneRemoteButtonTitles(
        bindings: [RemoteButton: ButtonAction]? = nil,
        shortcuts: [RemoteButton: CustomKeyboardShortcut]? = nil,
        applicationProfileIDs: [RemoteButton: UUID]? = nil,
        customApplicationProfiles: [CustomApplicationProfile]? = nil
    ) {
        model.updatePhoneRemoteButtonTitles(
            bindings: bindings ?? model.settings.buttonBindings,
            shortcuts: shortcuts ?? model.settings.buttonShortcuts,
            applicationProfileIDs: applicationProfileIDs ?? model.settings.buttonApplicationProfileIDs,
            customApplicationProfiles: customApplicationProfiles ?? model.settings.customApplicationProfiles,
            localization: localization
        )
    }

    private func observeUpdatePreferences() {
        model.settings.$checksForPreReleaseUpdates
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                updateCheckTask?.cancel()
                resolvedUpdateFeedURLString = nil
                updateInformation.reset()
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

    private func observeAppIconPreference() {
        model.settings.$appIconIdentifier
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] identifier in
                self?.applyAppIcon(identifier, source: "preference")
            }
            .store(in: &subscriptions)
    }

    private func applyAppIcon(_ identifier: AppIconIdentifier, source: String) {
        appIconController.apply(identifier, source: source)
    }

    private func reapplyCurrentAppIcon(source: String) {
        applyAppIcon(model.settings.appIconIdentifier, source: source)
    }

    private func configureUpdater() {
        let checksForPreReleaseUpdates = model.settings.checksForPreReleaseUpdates
        guard checksForPreReleaseUpdates else {
            startUpdaterIfNeeded()
            return
        }
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

    func feedURLString(for updater: SPUUpdater) -> String? {
        let includePreRelease = model.settings.checksForPreReleaseUpdates
        if let testFeed = UpdateFeedResolver.testInjectedFeed(
            environment: ProcessInfo.processInfo.environment,
            assetName: updateFeedSelection.appcastAssetName,
            includePreRelease: includePreRelease
        ) {
            return testFeed.url.absoluteString
        }
        if includePreRelease, let resolvedUpdateFeedURLString {
            return resolvedUpdateFeedURLString
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
        macMicrophoneItem.title = localization.text(model.macMicrophoneButtonKey)
        macMicrophoneItem.toolTip = localization.text("audio.mac_microphone.help")
        macMicrophoneItem.state = model.macMicrophoneEnabled ? .on : .off
        macMicrophoneItem.isEnabled = model.macMicrophoneState != .stopping
    }

    private func refreshStatusItemPresentation() {
        guard let button = statusItem?.button else { return }
        let description = LocalizedMessage(
            statusItemPresentation.descriptionKey,
            arguments: [localization.text("app.name")]
        ).text(using: localization)
        statusItemPresentation.apply(to: button, description: description)
        updateStatusItemWarningBlinking(button: button)
        guard appliedStatusItemPresentation != statusItemPresentation else { return }
        statusItemOperationID &+= 1
        AppLogger.shared.write(
            "UI STATUS_ITEM operation_id=\(statusItemOperationID) phase=completed result=applied " +
                "from=\(appliedStatusItemPresentation?.rawValue ?? "none") " +
                "to=\(statusItemPresentation.rawValue) " +
                "rendering=\(button.image == nil ? "text" : "image")"
        )
        appliedStatusItemPresentation = statusItemPresentation
    }

    private func updateStatusItemWarningBlinking(button: NSStatusBarButton) {
        guard statusItemPresentation == .streamingWarning else {
            stopStatusItemWarningBlinking()
            button.alphaValue = 1
            return
        }
        guard statusItemWarningBlinkTimer == nil else { return }
        statusItemWarningBlinkVisible = true
        button.alphaValue = 1
        let timer = Timer(
            timeInterval: 0.55,
            target: self,
            selector: #selector(handleStatusItemWarningBlink(_:)),
            userInfo: button,
            repeats: true
        )
        statusItemWarningBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleStatusItemWarningBlink(_ timer: Timer) {
        guard statusItemPresentation == .streamingWarning,
              let button = timer.userInfo as? NSStatusBarButton
        else {
            stopStatusItemWarningBlinking()
            return
        }
        statusItemWarningBlinkVisible.toggle()
        button.alphaValue = statusItemWarningBlinkVisible ? 1 : 0.35
    }

    private func stopStatusItemWarningBlinking() {
        statusItemWarningBlinkTimer?.invalidate()
        statusItemWarningBlinkTimer = nil
        statusItemWarningBlinkVisible = true
    }

    private func finishStatusMenuOperation(result: String, reason: String) {
        guard let operation = activeStatusMenuOperation else { return }
        activeStatusMenuOperation = nil
        let elapsedMilliseconds = max(
            0,
            Int((ProcessInfo.processInfo.systemUptime - operation.startedAt) * 1_000)
        )
        let batteryRows = operation.menu.items.filter { $0.identifier == StatusMenuBatterySection.itemIdentifier }.count
        AppLogger.shared.write(
            "UI STATUS_MENU operation_id=\(operation.id) phase=completed " +
                "result=\(result) reason=\(reason) elapsed_ms=\(elapsedMilliseconds) battery_rows=\(batteryRows)"
        )
    }

    @objc private func toggleMacMicrophone() {
        guard model.macMicrophoneState != .stopping else { return }
        model.toggleMacMicrophone(from: .statusMenu)
    }

    @objc private func reconnect() {
        model.reconnect()
    }

    @objc private func showSettingsFromStatusMenu() {
        showSettingsWindow()
    }

    private func showSettingsWindow(initialSection: SettingsSection? = nil) {
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController(
                initialSettingsSection: initialSection
            )
        }
        guard let windowController = settingsWindowController,
              let window = windowController.window else { return }
        isSettingsWindowOpen = true
        updateDockActivationPolicy(source: "window_open")
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController(
        initialSettingsSection: SettingsSection? = nil
    ) -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: RemoteMicRootView(
                model: model,
                buttonProfileImportRequests: buttonProfileImportRequests,
                settingsNavigation: settingsNavigation,
                updateInformation: updateInformation,
                hardwareAnnouncements: hardwareAnnouncements,
                checkForUpdates: { [weak self] in self?.checkForUpdates() },
                refreshUpdateInformation: { [weak self] in
                    self?.refreshUpdateInformation()
                },
                setDockIconVisible: { [weak self] isVisible in
                    self?.setDockIconVisible(isVisible)
                },
                setStatusBarIconVisible: { [weak self] isVisible in
                    self?.setStatusBarIconVisible(isVisible)
                },
                syncEntryPointVisibility: { [weak self] in
                    self?.applyImportedEntryPointVisibility()
                },
                initialSettingsSection: initialSettingsSection
            )
            .environmentObject(localization)
        )
        // 窗口尺寸按设计稿给定的是**整窗**（含标题栏）。`NSWindow` 的初始化和
        // `setContentSize` 用的是内容区，直接传整窗数值会多出一个标题栏的高度，
        // 所以统一从目标 frame 反算内容区，默认值与最小值才能对齐同一张设计稿。
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
        ]
        let frameSize = Self.settingsWindowFrameSize
        let contentRect = NSWindow.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize),
            styleMask: styleMask
        )
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = localization.text("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        // A settings window must remain visible when the user switches to another app.
        // Closing it remains an explicit red-button or Command-W action.
        window.hidesOnDeactivate = false
        window.delegate = self
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.miniwindowImage = appIconController.catalog.image(
            for: model.settings.appIconIdentifier
        )
        window.minSize = frameSize
        window.setContentSize(contentRect.size)
        window.setFrameAutosaveName("RemoteMicSettings")
        window.center()
        return NSWindowController(window: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window
        else { return }
        model.macroFeature.setEditorActive(false)
        isSettingsWindowOpen = false
        updateDockActivationPolicy(source: "window_close")
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reapplyCurrentAppIcon(source: "window_miniaturized")
        }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindowController?.window
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reapplyCurrentAppIcon(source: "window_deminiaturized")
        }
    }

    func applicationDidHide(_ notification: Notification) {
        model.macroFeature.setEditorActive(false)
    }

    @objc private func showLog() {
        model.openLogFolder()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
        let alert = NSAlert()
        alert.messageText = localization.text("app.name")
        alert.informativeText = String(
            format: localization.text("about.alert.description_with_version"),
            locale: localization.locale,
            arguments: [shortVersion]
        )
        alert.addButton(withTitle: localization.text("common.action.ok"))
        alert.runModal()
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
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            updateInformation.beginChecking()
            let includePreRelease = model.settings.checksForPreReleaseUpdates
            let testFeed = UpdateFeedResolver.testInjectedFeed(
                environment: ProcessInfo.processInfo.environment,
                assetName: updateFeedSelection.appcastAssetName,
                includePreRelease: includePreRelease
            )
            resolvedUpdateFeedURLString = nil
            if includePreRelease {
                let resolution: UpdateFeedResolver.FeedResolution
                if let testFeed {
                    resolution = UpdateFeedResolver.FeedResolution(
                        stable: nil,
                        preview: testFeed
                    )
                } else if let stableURL = updateFeedSelection.validatedStableFeedURL,
                          let previewURL = updateFeedSelection.validatedPreReleaseFeedURL {
                    resolution = await UpdateFeedResolver.resolvePreviewFeed(
                        stableURL: stableURL,
                        previewURL: previewURL
                    )
                } else {
                    resolution = UpdateFeedResolver.FeedResolution(stable: nil, preview: nil)
                }
                guard !Task.isCancelled else { return }
                guard let selectedFeed = resolution.selected else {
                    updateInformation.setUnavailable()
                    AppLogger.shared.write(
                        "UPDATE CHECK prerelease_enabled=true resolved=false " +
                            "stable_version=unknown preview_version=unknown " +
                            "selected_channel=unknown source=cloudflare_channel user_alert=false"
                    )
                    return
                }
                resolvedUpdateFeedURLString = selectedFeed.url.absoluteString
                AppLogger.shared.write(
                    "UPDATE CHECK prerelease_enabled=true resolved=true " +
                        "stable_version=\(resolution.stable?.version ?? "unknown") " +
                        "preview_version=\(resolution.preview?.version ?? "unknown") " +
                        "selected_channel=\(selectedFeed.isPreRelease ? "preview" : "stable") " +
                        "source=\(testFeed == nil ? "cloudflare_channel" : "ui_test")"
                )
            } else {
                guard updateFeedSelection.feedURLString(checksForPreReleaseUpdates: false) != nil else {
                    updateInformation.setUnavailable()
                    AppLogger.shared.write(
                        "UPDATE CHECK prerelease_enabled=false resolved=false " +
                            "source=cloudflare_channel user_alert=false"
                    )
                    return
                }
                AppLogger.shared.write(
                    "UPDATE CHECK prerelease_enabled=false resolved=true " +
                        "selected_channel=stable source=cloudflare_channel"
                )
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

    private func setDockIconVisible(_ isVisible: Bool) {
        model.settings.showDockIcon = isVisible
        updateDockActivationPolicy(source: "dock_toggle")
    }

    private func setStatusBarIconVisible(_ isVisible: Bool) {
        model.settings.showStatusBarIcon = isVisible
        applyStatusBarIconVisibility(isVisible, source: "status_bar_toggle")
    }

    private func applyImportedEntryPointVisibility() {
        updateDockActivationPolicy(source: "configuration_import")
        applyStatusBarIconVisibility(
            model.settings.showStatusBarIcon,
            source: "configuration_import"
        )
    }

    func updateDockActivationPolicy(source: String) {
        entryPointOperationID &+= 1
        let startedAt = ProcessInfo.processInfo.systemUptime
        let policy = SettingsWindowActivationPolicy.value(
            showDockIcon: model.settings.showDockIcon,
            isSettingsWindowOpen: isSettingsWindowOpen
        )
        let fields = "operation_id=\(entryPointOperationID) source=\(source) " +
            "show_dock=\(model.settings.showDockIcon) window_open=\(isSettingsWindowOpen) " +
            "target_policy=\(policy == .regular ? "regular" : "accessory")"
        AppLogger.shared.write("UI DOCK_POLICY phase=requested \(fields)")
        let unchanged = NSApp.activationPolicy() == policy
        let applied = unchanged || NSApp.setActivationPolicy(policy)
        if applied && !unchanged {
            reapplyCurrentAppIcon(source: "activation_policy")
        }
        let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        AppLogger.shared.write(
            "UI DOCK_POLICY phase=completed result=\(applied ? "applied" : "failed") " +
                "reason=\(applied ? "policy_active" : "appkit_rejected") " +
                "elapsed_ms=\(elapsedMilliseconds) dock_visible=unknown \(fields)"
        )
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
