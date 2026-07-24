import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum KeyboardInjector {
    typealias ApplicationOpener = (
        URL,
        PresetApplication,
        @escaping (Error?) -> Void
    ) -> Void

    static let syntheticEventMarker: Int64 = 0x5849_414F
    static let contextualMenuKeyCode: CGKeyCode = 110

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func send(
        _ action: ButtonAction,
        applicationURL: (String) -> URL? = {
            if $0 == PresetApplication.remoteMic.bundleIdentifier {
                return Bundle.main.bundleURL
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationOpener: ApplicationOpener = openApplication
    ) -> Bool {
        guard action != .disabled else { return true }
        if let application = action.presetApplication {
            open(
                application,
                applicationURL: applicationURL,
                applicationOpener: applicationOpener
            )
            return true
        }
        guard isAccessibilityTrusted else { return false }

        switch action {
        case .disabled:
            return true
        case .escape:
            postKey(code: 53)
        case .returnKey:
            postKey(code: 36)
        case .arrowUp:
            postKey(code: 126)
        case .arrowDown:
            postKey(code: 125)
        case .arrowLeft:
            postKey(code: 123)
        case .arrowRight:
            postKey(code: 124)
        case .deleteBackward:
            postKey(code: 51)
        case .showDesktop:
            postKey(code: 103, flags: .maskSecondaryFn)
        case .contextMenu:
            postKey(code: contextualMenuKeyCode)
        case .appSwitcher:
            postKey(code: 48, flags: .maskCommand)
        case .volumeUp:
            postSystemKey(type: 0)
        case .volumeDown:
            postSystemKey(type: 1)
        case .volumeMute:
            postSystemKey(type: 7)
        case .playPause:
            postSystemKey(type: 16)
        case .openRemoteMic, .openCodex, .openClaude, .openCmux, .openWeChat, .openCursor, .openXcode,
             .openSlack, .openWeCom, .openNeteaseMusic, .openChrome, .openSafari, .openZed:
            break
        }
        return true
    }

    private static func open(
        _ application: PresetApplication,
        applicationURL: (String) -> URL?,
        applicationOpener: ApplicationOpener
    ) {
        guard let url = applicationURL(application.bundleIdentifier) else {
            AppLogger.shared.write("APP ACTION unavailable bundle=\(application.bundleIdentifier)")
            return
        }

        applicationOpener(url, application) { error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) error=\(error.localizedDescription)"
                )
            } else {
                AppLogger.shared.write("APP ACTION opened bundle=\(application.bundleIdentifier)")
            }
        }
    }

    private static func openApplication(
        at url: URL,
        application: PresetApplication,
        completion: @escaping (Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            completion(error)
        }
    }

    private static func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postSystemKey(type: Int32) {
        postSystemKey(type: type, isDown: true)
        postSystemKey(type: type, isDown: false)
    }

    private static func postSystemKey(type: Int32, isDown: Bool) {
        let keyState = isDown ? 0xA : 0xB
        let data1 = Int((type << 16) | Int32(keyState << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        guard let cgEvent = event.cgEvent else { return }
        cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }
}
