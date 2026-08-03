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
    private static let focusRequests = ApplicationFocusRequestGate()
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
        guard accessibilityTrusted() else { return false }
        return keyStatePoster(
            functionKeyCode,
            isPressed,
            isPressed ? .maskSecondaryFn : []
        )
    }

    @discardableResult
    static func send(
        _ action: ButtonAction,
        shortcut: CustomKeyboardShortcut? = nil,
        applicationURL: (String) -> URL? = {
            if $0 == PresetApplication.remoteMic.bundleIdentifier {
                return Bundle.main.bundleURL
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationOpener: ApplicationOpener = openApplication,
        applicationFocuser: @escaping ApplicationFocuser = focusApplication,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyPoster: KeyPoster = { postKey(code: $0, flags: $1) }
    ) -> Bool {
        guard action != .disabled else { return true }
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
        case .customShortcut:
            if let shortcut {
                keyPoster(CGKeyCode(shortcut.keyCode), shortcut.cgEventFlags)
            }
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
                    "APP ACTION failed bundle=\(application.bundleIdentifier) error=\(error.localizedDescription)"
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
                application: application,
                processIdentifier: processIdentifier,
                requestID: requestID,
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
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int
    ) {
        let maximumAttempts = 8
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(0) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard focusRequests.isCurrent(requestID) else { return }

            if applicationIsFrontmost(processIdentifier) {
                guard isAccessibilityTrusted else {
                    AppLogger.shared.write(
                        "APP FOCUS skipped bundle=\(application.bundleIdentifier) method=accessibility reason=not_trusted"
                    )
                    return
                }
                if focusComposer(processIdentifier: processIdentifier) {
                    AppLogger.shared.write(
                        "APP FOCUS succeeded bundle=\(application.bundleIdentifier) method=accessibility"
                    )
                    return
                }
            }

            let nextAttempt = attempt + 1
            if nextAttempt < maximumAttempts {
                scheduleAccessibilityComposerFocus(
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt
                )
            } else if focusRequests.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) method=accessibility reason=composer_not_found"
                )
            }
        }
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
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        else { return false }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
        return true
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
