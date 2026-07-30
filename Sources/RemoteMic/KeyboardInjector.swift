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
    }

    struct CmuxCommandResult: Equatable {
        let terminationStatus: Int32
        let standardOutput: Data
        let timedOut: Bool
    }

    static let syntheticEventMarker: Int64 = 0x5849_414F
    static let contextualMenuKeyCode: CGKeyCode = 110
    private static let focusRequests = ApplicationFocusRequestGate()
    private static let focusQueue = DispatchQueue(
        label: "RemoteMic.application-focus",
        qos: .userInitiated
    )

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
            focusQueue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                let canContinue = {
                    focusRequests.isCurrent(requestID) && applicationIsFrontmost(processIdentifier)
                }
                guard canContinue() else { return }
                if focusCmux(
                    applicationURL: applicationURL,
                    canContinue: canContinue
                ) {
                    AppLogger.shared.write("APP FOCUS succeeded bundle=\(application.bundleIdentifier) method=cmux_api")
                }
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
        guard let window = axElement(applicationElement, attribute: kAXFocusedWindowAttribute)
                ?? axElement(applicationElement, attribute: kAXMainWindowAttribute)
        else { return false }

        let windowTitle = axString(window, attribute: kAXTitleAttribute).lowercased()
        let excludedWindowTerms = ["settings", "preferences", "设置", "偏好设置"]
        guard !excludedWindowTerms.contains(where: windowTitle.contains) else { return false }

        let windowFrame = axFrame(window)
        var queue: [(element: AXUIElement, context: String)] = [
            (window, axSemanticText(window))
        ]
        var cursor = 0
        var candidates: [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] = []

        while cursor < queue.count, cursor < 1_500 {
            let current = queue[cursor]
            cursor += 1

            let ownContext = axSemanticText(current.element)
            let combinedContext = [current.context, ownContext]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let role = axString(current.element, attribute: kAXRoleAttribute)
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
                        frame: axFrame(current.element),
                        enabled: axBool(current.element, attribute: kAXEnabledAttribute) ?? true
                    )
                ))
            }

            let childContext = String(combinedContext.suffix(512))
            for child in axElements(current.element, attribute: kAXChildrenAttribute) {
                queue.append((child, childContext))
            }
        }

        guard let candidateIndex = bestComposerCandidateIndex(
            candidates.map(\.snapshot),
            windowFrame: windowFrame
        ) else { return false }

        let candidate = candidates[candidateIndex].element
        if AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        return AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            candidate
        ) == .success
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

    @discardableResult
    static func focusCmux(
        applicationURL: URL,
        cliURL: URL? = nil,
        runner: CmuxCommandRunner = runCmuxCommand,
        canContinue: () -> Bool = { true }
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
        return true
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
