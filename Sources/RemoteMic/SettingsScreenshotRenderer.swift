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
        .commonPhrases,
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
        let opensActionEditor = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_ACTION_EDITOR"
        ] == "1"
        let opensMappingEditor = opensShortcutEditor || opensActionEditor
        let showsStandardKeyboard = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_SHORTCUT_MODE"
        ] == "keyboard"
        let expandsShare = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_EXPAND_SHARE"
        ] == "1"
        let usesSiriRemote = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_SIRI_REMOTE"
        ] == "1"
        let usesChromecast = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_CHROMECAST"
        ] == "1"
        let showsRemoteCards = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_REMOTE_CARDS"
        ] == "1"
        let onlySection = ProcessInfo.processInfo.environment["REMOTE_MIC_SETTINGS_SCREENSHOT_SECTION"]
        let interactive = ProcessInfo.processInfo.environment["REMOTE_MIC_SETTINGS_SCREENSHOT_INTERACTIVE"] == "1"
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
        if let iconIdentifier = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_APP_ICON"
        ] {
            settings.appIconIdentifier = AppIconIdentifier(rawValue: iconIdentifier)
        }
        var remoteCardSystemNames: [UUID: String] = [:]
        var remoteCardBatteryLevels: [UUID: Int] = [:]
        var remoteCardPowerStates: [UUID: RemotePowerState] = [:]
        if showsRemoteCards {
            let xiaomiID = settings.registerBluetoothRemote(
                identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
            )
            settings.updateRemoteProfileModel(xiaomiID, model: .rc003)
            settings.bindHIDFingerprint("settings-screenshot-xiaomi", to: xiaomiID)
            let appleID = settings.registerHIDRemote(fingerprint: "settings-screenshot-apple-remote")
            settings.updateRemoteProfileModel(appleID, model: .appleSiriRemoteA2854)
            let chromecastID = settings.registerChromecastRemote()
            settings.selectRemoteProfile(appleID)
            remoteCardSystemNames = [
                xiaomiID: "书房遥控器",
                appleID: "客厅 Apple TV",
                chromecastID: "Bedroom Remote",
            ]
            remoteCardBatteryLevels = [
                xiaomiID: 78,
                chromecastID: 42,
            ]
            remoteCardPowerStates = [
                xiaomiID: .charging,
                chromecastID: .onBattery,
            ]
        }
#if SAYALL_SIRI_REMOTE_ENABLED
        if usesSiriRemote {
            let profileID = settings.registerAppleSiriRemote(
                fingerprint: "settings-screenshot-siri-remote"
            )
            settings.selectRemoteProfile(profileID)
        }
#else
        _ = usesSiriRemote
#endif
#if SAYALL_CHROMECAST_ENABLED
        if usesChromecast {
            let profileID = settings.registerChromecastRemote()
            settings.selectRemoteProfile(profileID)
        }
#else
        _ = usesChromecast
#endif
        if opensShortcutEditor {
            settings.customMappingEnabled = true
            settings.setAction(.customShortcut, for: .ok, trigger: .singleClick)
            settings.setShortcut(
                KeyboardShortcutPreset.spotlight.shortcut,
                for: .ok,
                trigger: .singleClick
            )
        }
        seedStatisticsForScreenshot(settings)
        let historyDirectory = outputDirectory.appendingPathComponent(UUID().uuidString)
        let model = BridgeAppModel(
            settings: settings,
            commonPhraseStore: CommonPhraseStore(defaults: defaults),
            transcriptArchiveStore: TranscriptArchiveStore(
                rootDirectoryURL: historyDirectory.appendingPathComponent("transcripts")
            ),
            recordingAssetStore: RecordingAssetStore(
                rootDirectoryURL: historyDirectory.appendingPathComponent("recordings")
            )
        )
        if showsRemoteCards {
            model.configureRemoteCardsForSettingsScreenshot(
                profileIDs: Set(remoteCardSystemNames.keys),
                systemNames: remoteCardSystemNames,
                batteryLevels: remoteCardBatteryLevels,
                powerStates: remoteCardPowerStates
            )
        }
        let updateInformation = UpdateInformationStore(userDefaults: defaults)
        seedAvailableUpdate(updateInformation, language: language)
        if ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_UPDATE_SEEN"
        ] == "1" {
            updateInformation.markAvailableUpdateSeen()
        }
        let localization = LocalizationStore(settings: settings, resourceBundle: RemoteMicResourceBundle.mainOrDevelopment)
        model.privateFeature.updateLocaleIdentifier(localization.locale.identifier)
        model.macroFeature.updateLocaleIdentifier(localization.locale.identifier)
        model.membershipFeature.updateLocaleIdentifier(localization.locale.identifier)

        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }
        if interactive {
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
        }

        // Interactive review uses the production view, navigation and window geometry,
        // with the same isolated fixture settings as the offscreen renderer.
        if ProcessInfo.processInfo.environment["REMOTE_MIC_SETTINGS_SCREENSHOT_INTERACTIVE"] == "1" {
            let section = sections.first { $0.rawValue == onlySection } ?? .mapping
            let controller = NSHostingController(rootView: SettingsView(
                model: model,
                updateInformation: updateInformation,
                initialSection: section,
                initialShareSection: section == .statistics && expandsShare ? section : nil,
                initialMappingEditingButton: section == .mapping && opensMappingEditor ? .ok : nil,
                initialShortcutPickerShowsKeyboard: showsStandardKeyboard
            ).environmentObject(localization))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "SayAll — Settings Review"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1020, height: 772)
            window.contentViewController = controller
            window.setContentSize(size)
            window.center()
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.run()
            return
        }

        for section in sections where onlySection == nil || onlySection == section.rawValue {
            let rootView = SettingsView(
                model: model,
                updateInformation: updateInformation,
                initialSection: section,
                initialShareSection: section == .statistics && expandsShare ? section : nil,
                initialMappingEditingButton: section == .mapping && opensMappingEditor
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
                styleMask: interactive ? [.titled, .closable, .resizable] : [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = hostingController
            window.title = "SayAll — UI check"
            window.setContentSize(size)
            window.orderFront(nil)
            if interactive {
                // The production settings view uses isolated screenshot data;
                // this bounded mode permits clicks without starting hardware.
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let deadline = Date().addingTimeInterval(300)
                while window.isVisible && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            }
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

        // Capture the same nonactivating panel view used for real input. This
        // hidden renderer neither opens a remote session nor posts text.
        let panelSize = CommonPhrasePanelView.size
        let phrasePanel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        phrasePanel.contentView = NSHostingView(rootView:
            CommonPhrasePanelView(controller: model.commonPhrases).environmentObject(localization))
        phrasePanel.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let view = phrasePanel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw RenderingError.bitmapCreationFailed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let panelPNG = bitmap.representation(using: .png, properties: [:])
        else { throw RenderingError.pngCreationFailed }
        try panelPNG.write(to: outputDirectory.appendingPathComponent("common-phrases-panel.png"))
        phrasePanel.orderOut(nil)
        phrasePanel.contentView = nil
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
