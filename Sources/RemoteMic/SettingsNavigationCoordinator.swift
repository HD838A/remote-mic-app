import Combine
import Foundation

/// Routes AppKit main-menu commands (back/forward/find/about) into the SwiftUI settings view.
final class SettingsNavigationCoordinator {
    enum Command {
        case goBack
        case goForward
        case focusSearch
        case selectSection(SettingsSection)
    }

    let commands = PassthroughSubject<Command, Never>()

    /// Mirrored from `SettingsView` so the main menu can validate ⌘[ / ⌘].
    var canGoBack = false
    var canGoForward = false

    func goBack() {
        commands.send(.goBack)
    }

    func goForward() {
        commands.send(.goForward)
    }

    func focusSearch() {
        commands.send(.focusSearch)
    }

    func selectSection(_ section: SettingsSection) {
        commands.send(.selectSection(section))
    }
}
