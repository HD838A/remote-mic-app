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
        .statistics,
        .transcripts,
        .connection,
        .permissions,
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
        let opensVoiceShortcutEditor = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_VOICE_SHORTCUT_EDITOR"
        ] == "1"
        let showsVoiceShortcutConflict = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_VOICE_SHORTCUT_CONFLICT"
        ] == "1"
        let showsStandardKeyboard = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_SHORTCUT_MODE"
        ] == "keyboard"
        let showsConnectedRemote = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_CONNECTED_REMOTE"
        ] == "1"
        let showsTranscriptAudio = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_TRANSCRIPT_AUDIO"
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
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMic.SettingsScreenshot.\(UUID().uuidString)")
        let transcriptArchiveStore = TranscriptArchiveStore(
            rootDirectoryURL: fixtureRoot.appendingPathComponent("Transcripts/v1")
        )
        let voiceAudioRoot = fixtureRoot.appendingPathComponent("TranscriptAudio/v1")
        let voiceAudioArchiveStore = VoiceAudioArchiveStore(rootDirectoryURL: voiceAudioRoot)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        if showsTranscriptAudio {
            settings.localTranscriptHistoryEnabled = true
            settings.localTranscriptAudioRetentionEnabled = true
            let now = Date()
            let availableSessionID = UUID()
            let availableFileName = "\(availableSessionID.uuidString).m4a"
            try FileManager.default.createDirectory(
                at: voiceAudioRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data([0]).write(
                to: voiceAudioRoot.appendingPathComponent(availableFileName)
            )
            let sampleText = language == .english
                ? "A voice entry captured from the remote."
                : "这是一次使用遥控器完成的语音输入。"
            try transcriptArchiveStore.append(TranscriptRecord(
                sessionID: availableSessionID,
                startedAt: now.addingTimeInterval(-14),
                endedAt: now.addingTimeInterval(-10),
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                source: .bluetoothRemote,
                originalTranscript: sampleText,
                audio: TranscriptAudioAttachment(
                    fileName: availableFileName,
                    duration: 4,
                    expiresAt: now.addingTimeInterval(4 * 60 * 60 - 10)
                )
            ))
            let expiredSessionID = UUID()
            try transcriptArchiveStore.append(TranscriptRecord(
                sessionID: expiredSessionID,
                startedAt: now.addingTimeInterval(-34),
                endedAt: now.addingTimeInterval(-30),
                applicationName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                source: .bluetoothRemote,
                originalTranscript: "",
                transcriptStatus: .unavailable,
                audio: TranscriptAudioAttachment(
                    fileName: "\(expiredSessionID.uuidString).m4a",
                    duration: 4,
                    expiresAt: now.addingTimeInterval(-1)
                )
            ))
        }
        if opensShortcutEditor || opensVoiceShortcutEditor {
            settings.customMappingEnabled = true
        }
        if opensShortcutEditor {
            settings.setAction(.customShortcut, for: .ok, trigger: .singleClick)
            settings.setShortcut(
                KeyboardShortcutPreset.spotlight.shortcut,
                for: .ok,
                trigger: .singleClick
            )
        }
        if opensVoiceShortcutEditor {
            settings.voiceTriggerShortcut = showsVoiceShortcutConflict
                ? KeyboardShortcutPreset.quitApplication.shortcut
                : StandaloneKeyboardModifier.leftControl.shortcut
        }
        let simulatedProfileID: UUID? = showsConnectedRemote
            ? settings.registerBluetoothRemote(
                identifier: UUID(uuidString: "C4B6E236-2C5E-49D6-9D5A-5B8794DCE2E3")!
            )
            : nil
        if let simulatedProfileID {
            settings.updateRemoteProfileModel(simulatedProfileID, model: .rc003)
            settings.selectRemoteProfile(simulatedProfileID)
        }
        let simulatedProfileIDs = simulatedProfileID.map { Set([$0]) } ?? []
        let model = BridgeAppModel(
            settings: settings,
            initialConnectedRemoteProfileIDs: simulatedProfileIDs,
            initialRemoteBatteryLevels: simulatedProfileID.map { [$0: 86] } ?? [:],
            initialRemotePowerStates: simulatedProfileID.map { [$0: .onBattery] } ?? [:],
            initialRemoteVoiceLevels: simulatedProfileID.map { [$0: 0.68] } ?? [:],
            transcriptArchiveStore: transcriptArchiveStore,
            voiceAudioArchiveStore: voiceAudioArchiveStore
        )
        let updateInformation = UpdateInformationStore()
        let localization = LocalizationStore(settings: settings)
        model.privateFeature.updateLocaleIdentifier(localization.locale.identifier)
        model.macroFeature.updateLocaleIdentifier(localization.locale.identifier)

        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        defer { NSApp.appearance = previousAppearance }

        for section in sections {
            let rootView = SettingsView(
                model: model,
                updateInformation: updateInformation,
                initialSection: section,
                initialShareSection: section == .statistics || section == .about
                    ? section
                    : nil,
                initialMappingEditingButton: section == .mapping && opensShortcutEditor
                    ? .ok
                    : nil,
                initialVoiceShortcutEditorPresented: section == .mapping && opensVoiceShortcutEditor,
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
