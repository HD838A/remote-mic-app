import AppKit
import Combine
import Darwin
import Sparkle
import SwiftUI

@main
enum RemoteMicApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = RemoteMicAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(delegate.activationPolicy)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class RemoteMicAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
    SPUUpdaterDelegate
{
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let draft: Bool
        let assets: [Asset]
    }

    private enum UpdateFeedError: Error {
        case invalidResponse
        case feedNotFound
    }

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/HD838A/remote-mic-app/releases?per_page=30"
    )!
    private static let preReleaseFeedRefreshInterval: TimeInterval = 6 * 60 * 60

    private let model = BridgeAppModel()
    private lazy var localization = LocalizationStore(settings: model.settings)
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: NSWindowController?
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var preReleaseFeedURL: URL?
    private var updateFeedRefreshTask: Task<Void, Never>?
    private var updateFeedRefreshTimer: Timer?
    private var updaterStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private let connectionItem = NSMenuItem()
    private let audioItem = NSMenuItem()
    private let hidItem = NSMenuItem()

    var activationPolicy: NSApplication.ActivationPolicy {
        model.settings.showDockIcon ? .regular : .accessory
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
        configureStatusItem()
        observeModel()
        observeLocalization()
        observePhoneRemoteButtonTitles()
        model.startIfNeeded()
        refreshMenuStatus()

        if completedUpdate || model.settings.openMainWindowAtLaunch {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.showSettings()
                if completedUpdate {
                    self.showUpdateCompletedAlert()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        updateFeedRefreshTask?.cancel()
        updateFeedRefreshTimer?.invalidate()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
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
        menu.addItem(menuItem("about.support.website_chinese", action: #selector(openChineseWebsite)))
        menu.addItem(menuItem("about.support.website_english", action: #selector(openEnglishWebsite)))
        menu.addItem(.separator())
        menu.addItem(menuItem("common.action.quit", action: #selector(quit)))
        statusMenu = menu
        refreshMenuStatus()
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
    }

    private func observeLocalization() {
        localization.$locale
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem?.button?.toolTip = self.localization.text("app.name")
                self.settingsWindowController?.window?.title = self.localization.text("app.name")
                self.rebuildStatusMenu()
            }
            .store(in: &subscriptions)
    }

    private func observePhoneRemoteButtonTitles() {
        Publishers.CombineLatest3(
            model.settings.$buttonBindings,
            model.settings.$buttonShortcuts,
            localization.$locale
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] bindings, shortcuts, _ in
            guard let self else { return }
            model.updatePhoneRemoteButtonTitles(
                bindings: bindings,
                shortcuts: shortcuts,
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
                preReleaseFeedURL = nil
                configurePreReleaseFeedRefreshTimer(isEnabled: isEnabled)
                startUpdaterIfNeeded()
                if isEnabled {
                    refreshPreReleaseFeed(resetUpdateCycleWhenChanged: true)
                } else {
                    updaterController.updater.resetUpdateCycleAfterShortDelay()
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
        refreshPreReleaseFeed(startUpdaterAfterRefresh: true)
    }

    private func startUpdaterIfNeeded() {
        guard !updaterStarted else { return }
        _ = updaterController
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

    private func refreshPreReleaseFeed(
        startUpdaterAfterRefresh: Bool = false,
        resetUpdateCycleWhenChanged: Bool = false
    ) {
        updateFeedRefreshTask?.cancel()
        updateFeedRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolvedURL = try await Self.latestReleaseFeedURL()
                guard !Task.isCancelled, model.settings.checksForPreReleaseUpdates else { return }
                let feedChanged = preReleaseFeedURL != resolvedURL
                preReleaseFeedURL = resolvedURL
                AppLogger.shared.write("UPDATE FEED prerelease_enabled=true resolved=true")
                if startUpdaterAfterRefresh {
                    startUpdaterIfNeeded()
                } else if feedChanged, resetUpdateCycleWhenChanged {
                    updaterController.updater.resetUpdateCycleAfterShortDelay()
                }
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.shared.write(
                    "UPDATE FEED prerelease_enabled=true resolved=false error=\(error.localizedDescription)"
                )
                if startUpdaterAfterRefresh {
                    startUpdaterIfNeeded()
                }
            }
        }
    }

    private static func latestReleaseFeedURL() async throws -> URL {
        var request = URLRequest(url: releasesURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RemoteMic", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateFeedError.invalidResponse
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let feedURL = releases.lazy
            .filter({ !$0.draft })
            .flatMap(\.assets)
            .first(where: { $0.name == "appcast.xml" })?
            .browserDownloadURL
        else {
            throw UpdateFeedError.feedNotFound
        }
        return feedURL
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard model.settings.checksForPreReleaseUpdates else { return nil }
        return preReleaseFeedURL?.absoluteString
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
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController()
        }
        guard let windowController = settingsWindowController,
              let window = windowController.window else { return }
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: SettingsView(
                model: model,
                checkForUpdates: { [weak self] in self?.checkForUpdates() },
                setDockIconVisible: { [weak self] isVisible in
                    self?.setDockIconVisible(isVisible)
                }
            )
            .environmentObject(localization)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localization.text("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 650)
        window.setFrameAutosaveName("RemoteMicSettings")
        window.center()
        return NSWindowController(window: window)
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
        updateFeedRefreshTask?.cancel()
        updateFeedRefreshTask = Task { [weak self] in
            guard let self else { return }
            if model.settings.checksForPreReleaseUpdates {
                do {
                    preReleaseFeedURL = try await Self.latestReleaseFeedURL()
                    guard !Task.isCancelled,
                          model.settings.checksForPreReleaseUpdates
                    else { return }
                    AppLogger.shared.write("UPDATE CHECK prerelease_enabled=true resolved=true")
                } catch {
                    guard !Task.isCancelled else { return }
                    AppLogger.shared.write(
                        "UPDATE CHECK prerelease_enabled=true resolved=false error=\(error.localizedDescription)"
                    )
                    guard preReleaseFeedURL != nil else {
                        startUpdaterIfNeeded()
                        showPreReleaseFeedUnavailableAlert()
                        return
                    }
                }
            } else {
                preReleaseFeedURL = nil
            }
            startUpdaterIfNeeded()
            updaterController.checkForUpdates(nil)
        }
    }

    private func showPreReleaseFeedUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localization.text("update.prerelease.feed_unavailable.title")
        alert.informativeText = localization.text("update.prerelease.feed_unavailable.message")
        alert.addButton(withTitle: localization.text("common.action.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
        if isVisible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openGitHub() {
        guard let url = URL(string: "https://github.com/HD838A/remote-mic-app") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openChineseWebsite() {
        guard let url = URL(string: "https://8586ai.com/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openEnglishWebsite() {
        guard let url = URL(string: "https://8586ai.com/en/") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
