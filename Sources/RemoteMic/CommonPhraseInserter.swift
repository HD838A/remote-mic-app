import AppKit
import Carbon

/// A paste transaction never reads target text. Accessibility is used only to
/// check focus, editability and secure-field metadata through public APIs.
final class CommonPhraseInserter {
    struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        static func capture(_ pasteboard: NSPasteboard) -> Snapshot {
            Snapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            })
        }
        func restore(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.clearContents()
            guard !items.isEmpty else { return true }
            return pasteboard.writeObjects(items.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
    }

    struct Request {
        let operationID: UInt64
        let start: TimeInterval
        let text: String
        let processID: pid_t
        let completion: (String) -> Void
    }
    private let pasteboard: NSPasteboard
    private let validateTarget: (pid_t) -> String?
    private let postPaste: () -> Bool
    private let schedule: (@escaping () -> Void) -> Void
    private let logger: (String) -> Void
    private var queue: [Request] = []
    private var busy = false
    private var operation: UInt64 = 0

    init(
        pasteboard: NSPasteboard = .general,
        validateTarget: @escaping (pid_t) -> String? = CommonPhraseInserter.targetFailure,
        postPaste: @escaping () -> Bool = {
            KeyboardInjector.postKeyState(code: 9, isDown: true, flags: .maskCommand) &&
                KeyboardInjector.postKeyState(code: 9, isDown: false, flags: .maskCommand)
        },
        schedule: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: action)
        },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.pasteboard = pasteboard
        self.validateTarget = validateTarget
        self.postPaste = postPaste
        self.schedule = schedule
        self.logger = logger
    }

    func insert(_ text: String, into processID: pid_t, completion: @escaping (String) -> Void) {
        operation &+= 1
        logger("COMMON_PHRASES INSERT operation_id=\(operation) phase=requested")
        queue.append(Request(operationID: operation, start: ProcessInfo.processInfo.systemUptime, text: text, processID: processID, completion: completion))
        drain()
    }

    func cancelPending() {
        let pending = queue
        queue.removeAll()
        for request in pending {
            logger("COMMON_PHRASES INSERT operation_id=\(request.operationID) phase=completed result=cancelled reason=panel_closed")
            request.completion("common_phrases.error.cancelled")
        }
    }

    private func drain() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let request = queue.removeFirst()
        let id = request.operationID
        let start = request.start
        if let reason = validateTarget(request.processID) {
            finish(request, id: id, start: start, result: "failed", reason: reason)
            return
        }
        logger("COMMON_PHRASES INSERT operation_id=\(id) phase=preflight result=passed")
        let snapshot = Snapshot.capture(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(request.text, forType: .string) else {
            _ = snapshot.restore(pasteboard)
            finish(request, id: id, start: start, result: "failed", reason: "clipboard_write_failed")
            return
        }
        let ownedChange = pasteboard.changeCount
        // Recheck after the clipboard write; never paste into a newly focused app.
        let targetError = validateTarget(request.processID)
        let submitted = targetError == nil && postPaste()
        logger("COMMON_PHRASES INSERT operation_id=\(id) phase=paste result=\(submitted ? "submitted" : "failed")")
        schedule { [weak self] in
            guard let self else { return }
            let restore = self.pasteboard.changeCount == ownedChange
            let restored = !restore || snapshot.restore(self.pasteboard)
            self.logger("COMMON_PHRASES INSERT operation_id=\(id) phase=clipboard result=\(restore ? (restored ? "restored" : "failed") : "user_copy_preserved")")
            let reason = !restored ? "clipboard_restore_failed" : (targetError ?? (submitted ? "paste_submitted" : "paste_failed"))
            self.finish(request, id: id, start: start, result: submitted && restored ? "submitted" : "failed", reason: reason)
        }
    }

    private func finish(_ request: Request, id: UInt64, start: TimeInterval, result: String, reason: String) {
        logger("COMMON_PHRASES INSERT operation_id=\(id) phase=completed result=\(result) reason=\(reason) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)) diagnostic_boundary=external_text_unobserved")
        busy = false
        request.completion(result == "submitted" ? "common_phrases.paste_submitted" : "common_phrases.error.\(reason)")
        drain()
    }

    static func targetFailure(_ processID: pid_t) -> String? {
        guard KeyboardInjector.isAccessibilityTrusted else { return "accessibility_required" }
        guard !IsSecureEventInputEnabled() else { return "input_unavailable" }
        guard processID != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        else { return "target_changed" }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return "input_unavailable" }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        func attribute(_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        guard (attribute(kAXEnabledAttribute) as? Bool) != false,
              (attribute(kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole
        else { return "input_unavailable" }
        let role = attribute(kAXRoleAttribute) as? String
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
        else { return "input_unavailable" }
        var valueSettable = DarwinBoolean(false)
        var selectedSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedSettable)
        guard valueSettable.boolValue || selectedSettable.boolValue else { return "input_unavailable" }
        if let identifier = attribute(kAXIdentifierAttribute) as? String,
           ["password", "token", "secret", "apikey", "api_key"].contains(where: identifier.lowercased().contains) {
            return "input_unavailable"
        }
        // A selected range would be replaced by Cmd+V. Refuse it rather than
        // reading or changing target content to emulate an insertion.
        guard let selectedRange = attribute(kAXSelectedTextRangeAttribute),
              CFGetTypeID(selectedRange) == AXValueGetTypeID() else { return "input_unavailable" }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(selectedRange, to: AXValue.self), .cfRange, &range), range.length == 0
        else { return "input_unavailable" }
        return nil
    }
}
