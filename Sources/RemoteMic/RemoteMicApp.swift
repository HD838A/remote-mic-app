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
private final class RemoteMicAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = BridgeAppModel()
    private lazy var localization = LocalizationStore(settings: model.settings)
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: NSWindowController?
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
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
        _ = updaterController
        installTerminationSignalHandlers()
        configureStatusItem()
        observeModel()
        observeLocalization()
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
            button.toolTip = localization.text("无线麦")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            if let image = statusImage(isStreaming: false) {
                button.image = image
            } else {
                button.title = localization.text("小米遥控器")
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
        menu.addItem(menuItem("立即重新连接", action: #selector(reconnect)))
        menu.addItem(menuItem("打开设置…", action: #selector(showSettings)))
        menu.addItem(menuItem("显示日志", action: #selector(showLog)))
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())
        menu.addItem(menuItem("关于无线麦", action: #selector(showAbout)))
        menu.addItem(versionMenuItem())
        menu.addItem(menuItem("检查更新…", action: #selector(checkForUpdates)))
        menu.addItem(menuItem("GitHub", action: #selector(openGitHub)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", action: #selector(quit)))
        statusMenu = menu
        refreshMenuStatus()
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: localization.text(title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func languageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: localization.text("语言"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let title: String
            switch language {
            case .system:
                title = localization.text("跟随系统")
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
        ) as? String ?? localization.text("未知")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let title = build.map {
            String(
                format: localization.text("版本 %@ (%@)"),
                locale: localization.locale,
                arguments: [shortVersion, $0]
            )
        } ?? String(
            format: localization.text("版本 %@"),
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
                self.statusItem?.button?.toolTip = self.localization.text("无线麦")
                self.settingsWindowController?.window?.title = self.localization.text("无线麦")
                self.rebuildStatusMenu()
            }
            .store(in: &subscriptions)
    }

    private func refreshMenuStatus() {
        connectionItem.title = model.connectionStatus.text(using: localization)
        audioItem.title = model.isStreaming
            ? localization.text("语音中")
            : model.audioStatus.text(using: localization)
        hidItem.title = model.hidStatus.text(using: localization)
        statusItem?.button?.image = statusImage(isStreaming: model.isStreaming)
    }

    private func statusImage(isStreaming: Bool) -> NSImage? {
        let resourceName = isStreaming ? "StatusIconActiveTemplate" : "StatusIconTemplate"
        let fallbackSymbol = isStreaming ? "mic.fill" : "dot.radiowaves.left.and.right"
        let accessibilityDescription = localization.text(
            isStreaming ? "小米遥控器语音中" : "小米遥控器"
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localization.text("无线麦")
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
        ) as? String ?? localization.text("未知")
        let alert = NSAlert()
        alert.messageText = localization.text("无线麦")
        alert.informativeText = String(
            format: localization.text("版本 %@\nRC003 蓝牙语音遥控器桥接工具。"),
            locale: localization.locale,
            arguments: [shortVersion]
        )
        alert.addButton(withTitle: localization.text("好"))
        alert.runModal()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue)
        else { return }
        localization.select(language)
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func showUpdateCompletedAlert() {
        guard let window = settingsWindowController?.window else { return }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("未知")
        let alert = NSAlert()
        alert.messageText = localization.text("无线麦已更新")
        alert.informativeText = String(
            format: localization.text("已成功更新到版本 %@。"),
            locale: localization.locale,
            arguments: [version]
        )
        alert.addButton(withTitle: localization.text("好"))
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
