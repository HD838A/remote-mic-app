import AppKit
import SwiftUI

@MainActor
enum OnboardingScreenshotRenderer {
    private enum RenderingError: Error, LocalizedError {
        case invalidAppearance(String)
        case missingFrameView
        case bitmapCreationFailed
        case pngCreationFailed

        var errorDescription: String? {
            switch self {
            case let .invalidAppearance(value):
                return "Unsupported screenshot appearance: \(value). Use light, dark, or system."
            case .missingFrameView:
                return "The offscreen window frame view is unavailable."
            case .bitmapCreationFailed:
                return "The offscreen window bitmap could not be created."
            case .pngCreationFailed:
                return "The offscreen window bitmap could not be encoded as PNG."
            }
        }
    }

    private enum ScreenshotAppearance: String {
        case light
        case dark
        case system

        init(environmentValue: String?) throws {
            let value = environmentValue?.lowercased() ?? Self.light.rawValue
            guard let appearance = Self(rawValue: value) else {
                throw RenderingError.invalidAppearance(value)
            }
            self = appearance
        }

        var appKitAppearance: NSAppearance? {
            switch self {
            case .light:
                return NSAppearance(named: .aqua)
            case .dark:
                return NSAppearance(named: .darkAqua)
            case .system:
                return nil
            }
        }
    }

    private static let pages: [(OnboardingStep, String)] = [
        (.welcome, "01-welcome.png"),
        (.voiceTool, "02-voice-tool.png"),
        (.permissions, "03-permissions.png"),
        (.remote, "04-remote.png"),
        (.audio, "05-audio.png"),
        (.voiceTest, "06-voice-test.png"),
        (.controls, "07-controls.png"),
        (.complete, "08-complete.png"),
    ]

    static func renderAll(to outputDirectory: URL, appearanceName: String?) throws {
        let screenshotAppearance = try ScreenshotAppearance(environmentValue: appearanceName)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let suiteName = "RemoteMic.OnboardingScreenshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw RenderingError.bitmapCreationFailed
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        settings.setOnboardingVoiceTool(.typeless)
        let model = BridgeAppModel(settings: settings)
        let localization = LocalizationStore(settings: settings)

        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = screenshotAppearance.appKitAppearance
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.appearance = previousAppearance }

        for (step, filename) in pages {
            settings.setOnboardingStep(step)
            let rootView = OnboardingView(model: model)
                .environmentObject(localization)
                .frame(width: 1020, height: 772)
            let hostingController = NSHostingController(rootView: rootView)
            let window = makeWindow(hostingController: hostingController)

            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()

            guard let frameView = window.contentView?.superview else {
                throw RenderingError.missingFrameView
            }
            frameView.layoutSubtreeIfNeeded()
            frameView.displayIfNeeded()

            let bounds = frameView.bounds
            guard let representation = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw RenderingError.bitmapCreationFailed
            }
            frameView.cacheDisplay(in: bounds, to: representation)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                throw RenderingError.pngCreationFailed
            }
            try png.write(to: outputDirectory.appendingPathComponent(filename))
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }

    private static func makeWindow<Content: View>(
        hostingController: NSHostingController<Content>
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 772),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "无线麦"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 1020, height: 772)
        window.setContentSize(NSSize(width: 1020, height: 772))
        window.center()
        return window
    }
}
