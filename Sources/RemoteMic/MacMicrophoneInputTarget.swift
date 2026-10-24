import AppKit
import ApplicationServices

/// Keeps only a focused AX element, never its value or selected text.
final class MacMicrophoneInputTarget {
    private var application: NSRunningApplication?
    private var element: AXUIElement?
    private var generation: UInt64 = 0

    static func isEligible(_ snapshot: VoiceInputDestinationSnapshot) -> Bool {
        // The user explicitly chose this field; search fields are valid for dictation too.
        snapshot.enabled && snapshot.editable && !snapshot.protectedContent &&
            snapshot.subrole != "AXSecureTextField" &&
            ["AXTextArea", "AXTextField", "AXComboBox"].contains(snapshot.role)
    }

    func cancel() { generation &+= 1 }

    func remember(_ candidate: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let candidate, candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !candidate.isTerminated, AXIsProcessTrusted() else { return }
        application = nil
        element = nil
        let app = AXUIElementCreateApplication(candidate.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        application = candidate
        element = (value as! AXUIElement)
    }

    func prepare(completion: @escaping (Bool) -> Void) {
        generation &+= 1
        let operation = generation
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            remember()
        }
        guard let application, let element, !application.isTerminated else {
            completion(false); return
        }
        application.activate(options: [])
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        wait(application: application, element: element, deadline: deadline, operation: operation, completion: completion)
    }

    func restoreForStop(completion: @escaping () -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            completion(); return
        }
        prepare { _ in completion() }
    }

    func monitor(onChange: @escaping () -> Void) {
        let operation = generation
        let baseline = VoiceInputDestinationSnapshot.system()
        checkFocus(baseline: baseline, operation: operation, onChange: onChange)
    }

    private func checkFocus(baseline: VoiceInputDestinationSnapshot, operation: UInt64,
                            onChange: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.generation == operation else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                self.checkFocus(baseline: baseline, operation: operation, onChange: onChange)
                return
            }
            let current = VoiceInputDestinationSnapshot.system()
            guard current.bundleIdentifier == baseline.bundleIdentifier,
                  current.focusIdentity == baseline.focusIdentity, Self.isEligible(current) else {
                onChange(); return
            }
            self.checkFocus(baseline: baseline, operation: operation, onChange: onChange)
        }
    }

    private func wait(application: NSRunningApplication, element: AXUIElement,
                      deadline: TimeInterval, operation: UInt64, completion: @escaping (Bool) -> Void) {
        guard generation == operation else { return }
        let snapshot = VoiceInputDestinationSnapshot.system()
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
           Self.isEligible(snapshot),
           read == .success, let focused, CFEqual(focused, element) {
            completion(true); return
        }
        guard !application.isTerminated, ProcessInfo.processInfo.systemUptime < deadline else {
            completion(false); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { completion(false); return }
            self.wait(application: application, element: element, deadline: deadline, operation: operation, completion: completion)
        }
    }
}
