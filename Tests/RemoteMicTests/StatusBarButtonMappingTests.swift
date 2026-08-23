import AppKit
import Foundation
import Testing
@testable import RemoteMic

struct StatusBarButtonMappingTests {
    @Test(
        "Status item click behavior",
        arguments: [
            (isRightClick: true, showDockIcon: true, openMainWindowAtLaunch: true, expected: true),
            (isRightClick: false, showDockIcon: false, openMainWindowAtLaunch: false, expected: true),
            (isRightClick: false, showDockIcon: true, openMainWindowAtLaunch: false, expected: false),
            (isRightClick: false, showDockIcon: false, openMainWindowAtLaunch: true, expected: false),
        ]
    )
    func statusItemClickBehavior(
        scenario: (
            isRightClick: Bool,
            showDockIcon: Bool,
            openMainWindowAtLaunch: Bool,
            expected: Bool
        )
    ) {
        #expect(
            StatusItemClickPolicy.opensMenu(
                isRightClick: scenario.isRightClick,
                showDockIcon: scenario.showDockIcon,
                openMainWindowAtLaunch: scenario.openMainWindowAtLaunch
            ) == scenario.expected
        )
    }

    @Test func quickActionSelectionUpdatesAndPersistsTheSingleClickMapping() throws {
        let suiteName = "RemoteMicTests.StatusBarMapping.Apply.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let selection = StatusBarButtonActionSelection(button: .ok, action: .commandReturn)

        selection.apply(to: settings)

        #expect(settings.configuredAction(for: .ok, trigger: .singleClick).action == .commandReturn)
        #expect(
            AppSettings(defaults: defaults)
                .configuredAction(for: .ok, trigger: .singleClick).action == .commandReturn
        )
    }

    @Test @MainActor func unconfiguredCustomActionsAreNotOfferedInTheQuickMenu() {
        let groups = StatusBarButtonMappingMenuFactory.actionGroups(
            installedBundleIdentifiers: [],
            currentAction: .returnKey,
            experimentalContinuousRecordingEnabled: false,
            hasConfiguredShortcut: false,
            hasConfiguredApplication: false
        )
        let actions = groups.flatMap(\.actions)

        #expect(actions.contains(.customShortcut) == false)
        #expect(actions.contains(.openCustomApplication) == false)
        #expect(actions.contains(.toggleLongRecording) == false)
        #expect(groups.map(\.category) == [.basicKeys, .systemAndMedia])
    }

    @Test @MainActor func configuredCustomActionsRemainAvailableForFastSwitching() {
        let groups = StatusBarButtonMappingMenuFactory.actionGroups(
            installedBundleIdentifiers: [PresetApplication.codex.bundleIdentifier],
            currentAction: .returnKey,
            experimentalContinuousRecordingEnabled: false,
            hasConfiguredShortcut: true,
            hasConfiguredApplication: true
        )
        let actions = groups.flatMap(\.actions)

        #expect(actions.contains(.customShortcut))
        #expect(actions.contains(.openCustomApplication))
        #expect(actions.contains(.openCodex))
        #expect(actions.contains(.openSafari) == false)
        #expect(groups.map(\.category) == ButtonActionCategory.allCases)
    }

    @Test @MainActor func menuReflectsSelectedRemoteAndCurrentButtonAction() throws {
        _ = NSApplication.shared
        let suiteName = "RemoteMicTests.StatusBarMapping.Menu.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let profileID = settings.registerHIDRemote(fingerprint: "status-menu-remote")
        settings.selectRemoteProfile(profileID)
        let localization = LocalizationStore(settings: settings)
        let target = StatusBarMenuTarget()

        let menu = StatusBarButtonMappingMenuFactory.makeMenu(
            settings: settings,
            connectedRemoteProfileIDs: [profileID],
            localization: localization,
            target: target,
            actions: target.actions,
            installedBundleIdentifiers: []
        )

        #expect(menu.items.first?.state == .on)
        let profileSelection = try #require(
            recursivelyFlatten(menu).first { $0.representedObject as? String == profileID.uuidString }
        )
        #expect(profileSelection.state == .on)
        let returnSelection = try #require(
            recursivelyFlatten(menu).first {
                ($0.representedObject as? StatusBarButtonActionSelection) ==
                    StatusBarButtonActionSelection(button: .ok, action: .returnKey)
            }
        )
        #expect(returnSelection.state == .on)
    }
}

@MainActor
private final class StatusBarMenuTarget: NSObject {
    var actions: StatusBarButtonMappingMenuActions {
        StatusBarButtonMappingMenuActions(
            toggleMapping: #selector(handleMenuItem(_:)),
            selectRemoteProfile: #selector(handleMenuItem(_:)),
            selectButtonAction: #selector(handleMenuItem(_:)),
            openFullEditor: #selector(handleMenuItem(_:))
        )
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {}
}

@MainActor
private func recursivelyFlatten(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in
        [item] + (item.submenu.map(recursivelyFlatten) ?? [])
    }
}
