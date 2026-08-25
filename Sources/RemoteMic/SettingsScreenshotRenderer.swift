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
        let showsStandardKeyboard = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_SHORTCUT_MODE"
        ] == "keyboard"
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
        let model = BridgeAppModel(settings: settings)
        let updateInformation = UpdateInformationStore()
        if ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_UPDATE_STATE"
        ] == "up-to-date" {
            updateInformation.setUpToDate()
        }
        let localization = LocalizationStore(settings: settings)
        model.privateFeature.updateLocaleIdentifier(localization.locale.identifier)
        model.macroFeature.updateLocaleIdentifier(localization.locale.identifier)

        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = appearance
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        defer { NSApp.appearance = previousAppearance }

        for section in sections {
            let rootView = SettingsView(
                model: model,
                updateInformation: updateInformation,
                initialSection: section,
                initialShareExpanded: section == .about,
                initialMappingEditingButton: section == .mapping && opensShortcutEditor
                    ? .ok
                    : nil,
                initialShortcutPickerShowsKeyboard: showsStandardKeyboard,
                minimumContentSize: .zero
            )
            .environmentObject(localization)
            let hostingController = NSHostingController(rootView: rootView)
            let styleMask: NSWindow.StyleMask = [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ]
            let frameRect = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: NSWindow.contentRect(
                    forFrameRect: frameRect,
                    styleMask: styleMask
                ),
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance
            window.title = localization.text("app.name")
            window.titleVisibility = .visible
            window.toolbarStyle = .unified
            window.contentViewController = hostingController
            window.setFrame(frameRect, display: false)
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()

            let png = try windowPNG(window)
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
        let value = value ?? "920x700"
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

    private static func windowPNG(_ window: NSWindow) throws -> Data {
        if let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            let representation = NSBitmapImageRep(cgImage: image)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                throw RenderingError.pngCreationFailed
            }
            return png
        }

        guard let contentView = window.contentView,
              !contentView.bounds.isEmpty,
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
        return png
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
