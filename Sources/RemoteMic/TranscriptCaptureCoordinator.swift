import AppKit
import ApplicationServices
import Foundation

struct TranscriptTextChange: Equatable {
    let oldRange: NSRange
    let newRange: NSRange
    let newText: String
}

struct CapturedTranscript: Equatable {
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let applicationName: String
    let bundleIdentifier: String
    let source: UsageEventSource
    let text: String
}

struct TranscriptCaptureSnapshot: Equatable {
    let focusIdentity: String
    let applicationName: String
    let bundleIdentifier: String
    let text: String
    let selection: NSRange
    let isSafeEditableDestination: Bool

    static func system() -> TranscriptCaptureSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElement(
            systemWideElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) else { return nil }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let text = axString(focusedElement, attribute: kAXValueAttribute as CFString),
              let selection = axRange(
                focusedElement,
                attribute: kAXSelectedTextRangeAttribute as CFString
              ),
              selection.location >= 0,
              NSMaxRange(selection) <= (text as NSString).length
        else { return nil }

        let role = axString(focusedElement, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = axString(focusedElement, attribute: kAXSubroleAttribute as CFString) ?? ""
        let roleIsEditable = role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox"
        let enabled = axBool(focusedElement, attribute: kAXEnabledAttribute as CFString) ?? true
        let editable = axBool(focusedElement, attribute: "AXEditable" as CFString) ?? roleIsEditable
        let protectedContent = axBool(
            focusedElement,
            attribute: "AXProtectedContent" as CFString
        ) ?? false
        let semanticText = [
            axString(focusedElement, attribute: kAXIdentifierAttribute as CFString),
            axString(focusedElement, attribute: kAXTitleAttribute as CFString),
            axString(focusedElement, attribute: kAXDescriptionAttribute as CFString),
            axString(focusedElement, attribute: kAXHelpAttribute as CFString),
            axString(focusedElement, attribute: kAXPlaceholderValueAttribute as CFString),
        ].compactMap { $0 }.joined(separator: " ")

        return TranscriptCaptureSnapshot(
            focusIdentity: "\(processIdentifier):\(CFHash(focusedElement))",
            applicationName: application.localizedName ?? "",
            bundleIdentifier: application.bundleIdentifier ?? "",
            text: text,
            selection: selection,
            isSafeEditableDestination: isSafeEditable(
                role: role,
                subrole: subrole,
                enabled: enabled,
                editable: editable,
                protectedContent: protectedContent,
                semanticText: semanticText
            )
        )
    }

    private static func isSafeEditable(
        role: String,
        subrole: String,
        enabled: Bool,
        editable: Bool,
        protectedContent: Bool,
        semanticText: String
    ) -> Bool {
        guard enabled, editable, !protectedContent else { return false }
        guard role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox" else {
            return false
        }
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return false }
        let normalized = semanticText.lowercased()
        let sensitiveTerms = [
            "password", "passcode", "secret", "api key", "apikey", "token",
            "credit card", "search", "find", "filter", "address bar", "settings",
            "preferences", "command palette", "密码", "口令", "密钥", "令牌",
            "信用卡", "搜索", "查找", "筛选", "设置", "偏好",
        ]
        return !sensitiveTerms.contains(where: normalized.contains)
    }

    private static func axElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func axBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func axRange(_ element: AXUIElement, attribute: CFString) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

final class TranscriptCaptureCoordinator {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask
    typealias SnapshotProvider = () -> TranscriptCaptureSnapshot?

    private static let maximumTranscriptCharacters = 8_000

    private struct ActiveSession {
        let id: UUID
        let generation: UInt64
        let startedAt: Date
        let source: UsageEventSource
        let target: TranscriptCaptureSnapshot
        var endedAt: Date?
        var stableText: String?
        var stableSince: TimeInterval?
        var acceptedChange: TranscriptTextChange?
    }

    private let pollInterval: TimeInterval
    private let stableDuration: TimeInterval
    private let totalTimeout: TimeInterval
    private let isEnabled: () -> Bool
    private let schedule: Scheduler
    private let clock: () -> TimeInterval
    private let snapshot: SnapshotProvider
    private let onCapture: (CapturedTranscript) -> Void

    private var generation: UInt64 = 0
    private var activeSession: ActiveSession?
    private var pollTask: VoiceFnTapScheduledTask?
    private var timeoutTask: VoiceFnTapScheduledTask?

    init(
        pollInterval: TimeInterval = 0.125,
        stableDuration: TimeInterval = 0.9,
        totalTimeout: TimeInterval = 8,
        isEnabled: @escaping () -> Bool,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        snapshot: @escaping SnapshotProvider = TranscriptCaptureSnapshot.system,
        onCapture: @escaping (CapturedTranscript) -> Void
    ) {
        self.pollInterval = pollInterval
        self.stableDuration = stableDuration
        self.totalTimeout = totalTimeout
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.clock = clock
        self.snapshot = snapshot
        self.onCapture = onCapture
    }

    func startSession(startedAt: Date, source: UsageEventSource) {
        cancel()
        guard isEnabled(), let target = snapshot(), target.isSafeEditableDestination else { return }
        generation &+= 1
        activeSession = ActiveSession(
            id: UUID(),
            generation: generation,
            startedAt: startedAt,
            source: source,
            target: target
        )
    }

    func finishSession(endedAt: Date) {
        guard isEnabled(), var session = activeSession, session.endedAt == nil else { return }
        session.endedAt = endedAt
        activeSession = session
        let generation = session.generation
        timeoutTask = schedule(totalTimeout) { [weak self] in
            guard self?.activeSession?.generation == generation else { return }
            self?.cancel()
        }
        poll(generation: generation)
    }

    func cancel() {
        generation &+= 1
        pollTask?.cancel()
        timeoutTask?.cancel()
        pollTask = nil
        timeoutTask = nil
        activeSession = nil
    }

    private func poll(generation: UInt64) {
        guard isEnabled(), var session = activeSession,
              session.generation == generation,
              session.endedAt != nil,
              let current = snapshot(),
              current.isSafeEditableDestination,
              current.focusIdentity == session.target.focusIdentity,
              current.bundleIdentifier == session.target.bundleIdentifier
        else {
            cancel()
            return
        }

        if current.text == session.target.text {
            session.stableText = nil
            session.stableSince = nil
            session.acceptedChange = nil
        } else if let change = Self.continuousChange(
            original: session.target.text,
            updated: current.text,
            originalSelection: session.target.selection
        ), change.oldRange == session.target.selection,
           !change.newText.isEmpty,
           change.newText.count <= Self.maximumTranscriptCharacters {
            if session.stableText != current.text {
                session.stableText = current.text
                session.stableSince = clock()
                session.acceptedChange = change
            } else if let stableSince = session.stableSince,
                      clock() - stableSince >= stableDuration,
                      current.selection.length == 0,
                      current.selection.location == NSMaxRange(change.newRange),
                      let endedAt = session.endedAt {
                let captured = CapturedTranscript(
                    sessionID: session.id,
                    startedAt: session.startedAt,
                    endedAt: endedAt,
                    applicationName: session.target.applicationName,
                    bundleIdentifier: session.target.bundleIdentifier,
                    source: session.source,
                    text: session.acceptedChange?.newText ?? change.newText
                )
                cancel()
                onCapture(captured)
                return
            }
        } else {
            cancel()
            return
        }

        activeSession = session
        pollTask = schedule(pollInterval) { [weak self] in
            self?.poll(generation: generation)
        }
    }

    static func continuousChange(
        original: String,
        updated: String,
        originalSelection: NSRange
    ) -> TranscriptTextChange? {
        let originalNSString = original as NSString
        guard originalSelection.location >= 0,
              NSMaxRange(originalSelection) <= originalNSString.length
        else { return nil }
        let prefix = originalNSString.substring(to: originalSelection.location)
        let suffix = originalNSString.substring(from: NSMaxRange(originalSelection))
        let updatedNSString = updated as NSString
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length
        guard updated.hasPrefix(prefix),
              updated.hasSuffix(suffix),
              updatedNSString.length >= prefixLength + suffixLength
        else { return nil }
        let newRange = NSRange(
            location: prefixLength,
            length: updatedNSString.length - prefixLength - suffixLength
        )
        guard newRange.length > 0 || originalSelection.length > 0 else { return nil }
        return TranscriptTextChange(
            oldRange: originalSelection,
            newRange: newRange,
            newText: updatedNSString.substring(with: newRange)
        )
    }
}
