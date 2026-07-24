import AppKit
import Combine
import Darwin
import SwiftUI

@main
enum RemoteMicApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = RemoteMicAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class RemoteMicAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = BridgeAppModel()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: NSWindowController?
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []

    private let connectionItem = NSMenuItem(title: "正在初始化蓝牙", action: nil, keyEquivalent: "")
    private let audioItem = NSMenuItem(title: "未选择语音输出设备", action: nil, keyEquivalent: "")
    private let hidItem = NSMenuItem(title: "按键映射未启用", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalHandlers()
        configureStatusItem()
        observeModel()
        model.startIfNeeded()
        refreshMenuStatus()
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
            button.toolTip = "无线麦"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            if let image = statusImage(isStreaming: false) {
                button.image = image
            } else {
                button.title = "小米遥控器"
            }
        }

        connectionItem.isEnabled = false
        audioItem.isEnabled = false
        hidItem.isEnabled = false

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(connectionItem)
        menu.addItem(audioItem)
        menu.addItem(hidItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("立即重新连接", action: #selector(reconnect)))
        menu.addItem(menuItem("打开设置…", action: #selector(showSettings)))
        menu.addItem(menuItem("显示日志", action: #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(menuItem("关于无线麦", action: #selector(showAbout)))
        menu.addItem(menuItem("GitHub", action: #selector(openGitHub)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出", action: #selector(quit)))
        statusMenu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
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

    private func refreshMenuStatus() {
        connectionItem.title = model.connectionStatus
        audioItem.title = model.isStreaming ? "语音中" : model.audioStatus
        hidItem.title = model.hidStatus
        statusItem?.button?.image = statusImage(isStreaming: model.isStreaming)
    }

    private func statusImage(isStreaming: Bool) -> NSImage? {
        let resourceName = isStreaming ? "StatusIconActiveTemplate" : "StatusIconTemplate"
        let fallbackSymbol = isStreaming ? "mic.fill" : "dot.radiowaves.left.and.right"
        let accessibilityDescription = isStreaming ? "小米遥控器语音中" : "小米遥控器"
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
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "无线麦"
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
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openGitHub() {
        guard let url = URL(string: "https://github.com/HD838A/remote-mic-app") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
