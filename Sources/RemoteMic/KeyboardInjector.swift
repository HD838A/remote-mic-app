import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum KeyboardInjector {
    typealias ApplicationOpener = (
        URL,
        PresetApplication,
        @escaping (pid_t?, Error?) -> Void
    ) -> Void
    typealias ApplicationFocuser = (URL, PresetApplication, pid_t, UInt64) -> Void
    typealias CustomApplicationOpener = (
        URL,
        CustomApplicationProfile,
        @escaping (pid_t?, Error?) -> Void
    ) -> Void
    typealias CustomApplicationFocuser = (CustomApplicationProfile, pid_t, UInt64) -> Void
    typealias CmuxCommandRunner = (URL, [String], TimeInterval) -> CmuxCommandResult
    typealias KeyPoster = (CGKeyCode, CGEventFlags) -> Void
    typealias KeyStatePoster = (CGKeyCode, Bool, CGEventFlags) -> Bool

    struct AccessibilityTextCandidate: Equatable {
        let role: String
        let identifier: String
        let title: String
        let description: String
        let help: String
        let placeholder: String
        let context: String
        let frame: CGRect?
        let enabled: Bool
        let focused: Bool
        let selectedContext: Bool

        init(
            role: String,
            identifier: String,
            title: String,
            description: String,
            help: String,
            placeholder: String,
            context: String,
            frame: CGRect?,
            enabled: Bool,
            focused: Bool = false,
            selectedContext: Bool = false
        ) {
            self.role = role
            self.identifier = identifier
            self.title = title
            self.description = description
            self.help = help
            self.placeholder = placeholder
            self.context = context
            self.frame = frame
            self.enabled = enabled
            self.focused = focused
            self.selectedContext = selectedContext
        }
    }

    struct CmuxCommandResult: Equatable {
        let terminationStatus: Int32
        let standardOutput: Data
        let timedOut: Bool
    }

    static let syntheticEventMarker: Int64 = 0x5849_414F
    static let contextualMenuKeyCode: CGKeyCode = 110
    static let functionKeyCode: CGKeyCode = 63
    static let leftCommandKeyCode: CGKeyCode = 55
    static let rightCommandKeyCode: CGKeyCode = 54
    static let f20KeyCode: CGKeyCode = 90
    /// Web content shells only build the accessibility tree once an assistive
    /// client announces itself, so the composer scan finds an empty shell until
    /// one of these attributes is set. `AXManualAccessibility` is the Chromium
    /// and Electron convention and is tried first, because the standard
    /// `AXEnhancedUserInterface` that VoiceOver uses is known to distort windows
    /// and animations on some Electron versions. Shells that are not Chromium
    /// based answer `attributeUnsupported` for the first attribute and only
    /// respond to the standard one, so it is used as a fallback for exactly
    /// those apps.
    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    /// The web content tree needs about one to two seconds after the attribute
    /// is set, so the composer scan keeps retrying for longer than that.
    static let composerFocusMaximumAttempts = 12
    static let composerFocusRetryMilliseconds = 250
    private static let focusRequests = ApplicationFocusRequestGate()
    private static let frontmostFocusRequests = ApplicationFocusRequestGate()
    private static let manualAccessibilityLock = NSLock()
    private static var manualAccessibilityLoggedProcesses: Set<pid_t> = []
    private static let focusQueue = DispatchQueue(
        label: "RemoteMic.application-focus",
        qos: .userInitiated
    )
    static let accessibilityChildAttributes = [
        "AXChildrenInNavigationOrder",
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
        kAXChildrenAttribute,
    ]
    static let maximumAccessibilityTraversalCount = 5_000

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
    static func setFunctionKeyPressed(
        _ isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postKeyState
    ) -> Bool {
        setVoiceKeyPressed(
            .function,
            isPressed: isPressed,
            accessibilityTrusted: accessibilityTrusted,
            keyStatePoster: keyStatePoster
        )
    }

    @discardableResult
    static func setVoiceKeyPressed(
        _ mode: VoiceKeyMode,
        isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postKeyState
    ) -> Bool {
        guard accessibilityTrusted() else { return false }
        let flags: CGEventFlags
        switch mode {
        case .function:
            flags = isPressed ? .maskSecondaryFn : []
        case .leftCommand, .rightCommand:
            flags = isPressed ? .maskCommand : []
        }
        return keyStatePoster(
            mode.keyCode,
            isPressed,
            flags
        )
    }

    @discardableResult
    static func setRightCommandPressed(
        _ isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postUnmarkedKeyState
    ) -> Bool {
        guard accessibilityTrusted() else { return false }
        return keyStatePoster(
            rightCommandKeyCode,
            isPressed,
            isPressed ? .maskCommand : []
        )
    }

    @discardableResult
    static func sendQianwenConfirmationInterrupt(
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postUnmarkedKeyState
    ) -> Bool {
        guard accessibilityTrusted() else { return false }
        return keyStatePoster(f20KeyCode, true, []) &&
            keyStatePoster(f20KeyCode, false, [])
    }

    @discardableResult
    static func send(
        _ action: ButtonAction,
        shortcut: CustomKeyboardShortcut? = nil,
        applicationProfile: CustomApplicationProfile? = nil,
        applicationURL: (String) -> URL? = {
            if $0 == PresetApplication.remoteMic.bundleIdentifier {
                return Bundle.main.bundleURL
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationOpener: ApplicationOpener = openApplication,
        applicationFocuser: @escaping ApplicationFocuser = focusApplication,
        customApplicationURL: (CustomApplicationProfile) -> URL? = resolveCustomApplicationURL,
        customApplicationOpener: CustomApplicationOpener = openCustomApplication,
        customApplicationFocuser: @escaping CustomApplicationFocuser = focusCustomApplication,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyPoster: KeyPoster = { postKey(code: $0, flags: $1) },
        keyStatePoster: KeyStatePoster = postKeyState
    ) -> Bool {
        guard action != .disabled else { return true }
        if action.isAppInternal {
            AppLogger.shared.write("INTERNAL ACTION ignored_by_keyboard action=\(action.rawValue)")
            return true
        }
        if let application = action.presetApplication {
            let focusRequestID = focusRequests.begin()
            open(
                application,
                focusRequestID: focusRequestID,
                applicationURL: applicationURL,
                applicationOpener: applicationOpener,
                applicationFocuser: applicationFocuser
            )
            return true
        }
        if action == .openCustomApplication {
            guard let applicationProfile else {
                AppLogger.shared.write("APP ACTION custom unavailable reason=profile_missing")
                return true
            }
            let focusRequestID = focusRequests.begin()
            open(
                applicationProfile,
                focusRequestID: focusRequestID,
                applicationURL: customApplicationURL,
                applicationOpener: customApplicationOpener,
                applicationFocuser: customApplicationFocuser
            )
            return true
        }
        if action == .customShortcut, shortcut == nil {
            AppLogger.shared.write("SHORTCUT ACTION ignored reason=not_configured")
            return true
        }
        guard accessibilityTrusted() else { return false }

        switch action {
        case .disabled:
            return true
        case .escape:
            keyPoster(53, [])
        case .returnKey:
            keyPoster(36, [])
        case .commandReturn:
            keyPoster(36, .maskCommand)
        case .shiftReturn:
            keyPoster(36, .maskShift)
        case .commandCopy:
            keyPoster(8, .maskCommand)
        case .commandPaste:
            keyPoster(9, .maskCommand)
        case .commandClose:
            keyPoster(13, .maskCommand)
        case .commandQuit:
            keyPoster(12, .maskCommand)
        case .commandCut:
            keyPoster(7, .maskCommand)
        case .commandSelectAll:
            keyPoster(0, .maskCommand)
        case .commandUndo:
            keyPoster(6, .maskCommand)
        case .commandRedo:
            keyPoster(6, [.maskCommand, .maskShift])
        case .commandFind:
            keyPoster(3, .maskCommand)
        case .commandSave:
            keyPoster(1, .maskCommand)
        case .commandDelete:
            keyPoster(51, .maskCommand)
        case .arrowUp:
            keyPoster(126, [])
        case .arrowDown:
            keyPoster(125, [])
        case .arrowLeft:
            keyPoster(123, [])
        case .arrowRight:
            keyPoster(124, [])
        case .deleteBackward:
            keyPoster(51, [])
        case .showDesktop:
            keyPoster(103, .maskSecondaryFn)
        case .contextMenu:
            keyPoster(contextualMenuKeyCode, [])
        case .appSwitcher:
            keyPoster(48, .maskCommand)
        case .volumeUp:
            postSystemKey(type: 0)
        case .volumeDown:
            postSystemKey(type: 1)
        case .volumeMute:
            postSystemKey(type: 7)
        case .playPause:
            postSystemKey(type: 16)
        case .previousCommandLeft:
            keyPoster(123, .maskCommand)
        case .nextCommandRight:
            keyPoster(124, .maskCommand)
        case .customShortcut:
            if let shortcut {
                let eventFlags = shortcut.cgEventFlags
                if shortcut.standaloneModifier != nil {
                    let pressed = keyStatePoster(
                        CGKeyCode(shortcut.keyCode),
                        true,
                        eventFlags
                    )
                    let released = keyStatePoster(CGKeyCode(shortcut.keyCode), false, [])
                    let submitted = pressed && released
                    AppLogger.shared.write(
                        "SHORTCUT ACTION submitted key_code=\(shortcut.keyCode) " +
                            "modifier_flags=\(eventFlags.rawValue) standalone=true " +
                            "success=\(submitted)"
                    )
                    return submitted
                }
                keyPoster(CGKeyCode(shortcut.keyCode), eventFlags)
                AppLogger.shared.write(
                    "SHORTCUT ACTION submitted key_code=\(shortcut.keyCode) " +
                        "modifier_flags=\(eventFlags.rawValue) standalone=false"
                )
            }
        case .openCustomApplication:
            break
        case .toggleLongRecording:
            break
        case .openRemoteMic, .openCodex, .openClaude, .openCmux, .openWeChat, .openCursor, .openXcode,
             .openSlack, .openWeCom, .openNeteaseMusic, .openChrome, .openSafari, .openZed:
            break
        }
        return true
    }

    private static func open(
        _ application: PresetApplication,
        focusRequestID: UInt64,
        applicationURL: (String) -> URL?,
        applicationOpener: ApplicationOpener,
        applicationFocuser: @escaping ApplicationFocuser
    ) {
        guard let url = applicationURL(application.bundleIdentifier) else {
            AppLogger.shared.write("APP ACTION unavailable bundle=\(application.bundleIdentifier)")
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) " +
                        AppLogger.errorFields(error)
                )
            } else {
                AppLogger.shared.write("APP ACTION opened bundle=\(application.bundleIdentifier)")
                if application.focusStrategy != nil, let processIdentifier {
                    applicationFocuser(url, application, processIdentifier, focusRequestID)
                }
            }
        }
    }

    private static func openApplication(
        at url: URL,
        application: PresetApplication,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    private static func open(
        _ application: CustomApplicationProfile,
        focusRequestID: UInt64,
        applicationURL: (CustomApplicationProfile) -> URL?,
        applicationOpener: CustomApplicationOpener,
        applicationFocuser: @escaping CustomApplicationFocuser
    ) {
        guard let url = applicationURL(application) else {
            AppLogger.shared.write(
                "APP ACTION unavailable bundle=\(application.bundleIdentifier) custom=true"
            )
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) custom=true " +
                        AppLogger.errorFields(error)
                )
                return
            }
            AppLogger.shared.write(
                "APP ACTION opened bundle=\(application.bundleIdentifier) custom=true"
            )
            guard application.focusStrategy != .none, let processIdentifier else { return }
            applicationFocuser(application, processIdentifier, focusRequestID)
        }
    }

    private static func resolveCustomApplicationURL(
        _ application: CustomApplicationProfile
    ) -> URL? {
        let savedURL = URL(fileURLWithPath: application.applicationPath)
        if Bundle(url: savedURL)?.bundleIdentifier == application.bundleIdentifier {
            return savedURL
        }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        )
    }

    private static func openCustomApplication(
        at url: URL,
        application: CustomApplicationProfile,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    private static func focusCustomApplication(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        scheduleCustomApplicationFocus(
            application: application,
            processIdentifier: processIdentifier,
            requestID: requestID,
            attempt: 0
        )
    }

    private static func scheduleCustomApplicationFocus(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int
    ) {
        let maximumAttempts = 8
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(0) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard focusRequests.isCurrent(requestID) else { return }
            if isAccessibilityTrusted, application.focusStrategy == .recordedAccessibility {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier) {
                guard isAccessibilityTrusted else {
                    AppLogger.shared.write(
                        "APP FOCUS skipped bundle=\(application.bundleIdentifier) " +
                            "method=custom reason=not_trusted"
                    )
                    return
                }
                switch application.focusStrategy {
                case .none:
                    return
                case .keyboardShortcut:
                    if let shortcut = application.focusShortcut {
                        postKey(code: CGKeyCode(shortcut.keyCode), flags: shortcut.cgEventFlags)
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_shortcut"
                        )
                        return
                    }
                case .recordedAccessibility:
                    if let target = application.accessibilityTarget,
                       focusRecordedAccessibilityTarget(
                           target,
                           processIdentifier: processIdentifier
                       )
                    {
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_accessibility"
                        )
                        return
                    }
                }
            }

            let nextAttempt = attempt + 1
            if nextAttempt < maximumAttempts {
                scheduleCustomApplicationFocus(
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt
                )
            } else if focusRequests.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) " +
                        "method=custom reason=target_not_focused"
                )
            }
        }
    }

    private static func focusApplication(
        at applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        guard focusRequests.isCurrent(requestID), let strategy = application.focusStrategy else { return }

        switch strategy {
        case .accessibilityComposer:
            scheduleAccessibilityComposerFocus(
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: processIdentifier,
                requestID: requestID,
                requestGate: focusRequests,
                attempt: 0
            )
        case .cmuxSurfaceAPI:
            scheduleCmuxFocus(
                applicationURL: applicationURL,
                application: application,
                processIdentifier: processIdentifier,
                requestID: requestID,
                attempt: 0
            )
        }
    }

    @discardableResult
    static func focusFrontmostComposer(completion: @escaping (Bool) -> Void) -> Bool {
        guard isAccessibilityTrusted,
              let application = NSWorkspace.shared.frontmostApplication
        else { return false }
        let processIdentifier = application.processIdentifier
        let requestID = frontmostFocusRequests.begin()
        scheduleAccessibilityComposerFocus(
            bundleIdentifier: application.bundleIdentifier ?? "unknown",
            processIdentifier: processIdentifier,
            requestID: requestID,
            requestGate: frontmostFocusRequests,
            attempt: 0,
            completion: completion
        )
        return true
    }

    private static func scheduleCmuxFocus(
        applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int
    ) {
        let maximumAttempts = 4
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(100) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard focusRequests.isCurrent(requestID) else { return }
            let nextAttempt = attempt + 1
            if !applicationIsFrontmost(processIdentifier) {
                if nextAttempt < maximumAttempts {
                    scheduleCmuxFocus(
                        applicationURL: applicationURL,
                        application: application,
                        processIdentifier: processIdentifier,
                        requestID: requestID,
                        attempt: nextAttempt
                    )
                }
                return
            }
            let canContinue = {
                focusRequests.isCurrent(requestID) && applicationIsFrontmost(processIdentifier)
            }
            let focused = focusCmux(
                applicationURL: applicationURL,
                canContinue: canContinue,
                terminalFocuser: { _ in
                    guard isAccessibilityTrusted else {
                        AppLogger.shared.write(
                            "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=not_trusted"
                        )
                        return false
                    }
                    return focusCmuxTerminal(
                        processIdentifier: processIdentifier,
                        keyPoster: { postKey(code: $0, flags: $1) }
                    )
                }
            )
            if focused {
                AppLogger.shared.write(
                    "APP FOCUS succeeded bundle=\(application.bundleIdentifier) method=cmux_api_accessibility"
                )
                return
            }

            if nextAttempt < maximumAttempts {
                scheduleCmuxFocus(
                    applicationURL: applicationURL,
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt
                )
            } else if focusRequests.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=terminal_not_focused"
                )
            }
        }
    }

    private static func scheduleAccessibilityComposerFocus(
        bundleIdentifier: String,
        processIdentifier: pid_t,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        attempt: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        let delay: DispatchTimeInterval = attempt == 0
            ? .milliseconds(0)
            : .milliseconds(composerFocusRetryMilliseconds)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard requestGate.isCurrent(requestID) else { return }

            if isAccessibilityTrusted {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier), isAccessibilityTrusted {
                if focusComposer(processIdentifier: processIdentifier) {
                    AppLogger.shared.write(
                        "APP FOCUS succeeded bundle=\(bundleIdentifier) method=accessibility"
                    )
                    completeComposerFocus(
                        true,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                    return
                }
            }

            let nextAttempt = attempt + 1
            if nextAttempt < composerFocusMaximumAttempts {
                scheduleAccessibilityComposerFocus(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    requestGate: requestGate,
                    attempt: nextAttempt,
                    completion: completion
                )
            } else if requestGate.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(bundleIdentifier) method=accessibility reason=composer_not_found"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
            }
        }
    }

    private static func completeComposerFocus(
        _ focused: Bool,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        completion: ((Bool) -> Void)?
    ) {
        guard let completion else { return }
        DispatchQueue.main.async {
            guard requestGate.isCurrent(requestID) else { return }
            completion(focused)
        }
    }

    static func manualAccessibilityResultName(_ result: AXError) -> String {
        switch result {
        case .success: return "success"
        case .attributeUnsupported: return "attribute_unsupported"
        case .cannotComplete: return "cannot_complete"
        case .invalidUIElement: return "invalid_element"
        case .apiDisabled: return "api_disabled"
        case .notImplemented: return "not_implemented"
        default: return "error_\(result.rawValue)"
        }
    }

    /// The fallback only runs when the Chromium attribute is unsupported, so the
    /// log has to name which attribute actually answered.
    static func manualAccessibilityResultToken(primary: AXError, fallback: AXError?) -> String {
        guard let fallback else { return manualAccessibilityResultName(primary) }
        return "fallback_enhanced_\(manualAccessibilityResultName(fallback))"
    }

    /// The fallback answer wins whenever it was attempted, because the primary
    /// attribute was unsupported by that app.
    static func manualAccessibilityEffectiveResult(
        primary: AXError,
        fallback: AXError?
    ) -> AXError {
        if primary == .success { return .success }
        return fallback ?? primary
    }

    /// The attribute is set on every attempt because it is idempotent, but only
    /// the first attempt and the attempt that finally builds the tree carry new
    /// information; the retries in between would repeat the same reason.
    static func shouldLogManualAccessibility(
        result: AXError,
        attempt: Int,
        alreadyLoggedSuccess: Bool
    ) -> Bool {
        if attempt == 0 { return true }
        return result == .success && !alreadyLoggedSuccess
    }

    @discardableResult
    private static func announceManualAccessibility(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        attempt: Int
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let primary = AXUIElementSetAttributeValue(
            applicationElement,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        var fallback: AXError?
        if primary == .attributeUnsupported {
            fallback = AXUIElementSetAttributeValue(
                applicationElement,
                enhancedUserInterfaceAttribute as CFString,
                kCFBooleanTrue
            )
        }
        let result = manualAccessibilityEffectiveResult(primary: primary, fallback: fallback)

        manualAccessibilityLock.lock()
        let alreadyLoggedSuccess = manualAccessibilityLoggedProcesses.contains(processIdentifier)
        let shouldLog = shouldLogManualAccessibility(
            result: result,
            attempt: attempt,
            alreadyLoggedSuccess: alreadyLoggedSuccess
        )
        if result == .success {
            if manualAccessibilityLoggedProcesses.count >= 64 {
                manualAccessibilityLoggedProcesses.removeAll()
            }
            manualAccessibilityLoggedProcesses.insert(processIdentifier)
        }
        manualAccessibilityLock.unlock()

        if shouldLog {
            AppLogger.shared.write(
                "APP FOCUS manual_accessibility bundle=\(bundleIdentifier) " +
                    "attempt=\(attempt) " +
                    "result=\(manualAccessibilityResultToken(primary: primary, fallback: fallback))"
            )
        }
        return result == .success
    }

    private static func applicationIsFrontmost(_ processIdentifier: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    private static func focusComposer(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        for window in applicationWindows(applicationElement) {
            let windowTitle = axString(window, attribute: kAXTitleAttribute).lowercased()
            let excludedWindowTerms = ["settings", "preferences", "设置", "偏好设置"]
            guard !excludedWindowTerms.contains(where: windowTitle.contains) else { continue }
            let candidates = accessibilityTextCandidates(in: window)
            guard let candidateIndex = bestComposerCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: axFrame(window)
            ) else { continue }
            if focusAccessibilityElement(
                candidates[candidateIndex].element,
                applicationElement: applicationElement
            ) {
                return true
            }
        }
        return false
    }

    static func captureFocusedAccessibilityTarget(
        bundleIdentifier: String
    ) -> AccessibilityFocusTarget? {
        guard isAccessibilityTrusted else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElement(
            systemWideElement,
            attribute: kAXFocusedUIElementAttribute
        ) else { return nil }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier == bundleIdentifier
        else { return nil }

        let role = axString(focusedElement, attribute: kAXRoleAttribute)
        guard role == "AXTextArea" || role == "AXTextField",
              axBool(focusedElement, attribute: kAXEnabledAttribute) ?? true
        else { return nil }

        var contextParts: [String] = []
        var current = axElement(focusedElement, attribute: kAXParentAttribute)
        var window = axElement(focusedElement, attribute: kAXWindowAttribute)
        var ancestorCount = 0
        while let element = current, ancestorCount < 8 {
            let semanticText = axSemanticText(element)
            if !semanticText.isEmpty {
                contextParts.append(semanticText)
            }
            if axString(element, attribute: kAXRoleAttribute) == "AXWindow" {
                window = window ?? element
                break
            }
            current = axElement(element, attribute: kAXParentAttribute)
            ancestorCount += 1
        }

        let context = String(contextParts.joined(separator: " ").suffix(512))
        let target = AccessibilityFocusTarget(
            role: role,
            identifier: axString(focusedElement, attribute: kAXIdentifierAttribute),
            title: axString(focusedElement, attribute: kAXTitleAttribute),
            description: axString(focusedElement, attribute: kAXDescriptionAttribute),
            help: axString(focusedElement, attribute: kAXHelpAttribute),
            placeholder: axString(focusedElement, attribute: kAXPlaceholderValueAttribute),
            context: context,
            windowTitle: window.map { axString($0, attribute: kAXTitleAttribute) } ?? "",
            normalizedFrame: normalizedAccessibilityFrame(
                elementFrame: axFrame(focusedElement),
                windowFrame: window.flatMap(axFrame)
            )
        )
        let semanticText = [
            target.identifier,
            target.title,
            target.description,
            target.help,
            target.placeholder,
            target.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText),
              !semanticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return target
    }

    private static func focusRecordedAccessibilityTarget(
        _ target: AccessibilityFocusTarget,
        processIdentifier: pid_t
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var ranked: [(element: AXUIElement, score: Int)] = []
        for window in applicationWindows(applicationElement) {
            let windowFrame = axFrame(window)
            let windowTitle = axString(window, attribute: kAXTitleAttribute)
            for candidate in accessibilityTextCandidates(in: window) {
                guard let score = recordedAccessibilityCandidateScore(
                    candidate.snapshot,
                    target: target,
                    windowTitle: windowTitle,
                    windowFrame: windowFrame
                ) else { continue }
                ranked.append((candidate.element, score))
            }
        }
        ranked.sort { $0.score > $1.score }
        guard let best = ranked.first,
              ranked.dropFirst().first.map({ best.score - $0.score >= 40 }) ?? true
        else { return false }
        return focusAccessibilityElement(
            best.element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: true
        )
    }

    static func recordedAccessibilityCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        target: AccessibilityFocusTarget,
        windowTitle: String,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == target.role else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText) else { return nil }

        var score = 0
        var strongMatches = 0
        if semanticValuesMatch(candidate.identifier, target.identifier) {
            score += 500
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.placeholder, target.placeholder) {
            score += 220
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.title, target.title) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.description, target.description) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.help, target.help) {
            score += 100
            strongMatches += 1
        }
        if semanticValuesMatch(windowTitle, target.windowTitle) {
            score += 100
        }

        let contextSimilarity = accessibilityContextSimilarity(candidate.context, target.context)
        score += Int(contextSimilarity * 180)
        if contextSimilarity >= 0.5 {
            strongMatches += 1
        }

        if let targetFrame = target.normalizedFrame,
           let candidateFrame = normalizedAccessibilityFrame(
               elementFrame: candidate.frame,
               windowFrame: windowFrame
           )
        {
            let distance = abs(targetFrame.x - candidateFrame.x) +
                abs(targetFrame.y - candidateFrame.y) +
                abs(targetFrame.width - candidateFrame.width) +
                abs(targetFrame.height - candidateFrame.height)
            score += max(0, 120 - Int(distance * 120))
        }

        guard strongMatches > 0 else { return nil }
        return score >= 180 ? score : nil
    }

    private static func normalizedAccessibilityFrame(
        elementFrame: CGRect?,
        windowFrame: CGRect?
    ) -> NormalizedAccessibilityFrame? {
        guard let elementFrame, let windowFrame,
              windowFrame.width > 0, windowFrame.height > 0
        else { return nil }
        return NormalizedAccessibilityFrame(
            x: (elementFrame.minX - windowFrame.minX) / windowFrame.width,
            y: (elementFrame.minY - windowFrame.minY) / windowFrame.height,
            width: elementFrame.width / windowFrame.width,
            height: elementFrame.height / windowFrame.height
        )
    }

    private static func semanticValuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        return min(lhs.count, rhs.count) >= 4 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    private static func accessibilityContextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = accessibilityTokens(lhs)
        let right = accessibilityTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }

    private static func accessibilityTokens(_ value: String) -> Set<String> {
        Set(
            value.lowercased().components(
                separatedBy: CharacterSet.alphanumerics.inverted
            ).filter { $0.count >= 2 }
        )
    }

    private static func containsSensitiveAccessibilityTerms(_ value: String) -> Bool {
        let value = value.lowercased()
        let terms = [
            "password", "passcode", "secret", "api key", "apikey", "token", "credit card",
            "search", "find", "filter", "address bar", "settings", "preferences",
            "密码", "口令", "密钥", "令牌", "银行卡", "搜索", "查找", "筛选", "设置", "偏好",
        ]
        return terms.contains(where: value.contains)
    }

    private static func applicationWindows(_ applicationElement: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for window in [
            axElement(applicationElement, attribute: kAXFocusedWindowAttribute),
            axElement(applicationElement, attribute: kAXMainWindowAttribute),
        ].compactMap({ $0 }) + axElements(applicationElement, attribute: kAXWindowsAttribute) {
            if !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        return windows
    }

    private static func accessibilityTextCandidates(
        in window: AXUIElement
    ) -> [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] {
        struct PendingElement {
            let element: AXUIElement
            let context: String
            let selectedContext: Bool
        }

        let windowFrame = axFrame(window)
        var stack = [PendingElement(
            element: window,
            context: axSemanticText(window),
            selectedContext: axBool(window, attribute: kAXSelectedAttribute) ?? false
        )]
        var visitedElements: [CFHashCode: [AXUIElement]] = [CFHash(window): [window]]
        var visitedCount = 0
        var candidates: [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] = []

        while let current = stack.popLast(), visitedCount < maximumAccessibilityTraversalCount {
            visitedCount += 1
            let ownContext = axSemanticText(current.element)
            let combinedContext = [current.context, ownContext]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let role = axString(current.element, attribute: kAXRoleAttribute)
            let frame = axFrame(current.element)
            let selectedContext = current.selectedContext ||
                (axBool(current.element, attribute: kAXSelectedAttribute) ?? false)

            if role == "AXTextArea" || role == "AXTextField" {
                candidates.append((
                    current.element,
                    AccessibilityTextCandidate(
                        role: role,
                        identifier: axString(current.element, attribute: kAXIdentifierAttribute),
                        title: axString(current.element, attribute: kAXTitleAttribute),
                        description: axString(current.element, attribute: kAXDescriptionAttribute),
                        help: axString(current.element, attribute: kAXHelpAttribute),
                        placeholder: axString(current.element, attribute: kAXPlaceholderValueAttribute),
                        context: combinedContext,
                        frame: frame,
                        enabled: axBool(current.element, attribute: kAXEnabledAttribute) ?? true,
                        focused: axBool(current.element, attribute: kAXFocusedAttribute) ?? false,
                        selectedContext: selectedContext
                    )
                ))
            }

            let childContext = String(combinedContext.suffix(512))
            var children: [AXUIElement] = []
            for attribute in accessibilityChildAttributes {
                for child in axElements(current.element, attribute: attribute) {
                    let hash = CFHash(child)
                    if visitedElements[hash]?.contains(where: { CFEqual($0, child) }) == true {
                        continue
                    }
                    visitedElements[hash, default: []].append(child)
                    children.append(child)
                }
            }
            children.sort {
                accessibilityTraversalPriority(
                    role: axString($0, attribute: kAXRoleAttribute),
                    frame: axFrame($0),
                    windowFrame: windowFrame
                ) < accessibilityTraversalPriority(
                    role: axString($1, attribute: kAXRoleAttribute),
                    frame: axFrame($1),
                    windowFrame: windowFrame
                )
            }
            stack.append(contentsOf: children.map {
                PendingElement(element: $0, context: childContext, selectedContext: selectedContext)
            })
        }
        return candidates
    }

    static func accessibilityTraversalPriority(
        role: String,
        frame: CGRect?,
        windowFrame: CGRect?
    ) -> Int {
        var priority = role == "AXTextArea" || role == "AXTextField" ? 1_000_000 : 0
        guard let frame, let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else {
            return priority
        }
        if frame.intersects(windowFrame) {
            priority += 100_000
        }
        let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
        priority += Int(max(0, min(1, verticalPosition)) * 10_000)
        return priority
    }

    private static func focusAccessibilityElement(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool = false
    ) -> Bool {
        if accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        ) {
            return true
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            element
        )
        if accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        ) {
            return true
        }
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        )
    }

    private static func accessibilityElementIsFocused(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        let applicationFocusedElementMatches = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { CFEqual($0, element) }
        return accessibilityFocusIsConfirmed(
            elementFocused: axBool(element, attribute: kAXFocusedAttribute) == true,
            applicationFocusedElementMatches: applicationFocusedElementMatches,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        )
    }

    static func accessibilityFocusIsConfirmed(
        elementFocused: Bool,
        applicationFocusedElementMatches: Bool?,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        if requiresApplicationFocusedElement {
            return applicationFocusedElementMatches == true
        }
        return elementFocused || applicationFocusedElementMatches == true
    }

    static func bestComposerCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = composerCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func composerCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == "AXTextArea" || candidate.role == "AXTextField" else {
            return nil
        }

        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ]
        .joined(separator: " ")
        .lowercased()

        let excludedTerms = [
            "search", "find", "filter", "title", "rename", "api key", "apikey", "token",
            "password", "secret", "settings", "preferences", "command palette", "address bar",
            "terminal", "console", "shell", "xterm", "approval", "permission", "code editor", "monaco",
            "搜索", "查找", "筛选", "标题", "重命名", "密钥", "令牌", "密码", "设置", "偏好",
            "终端", "控制台", "审批", "权限", "代码编辑器",
        ]
        guard !excludedTerms.contains(where: semanticText.contains) else { return nil }

        let strongTerms = [
            "composer", "prompt-editor", "prompt_editor", "chat-input", "chat_input",
            "message-input", "message_input", "prompt input", "message input",
            "消息输入", "输入消息", "发送消息",
        ]
        let supportingTerms = [
            "message", "prompt", "reply", "ask claude", "ask anything", "chat", "提问", "回复",
        ]
        let hasStrongSemanticMatch = strongTerms.contains(where: semanticText.contains)
        let hasSupportingSemanticMatch = supportingTerms.contains(where: semanticText.contains)
        guard candidate.role == "AXTextArea" || hasStrongSemanticMatch || hasSupportingSemanticMatch else {
            return nil
        }

        var score = candidate.role == "AXTextArea" ? 50 : 0
        if hasStrongSemanticMatch {
            score += 120
        } else if hasSupportingSemanticMatch {
            score += 70
        }

        if let frame = candidate.frame {
            if frame.width >= 280 { score += 25 }
            if (24...500).contains(frame.height) { score += 10 }
            if let windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                if frame.width / windowFrame.width >= 0.45 { score += 30 }
                let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
                if verticalPosition >= 0.55 {
                    score += 20
                } else if verticalPosition <= 0.25 {
                    score -= 15
                }
            }
        }

        return score >= 80 ? score : nil
    }

    private static func focusCmuxTerminal(
        processIdentifier: pid_t,
        keyPoster: KeyPoster
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var terminalFrame: CGRect?
        for window in applicationWindows(applicationElement) {
            let candidates = accessibilityTextCandidates(in: window)
            guard let candidateIndex = bestCmuxTerminalCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: axFrame(window)
            ) else { continue }
            terminalFrame = terminalFrame ?? candidates[candidateIndex].snapshot.frame
            if focusAccessibilityElement(
                candidates[candidateIndex].element,
                applicationElement: applicationElement,
                requiresApplicationFocusedElement: true
            ) {
                return true
            }
        }

        let focusedElementSnapshot = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { focusedElement in
            (
                role: axString(focusedElement, attribute: kAXRoleAttribute),
                frame: axFrame(focusedElement)
            )
        }
        if let keyCode = cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: focusedElementSnapshot?.role,
            focusedFrame: focusedElementSnapshot?.frame,
            terminalFrame: terminalFrame
        ) {
            keyPoster(keyCode, [.maskCommand, .maskShift])
        }
        return false
    }

    static func cmuxFocusRecoveryShortcutKeyCode(
        focusedRole: String?,
        focusedFrame: CGRect?,
        terminalFrame: CGRect?
    ) -> CGKeyCode? {
        if let focusedFrame, let terminalFrame,
           focusedFrame.minX >= terminalFrame.maxX {
            return 14 // Cmd+Shift+E: cmux Toggle Right Sidebar Focus returns to the terminal.
        }
        switch focusedRole {
        case "AXTextArea", "AXTextField":
            return 0 // Cmd+Shift+A: cmux Focus TextBox Input toggles back to the terminal.
        case nil, "", "AXApplication", "AXWindow":
            return nil
        default:
            return nil // Left-sidebar and other controls are recovered by the scheduled surface.focus retry.
        }
    }

    static func cmuxTerminalIsApplicationFocused(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let focusedElement = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ) else { return false }
        return applicationWindows(applicationElement).contains { window in
            accessibilityTextCandidates(in: window).contains { candidate in
                cmuxTerminalCandidateScore(candidate.snapshot, windowFrame: axFrame(window)) != nil &&
                    CFEqual(candidate.element, focusedElement)
            }
        }
    }

    static func bestCmuxTerminalCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = cmuxTerminalCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func cmuxTerminalCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == "AXTextArea" else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ]
        .joined(separator: " ")
        .lowercased()
        guard semanticText.contains("terminal content area") else { return nil }

        var score = 200
        if candidate.focused { score += 1_000 }
        if candidate.selectedContext { score += 500 }
        if let frame = candidate.frame {
            score += min(100, Int(frame.width * frame.height / 10_000))
            if let windowFrame, frame.intersects(windowFrame) { score += 100 }
        }
        return score
    }

    @discardableResult
    static func focusCmux(
        applicationURL: URL,
        cliURL: URL? = nil,
        runner: CmuxCommandRunner = runCmuxCommand,
        canContinue: () -> Bool = { true },
        terminalFocuser: (String) -> Bool = { _ in true }
    ) -> Bool {
        guard canContinue() else { return false }
        guard let cliURL = cliURL ?? cmuxCLIURL(applicationURL: applicationURL) else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=cli_unavailable")
            return false
        }

        let currentResult = runner(cliURL, ["rpc", "surface.current", "{}"], 1)
        guard !currentResult.timedOut, currentResult.terminationStatus == 0 else {
            let reason = currentResult.timedOut ? "current_timeout" : "current_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
            return false
        }
        guard canContinue() else { return false }
        guard let payload = try? JSONSerialization.jsonObject(with: currentResult.standardOutput) as? [String: Any],
              let surfaceID = payload["surface_id"] as? String,
              UUID(uuidString: surfaceID) != nil,
              let surfaceType = (payload["surface_type"] as? String) ?? (payload["type"] as? String),
              surfaceType.caseInsensitiveCompare("terminal") == .orderedSame
        else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=no_current_terminal")
            return false
        }

        guard let focusParameters = try? JSONSerialization.data(
            withJSONObject: ["surface_id": surfaceID],
            options: [.sortedKeys]
        ), let focusJSON = String(data: focusParameters, encoding: .utf8) else {
            return false
        }
        guard canContinue() else { return false }

        let focusResult = runner(cliURL, ["rpc", "surface.focus", focusJSON], 1)
        guard !focusResult.timedOut, focusResult.terminationStatus == 0 else {
            let reason = focusResult.timedOut ? "focus_timeout" : "focus_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
            return false
        }
        guard canContinue() else { return false }
        return terminalFocuser(surfaceID)
    }

    static func cmuxCLIURL(
        applicationURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = [
            applicationURL.appendingPathComponent("Contents/bin/cmux"),
            applicationURL.appendingPathComponent("Contents/Resources/bin/cmux"),
        ]
        candidates.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("cmux") })
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/cmux"),
            URL(fileURLWithPath: "/usr/local/bin/cmux"),
        ])

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func runCmuxCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> CmuxCommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            return CmuxCommandResult(terminationStatus: -1, standardOutput: Data(), timedOut: false)
        }

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .milliseconds(100))
            }
            return CmuxCommandResult(terminationStatus: -1, standardOutput: Data(), timedOut: true)
        }

        return CmuxCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            timedOut: false
        )
    }

    private static func axAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String {
        axAttribute(element, attribute: attribute) as? String ?? ""
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        axAttribute(element, attribute: attribute) as? Bool
    }

    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = axAttribute(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let values = axAttribute(element, attribute: attribute) as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axAttribute(element, attribute: kAXPositionAttribute),
              let sizeValue = axAttribute(element, attribute: kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func axSemanticText(_ element: AXUIElement) -> String {
        [
            axString(element, attribute: kAXIdentifierAttribute),
            axString(element, attribute: kAXTitleAttribute),
            axString(element, attribute: kAXDescriptionAttribute),
            axString(element, attribute: kAXHelpAttribute),
            axString(element, attribute: kAXPlaceholderValueAttribute),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
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

    private static func postKeyState(
        code: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags
    ) -> Bool {
        guard let event = keyStateEvent(
            code: code,
            isDown: isDown,
            flags: flags,
            userData: syntheticEventMarker
        ) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func postUnmarkedKeyState(
        code: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags
    ) -> Bool {
        guard let event = keyStateEvent(code: code, isDown: isDown, flags: flags, userData: nil)
        else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    static func keyStateEvent(
        code: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags,
        userData: Int64?
    ) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        else { return nil }
        event.flags = flags
        if let userData {
            event.setIntegerValueField(.eventSourceUserData, value: userData)
        }
        return event
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

final class ApplicationFocusRequestGate {
    private let lock = NSLock()
    private var latestRequestID: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latestRequestID &+= 1
        return latestRequestID
    }

    func isCurrent(_ requestID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestID == latestRequestID
    }
}
