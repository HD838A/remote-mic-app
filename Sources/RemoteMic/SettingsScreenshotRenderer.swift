import AppKit
import SwiftUI

@MainActor
enum SettingsScreenshotRenderer {
    private enum RenderingError: Error, LocalizedError {
        case invalidSize(String)
        case invalidAppearance(String)
        case invalidLanguage(String)
        case bitmapCreationFailed
        case pngCreationFailed

        var errorDescription: String? {
            switch self {
            case let .invalidSize(value):
                return "Unsupported settings screenshot size: \(value). Use WIDTHxHEIGHT."
            case let .invalidAppearance(value):
                return "Unsupported settings screenshot appearance: \(value)."
            case let .invalidLanguage(value):
                return "Unsupported settings screenshot language: \(value)."
            case .bitmapCreationFailed:
                return "The settings screenshot bitmap could not be created."
            case .pngCreationFailed:
                return "The settings screenshot bitmap could not be encoded as PNG."
            }
        }
    }

    private static let sections: [SettingsSection] = [
        .mapping,
        .macros,
        .buttonProfiles,
        .membership,
        .statistics,
        .transcripts,
        .connection,
        .about,
    ]

    static func renderAll(
        to outputDirectory: URL,
        sizeValue: String?,
        appearanceName: String?,
        languageName: String?
    ) throws {
        let size = try screenshotSize(from: sizeValue)
        let appearance = try screenshotAppearance(from: appearanceName)
        let language = try screenshotLanguage(from: languageName)
        let opensShortcutEditor = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_SHORTCUT_EDITOR"
        ] == "1"
        let opensApplicationEditor = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_APPLICATION_EDITOR"
        ] == "1"
        let opensAgentSwitcherEditor = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_AGENT_SWITCHER_EDITOR"
        ] == "1"
        let showsStandardKeyboard = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_SHORTCUT_MODE"
        ] == "keyboard"
        let expandsShare = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_EXPAND_SHARE"
        ] == "1"
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let suiteName = "RemoteMic.SettingsScreenshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RenderingError.bitmapCreationFailed
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = language
        settings.completeOnboarding()
        if opensShortcutEditor {
            settings.customMappingEnabled = true
            settings.setAction(.customShortcut, for: .ok, trigger: .singleClick)
            settings.setShortcut(
                KeyboardShortcutPreset.spotlight.shortcut,
                for: .ok,
                trigger: .singleClick
            )
        }
        if opensApplicationEditor {
            seedApplicationEditorForScreenshot(settings)
        }
        if opensAgentSwitcherEditor {
            settings.customMappingEnabled = true
            settings.setAction(.agentSwitcher, for: .ok, trigger: .singleClick)
        }
        seedStatisticsForScreenshot(settings)
        let model = BridgeAppModel(settings: settings)
        let updateInformation = UpdateInformationStore()
        seedAvailableUpdate(updateInformation, language: language)
        let localization = LocalizationStore(settings: settings)
        model.privateFeature.updateLocaleIdentifier(localization.locale.identifier)
        model.macroFeature.updateLocaleIdentifier(localization.locale.identifier)
        model.membershipFeature.updateLocaleIdentifier(localization.locale.identifier)

        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }

        for section in sections {
            let rootView = SettingsView(
                model: model,
                updateInformation: updateInformation,
                initialSection: section,
                initialShareSection: section == .about && expandsShare ? section : nil,
                initialMappingEditingButton: section == .mapping && (opensShortcutEditor || opensApplicationEditor || opensAgentSwitcherEditor)
                    ? .ok
                    : nil,
                initialShortcutPickerShowsKeyboard: showsStandardKeyboard,
                minimumContentSize: .zero
            )
            .environmentObject(localization)
            .frame(width: size.width, height: size.height)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hostingController
            window.setContentSize(size)
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()

            guard let contentView = window.contentView,
                  contentView.bounds.size == size,
                  let representation = contentView.bitmapImageRepForCachingDisplay(
                      in: contentView.bounds
                  )
            else {
                throw RenderingError.bitmapCreationFailed
            }
            contentView.cacheDisplay(in: contentView.bounds, to: representation)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                throw RenderingError.pngCreationFailed
            }
            let filename = String(
                format: "%@-%dx%d.png",
                section.rawValue,
                Int(size.width),
                Int(size.height)
            )
            try png.write(to: outputDirectory.appendingPathComponent(filename))
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }

    private static func seedApplicationEditorForScreenshot(_ settings: AppSettings) {
        settings.customMappingEnabled = true
        let focusShortcut = CustomKeyboardShortcut(
            keyCode: 37,
            modifierFlags: [.command],
            keyLabel: "L"
        )
        let cursorProfileID = settings.upsertCustomApplicationProfile(
            displayName: "Cursor",
            bundleIdentifier: PresetApplication.cursor.bundleIdentifier,
            applicationPath: "/Applications/Cursor.app"
        )
        let codexProfileID = settings.upsertCustomApplicationProfile(
            displayName: "Codex",
            bundleIdentifier: PresetApplication.codex.bundleIdentifier,
            applicationPath: "/Applications/Codex.app"
        )
        for profileID in [cursorProfileID, codexProfileID] {
            guard var profile = settings.customApplicationProfile(id: profileID) else { continue }
            profile.focusStrategy = .keyboardShortcut
            profile.focusShortcut = focusShortcut
            settings.updateCustomApplicationProfile(profile)
        }
        settings.setAction(.openCustomApplication, for: .ok, trigger: .singleClick)
        settings.setApplicationProfileID(cursorProfileID, for: .ok, trigger: .singleClick)
    }

    private static func seedAvailableUpdate(
        _ updateInformation: UpdateInformationStore,
        language: AppLanguage
    ) {
        let notes: String
        switch language {
        case .simplifiedChinese:
            notes = "优化设置页面结构\n权限与日志集中管理\n修复已知问题"
        case .system, .english:
            notes = "Refined the Settings layout\nCentralized permissions and logs\nFixed known issues"
        }
        updateInformation.setAvailable(
            displayVersion: "1.9.22",
            buildVersion: "183",
            archiveURL: nil,
            fallbackDescription: notes,
            localeIdentifier: language.rawValue
        )
    }

    private static func seedStatisticsForScreenshot(_ settings: AppSettings) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<364 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let buttonCount = (offset % 17 == 0) ? 9 : (offset % 5 == 0 ? 4 : (offset % 3 == 0 ? 1 : 0))
            for index in 0..<buttonCount {
                let button = RemoteButton.allCases[(offset + index) % RemoteButton.allCases.count]
                settings.recordButtonPress(
                    control: .remoteButton(button),
                    source: .bluetoothRemote,
                    at: date.addingTimeInterval(Double(index) * 11),
                    calendar: calendar
                )
            }
            if offset % 11 == 0 {
                settings.recordVoiceDuration(
                    TimeInterval(18 + (offset * 13) % 95),
                    startedAt: date.addingTimeInterval(3600),
                    source: .bluetoothRemote,
                    applicationName: ["Codex", "Claude", "Notion", "Zoom", "Slack"][(offset / 11) % 5],
                    at: date.addingTimeInterval(3660),
                    calendar: calendar
                )
            }
        }
        let topSessions: [(TimeInterval, String)] = [
            (85, "Codex"), (38, "Claude"), (38, "Notion"), (37, "Zoom"),
            (37, "Slack"), (29, "Figma"), (28, "VS Code"),
        ]
        for (index, session) in topSessions.enumerated() {
            let date = today.addingTimeInterval(-Double(index * 86_400 + 2_000))
            settings.recordVoiceDuration(
                session.0,
                startedAt: date.addingTimeInterval(-session.0),
                source: .bluetoothRemote,
                applicationName: session.1,
                at: date,
                calendar: calendar
            )
        }
    }

    private static func screenshotSize(from value: String?) throws -> NSSize {
        let value = value ?? "1020x772"
        let components = value.lowercased().split(separator: "x")
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width >= 800,
              height >= 650
        else {
            throw RenderingError.invalidSize(value)
        }
        return NSSize(width: width, height: height)
    }

    private static func screenshotAppearance(from value: String?) throws -> NSAppearance? {
        switch value?.lowercased() ?? "light" {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        case "system": return nil
        case let value: throw RenderingError.invalidAppearance(value)
        }
    }

    private static func screenshotLanguage(from value: String?) throws -> AppLanguage {
        switch value?.lowercased() ?? "zh-hans" {
        case "zh-hans", "zh", "chinese": return .simplifiedChinese
        case "en", "english": return .english
        case let value: throw RenderingError.invalidLanguage(value)
        }
    }
}
