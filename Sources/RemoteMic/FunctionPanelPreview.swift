import AppKit
import Foundation

/// Local visual QA entry for the non-activating function panel.
///
/// The panel normally needs a connected remote. This env-gated entry exists so a
/// developer can inspect the real production panel over the current frontmost app
/// without a remote; it is not reachable from normal app launch.
@MainActor
enum FunctionPanelPreview {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let suiteName = "RemoteMic.FunctionPanelPreview"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            exit(EXIT_FAILURE)
        }
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        let localization = LocalizationStore(settings: settings)
        let controller = FunctionPanelController()
        controller.autoCloseNanoseconds = 120_000_000_000

        let actions: [ButtonAction] = [
            .commandNewTab,
            .commandCopy,
            .commandPaste,
            .focusInput,
            .openCommonPhrases,
            .appSwitcher,
            .openWeChat,
        ]
        let unavailableWeChat = FunctionPanelItem(
            id: "preview:\(ButtonAction.openWeChat.rawValue)",
            title: ButtonAction.openWeChat.displayName(using: localization),
            systemImage: FunctionPanelCatalog.systemImage(for: .openWeChat),
            configuredAction: ConfiguredButtonAction(action: .openWeChat, shortcut: nil),
            unavailableReasonKey: "function_panel.unavailable.app_missing",
            unavailableReasonText: localization.text("function_panel.unavailable.app_missing")
        )
        let items = actions.map { action in
            if action == .openWeChat { return unavailableWeChat }
            return FunctionPanelItem(
                id: "preview:\(action.rawValue)",
                title: action == .openCommonPhrases
                    ? localization.text("common_phrases.title")
                    : action.displayName(using: localization),
                systemImage: FunctionPanelCatalog.systemImage(for: action),
                configuredAction: ConfiguredButtonAction(action: action, shortcut: nil),
                unavailableReasonKey: nil,
                unavailableReasonText: nil
            )
        }

        controller.present(
            items: items,
            emptyText: localization.text("function_panel.empty"),
            panelTitle: localization.text("function_panel.title"),
            openButton: nil,
            execute: { _ in false },
            showUnavailable: { _ in }
        )
        fputs(
            "Function panel preview: visual QA only; no remote, audio, or HID is started.\n",
            stderr
        )
        app.run()
        exit(EXIT_SUCCESS)
    }
}
