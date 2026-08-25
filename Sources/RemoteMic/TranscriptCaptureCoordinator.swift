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
    typealias Logger = (String) -> Void

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
        var allowsInsertionOutsideReportedSelection = false
    }

    private struct PendingSession {
        let id: UUID
        let generation: UInt64
        let startedAt: Date
        let source: UsageEventSource
        let snapshotDeadline: TimeInterval
        var endedAt: Date?
        var allowsInsertionOutsideReportedSelection = false
    }

    private let initialSnapshotTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let stableDuration: TimeInterval
    private let totalTimeout: TimeInterval
    private let isEnabled: () -> Bool
    private let schedule: Scheduler
    private let clock: () -> TimeInterval
    private let snapshot: SnapshotProvider
    private let onCapture: (CapturedTranscript) -> Void
    private let log: Logger

    private var generation: UInt64 = 0
    private var pendingSession: PendingSession?
    private var activeSession: ActiveSession?
    private var initialSnapshotTask: VoiceFnTapScheduledTask?
    private var pollTask: VoiceFnTapScheduledTask?
    private var timeoutTask: VoiceFnTapScheduledTask?

    init(
        initialSnapshotTimeout: TimeInterval = 1.25,
        pollInterval: TimeInterval = 0.125,
        stableDuration: TimeInterval = 0.9,
        totalTimeout: TimeInterval = 8,
        isEnabled: @escaping () -> Bool,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        snapshot: @escaping SnapshotProvider = TranscriptCaptureSnapshot.system,
        onCapture: @escaping (CapturedTranscript) -> Void,
        log: @escaping Logger = AppLogger.shared.write
    ) {
        self.initialSnapshotTimeout = initialSnapshotTimeout
        self.pollInterval = pollInterval
        self.stableDuration = stableDuration
        self.totalTimeout = totalTimeout
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.clock = clock
        self.snapshot = snapshot
        self.onCapture = onCapture
        self.log = log
    }

    func startSession(startedAt: Date, source: UsageEventSource) {
        settleExistingSessionBeforeNextStart()
        guard isEnabled() else {
            log("TRANSCRIPT CAPTURE skipped reason=feature_disabled")
            return
        }
        generation &+= 1
        let pending = PendingSession(
            id: UUID(),
            generation: generation,
            startedAt: startedAt,
            source: source,
            snapshotDeadline: clock() + initialSnapshotTimeout
        )
        guard let target = snapshot() else {
            pendingSession = pending
            log("TRANSCRIPT CAPTURE waiting reason=initial_focus_unavailable")
            scheduleInitialSnapshotRetry(generation: pending.generation)
            return
        }
        guard target.isSafeEditableDestination else {
            log("TRANSCRIPT CAPTURE skipped reason=unsafe_destination")
            return
        }
        activate(pending, target: target, recoveredAfterRetry: false)
    }

    private func activate(
        _ pending: PendingSession,
        target: TranscriptCaptureSnapshot,
        recoveredAfterRetry: Bool
    ) {
        initialSnapshotTask?.cancel()
        initialSnapshotTask = nil
        pendingSession = nil
        activeSession = ActiveSession(
            id: pending.id,
            generation: pending.generation,
            startedAt: pending.startedAt,
            source: pending.source,
            target: target,
            endedAt: pending.endedAt,
            allowsInsertionOutsideReportedSelection:
                pending.allowsInsertionOutsideReportedSelection
        )
        log("TRANSCRIPT CAPTURE target_ready retry=\(recoveredAfterRetry)")
        if pending.endedAt != nil {
            scheduleFinishedSession(generation: pending.generation)
        }
    }

    func finishSession(
        endedAt: Date,
        allowsInsertionOutsideReportedSelection: Bool = false
    ) {
        if var pending = pendingSession, pending.endedAt == nil {
            pending.endedAt = endedAt
            pending.allowsInsertionOutsideReportedSelection =
                allowsInsertionOutsideReportedSelection
            pendingSession = pending
            return
        }
        guard isEnabled(), var session = activeSession, session.endedAt == nil else { return }
        session.endedAt = endedAt
        session.allowsInsertionOutsideReportedSelection =
            allowsInsertionOutsideReportedSelection
        activeSession = session
        scheduleFinishedSession(generation: session.generation)
    }

    func captureCurrentCandidateBeforeDestinationChange(reason: String) {
        guard isEnabled(), let session = activeSession, session.endedAt != nil else { return }
        if let updated = sessionAcceptingCurrentSnapshot(
            session,
            allowsInsertionOutsideReportedSelection: true
        ) {
            complete(updated, reason: reason)
        } else if session.acceptedChange != nil {
            complete(session, reason: reason)
        }
    }

    private func scheduleFinishedSession(generation: UInt64) {
        timeoutTask?.cancel()
        timeoutTask = schedule(totalTimeout) { [weak self] in
            guard self?.activeSession?.generation == generation else { return }
            self?.cancel(reason: "timeout")
        }
        poll(generation: generation)
    }

    func cancel(reason: String = "external") {
        let hadSession = pendingSession != nil || activeSession != nil
        clearState()
        if hadSession {
            log("TRANSCRIPT CAPTURE canceled reason=\(reason)")
        }
    }

    private func clearState() {
        generation &+= 1
        initialSnapshotTask?.cancel()
        pollTask?.cancel()
        timeoutTask?.cancel()
        initialSnapshotTask = nil
        pollTask = nil
        timeoutTask = nil
        pendingSession = nil
        activeSession = nil
    }

    private func scheduleInitialSnapshotRetry(generation: UInt64) {
        initialSnapshotTask = schedule(pollInterval) { [weak self] in
            self?.retryInitialSnapshot(generation: generation)
        }
    }

    private func retryInitialSnapshot(generation: UInt64) {
        guard let pending = pendingSession, pending.generation == generation else { return }
        guard isEnabled() else {
            cancel(reason: "feature_disabled_during_initial_focus")
            return
        }
        if let target = snapshot() {
            guard target.isSafeEditableDestination else {
                clearState()
                log("TRANSCRIPT CAPTURE skipped reason=unsafe_destination")
                return
            }
            activate(pending, target: target, recoveredAfterRetry: true)
            return
        }
        guard clock() < pending.snapshotDeadline else {
            clearState()
            log("TRANSCRIPT CAPTURE skipped reason=initial_focus_unavailable")
            return
        }
        scheduleInitialSnapshotRetry(generation: generation)
    }

    private func settleExistingSessionBeforeNextStart() {
        if pendingSession != nil {
            cancel(reason: "superseded_during_initial_focus")
            return
        }
        guard let session = activeSession else { return }
        guard session.endedAt != nil else {
            cancel(reason: "superseded_before_finish")
            return
        }
        if session.acceptedChange != nil {
            complete(session, reason: "next_session")
        } else if let updated = sessionAcceptingCurrentSnapshot(session) {
            complete(updated, reason: "next_session_snapshot")
        } else {
            cancel(reason: "superseded_without_text_change")
        }
    }

    private func sessionAcceptingCurrentSnapshot(
        _ session: ActiveSession,
        allowsInsertionOutsideReportedSelection: Bool = false
    ) -> ActiveSession? {
        guard let current = snapshot(),
              current.isSafeEditableDestination,
              current.focusIdentity == session.target.focusIdentity,
              current.bundleIdentifier == session.target.bundleIdentifier
        else { return nil }
        let exactChange = Self.continuousChange(
            original: session.target.text,
            updated: current.text,
            originalSelection: session.target.selection
        ).flatMap { change in
            change.oldRange == session.target.selection ? change : nil
        }
        guard let change = exactChange ?? (allowsInsertionOutsideReportedSelection
            ? Self.insertedTextChange(original: session.target.text, updated: current.text)
            : nil),
              !change.newText.isEmpty,
              change.newText.count <= Self.maximumTranscriptCharacters
        else { return nil }
        var updated = session
        updated.acceptedChange = change
        return updated
    }

    private func poll(generation: UInt64) {
        guard var session = activeSession, session.generation == generation else { return }
        guard isEnabled() else {
            cancel(reason: "feature_disabled_during_poll")
            return
        }
        guard session.endedAt != nil else { return }
        guard let current = snapshot() else {
            completeAcceptedChangeOrCancel(session, reason: "snapshot_unavailable_after_finish")
            return
        }
        guard current.isSafeEditableDestination else {
            completeAcceptedChangeOrCancel(session, reason: "destination_became_unsafe")
            return
        }
        guard current.focusIdentity == session.target.focusIdentity,
              current.bundleIdentifier == session.target.bundleIdentifier else {
            completeAcceptedChangeOrCancel(session, reason: "destination_changed")
            return
        }

        if current.text == session.target.text {
            if current.text.isEmpty, session.acceptedChange != nil {
                complete(session, reason: "destination_cleared")
                return
            }
            session.stableText = nil
            session.stableSince = nil
            session.acceptedChange = nil
        } else if let change = Self.acceptedChange(
            original: session.target.text,
            updated: current.text,
            originalSelection: session.target.selection,
            allowsInsertionOutsideReportedSelection:
                session.allowsInsertionOutsideReportedSelection
        ) ?? (session.allowsInsertionOutsideReportedSelection
            ? Self.replacedTextChange(original: session.target.text, updated: current.text)
            : nil),
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
                      session.endedAt != nil {
                complete(session, reason: "stable")
                return
            }
        } else if current.text.isEmpty, session.acceptedChange != nil {
            complete(session, reason: "destination_cleared")
            return
        } else {
            cancel(reason: "discontinuous_text_change")
            return
        }

        activeSession = session
        pollTask = schedule(pollInterval) { [weak self] in
            self?.poll(generation: generation)
        }
    }

    private func completeAcceptedChangeOrCancel(_ session: ActiveSession, reason: String) {
        guard session.acceptedChange != nil else {
            cancel(reason: reason)
            return
        }
        complete(session, reason: reason)
    }

    private func complete(_ session: ActiveSession, reason: String) {
        guard let endedAt = session.endedAt,
              let change = session.acceptedChange,
              !change.newText.isEmpty
        else {
            cancel(reason: "missing_accepted_change")
            return
        }
        let captured = CapturedTranscript(
            sessionID: session.id,
            startedAt: session.startedAt,
            endedAt: endedAt,
            applicationName: session.target.applicationName,
            bundleIdentifier: session.target.bundleIdentifier,
            source: session.source,
            text: change.newText
        )
        clearState()
        log(
            "TRANSCRIPT CAPTURE saved reason=\(reason) " +
                "bundle=\(session.target.bundleIdentifier) characters=\(change.newText.count)"
        )
        onCapture(captured)
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

    private static func acceptedChange(
        original: String,
        updated: String,
        originalSelection: NSRange,
        allowsInsertionOutsideReportedSelection: Bool
    ) -> TranscriptTextChange? {
        if let change = continuousChange(
            original: original,
            updated: updated,
            originalSelection: originalSelection
        ), change.oldRange == originalSelection {
            return change
        }
        guard allowsInsertionOutsideReportedSelection else { return nil }
        return insertedTextChange(original: original, updated: updated)
    }

    static func insertedTextChange(original: String, updated: String) -> TranscriptTextChange? {
        changedTextChange(original: original, updated: updated, allowsReplacement: false)
    }

    private static func replacedTextChange(
        original: String,
        updated: String
    ) -> TranscriptTextChange? {
        changedTextChange(original: original, updated: updated, allowsReplacement: true)
    }

    private static func changedTextChange(
        original: String,
        updated: String,
        allowsReplacement: Bool
    ) -> TranscriptTextChange? {
        let originalText = original as NSString
        let updatedText = updated as NSString
        let commonLimit = min(originalText.length, updatedText.length)
        var prefixLength = 0
        while prefixLength < commonLimit,
              originalText.character(at: prefixLength) == updatedText.character(at: prefixLength) {
            prefixLength += 1
        }

        var suffixLength = 0
        while suffixLength < originalText.length - prefixLength,
              suffixLength < updatedText.length - prefixLength,
              originalText.character(at: originalText.length - suffixLength - 1) ==
                updatedText.character(at: updatedText.length - suffixLength - 1) {
            suffixLength += 1
        }

        let oldRange = NSRange(
            location: prefixLength,
            length: originalText.length - prefixLength - suffixLength
        )
        let newRange = NSRange(
            location: prefixLength,
            length: updatedText.length - prefixLength - suffixLength
        )
        guard (allowsReplacement || oldRange.length == 0), newRange.length > 0 else { return nil }
        return TranscriptTextChange(
            oldRange: oldRange,
            newRange: newRange,
            newText: updatedText.substring(with: newRange)
        )
    }
}
