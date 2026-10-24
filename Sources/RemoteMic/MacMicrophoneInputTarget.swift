import AppKit
import ApplicationServices

/// Keeps only a focused AX element, never its value or selected text.
final class MacMicrophoneInputTarget {
    private var application: NSRunningApplication?
    private var element: AXUIElement?
    private var generation: UInt64 = 0
    private let frontmost: () -> NSRunningApplication?
    private let readFocus: (NSRunningApplication) -> AXUIElement?
    private let activate: (NSRunningApplication) -> Void
    private let snapshot: () -> VoiceInputDestinationSnapshot
    private let ownProcessIdentifier: pid_t
    private let isRunning: (NSRunningApplication) -> Bool

    init(
        frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        readFocus: @escaping (NSRunningApplication) -> AXUIElement? = MacMicrophoneInputTarget.focusedElement,
        activate: @escaping (NSRunningApplication) -> Void = { $0.activate(options: []) },
        snapshot: @escaping () -> VoiceInputDestinationSnapshot = VoiceInputDestinationSnapshot.system,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        isRunning: @escaping (NSRunningApplication) -> Bool = { !$0.isTerminated }
    ) {
        self.frontmost = frontmost
        self.readFocus = readFocus
        self.activate = activate
        self.snapshot = snapshot
        self.ownProcessIdentifier = ownProcessIdentifier
        self.isRunning = isRunning
    }

    private static func focusedElement(in application: NSRunningApplication) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard read == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func isEligible(_ snapshot: VoiceInputDestinationSnapshot) -> Bool {
        // The user explicitly chose this field; search fields are valid for dictation too.
        snapshot.enabled && snapshot.editable && !snapshot.protectedContent &&
            snapshot.subrole != "AXSecureTextField" &&
            ["AXTextArea", "AXTextField", "AXComboBox"].contains(snapshot.role)
    }

    func cancel() { generation &+= 1 }

    func remember(_ candidate: NSRunningApplication? = nil) {
        guard let candidate = candidate ?? frontmost(), candidate.processIdentifier != ownProcessIdentifier,
              isRunning(candidate) else { return }
        // An app can temporarily lose AXFocusedUIElement as it deactivates.
        // Retain its identity, but never carry another app's field into it.
        if application?.processIdentifier != candidate.processIdentifier { element = nil }
        application = candidate
        if let focused = readFocus(candidate) { element = focused }
        AppLogger.shared.write("MAC MICROPHONE TARGET phase=remember result=remembered focused_element_saved=\(element != nil)")
    }

    func prepare(completion: @escaping (Bool) -> Void) {
        generation &+= 1
        let operation = generation
        if frontmost()?.processIdentifier != ownProcessIdentifier {
            remember()
        }
        guard let application, isRunning(application) else {
            AppLogger.shared.write("MAC MICROPHONE TARGET target_operation_id=\(operation) phase=completed result=failed reason=no_saved_target")
            completion(false); return
        }
        activate(application)
        if let element { _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        wait(application: application, element: element, deadline: deadline, operation: operation, completion: completion)
    }

    func restoreForStop(completion: @escaping () -> Void) {
        guard frontmost()?.processIdentifier == ownProcessIdentifier else {
            completion(); return
        }
        prepare { _ in completion() }
    }

    func monitor(onChange: @escaping () -> Void) {
        let operation = generation
        let baseline = snapshot()
        checkFocus(baseline: baseline, operation: operation, onChange: onChange)
    }

    private func checkFocus(baseline: VoiceInputDestinationSnapshot, operation: UInt64,
                            onChange: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == operation else { return }
            if self.frontmost()?.processIdentifier == self.ownProcessIdentifier {
                self.checkFocus(baseline: baseline, operation: operation, onChange: onChange)
                return
            }
            let current = self.snapshot()
            guard current.bundleIdentifier == baseline.bundleIdentifier,
                  current.focusIdentity == baseline.focusIdentity, Self.isEligible(current) else {
                onChange(); return
            }
            self.checkFocus(baseline: baseline, operation: operation, onChange: onChange)
        }
    }

    private func wait(application: NSRunningApplication, element: AXUIElement?,
                      deadline: TimeInterval, operation: UInt64, completion: @escaping (Bool) -> Void) {
        guard generation == operation else { return }
        let snapshot = snapshot()
        let focused = readFocus(application)
        if frontmost()?.processIdentifier == application.processIdentifier,
           snapshot.bundleIdentifier == application.bundleIdentifier,
           Self.isEligible(snapshot),
           let focused, element == nil || CFEqual(focused, element!) {
            self.element = focused
            AppLogger.shared.write("MAC MICROPHONE TARGET target_operation_id=\(operation) phase=completed result=ready focus_reacquired=\(element == nil)")
            completion(true); return
        }
        guard isRunning(application), ProcessInfo.processInfo.systemUptime < deadline else {
            AppLogger.shared.write("MAC MICROPHONE TARGET target_operation_id=\(operation) phase=completed result=failed reason=focus_not_restored eligible=\(Self.isEligible(snapshot)) focused_element_saved=\(element != nil)")
            completion(false); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { completion(false); return }
            self.wait(application: application, element: element, deadline: deadline, operation: operation, completion: completion)
        }
    }
}
