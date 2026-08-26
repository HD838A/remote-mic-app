import AppKit
import ApplicationServices
import Foundation

enum VoiceInputDestinationCancellation: String, Equatable {
    case actionFailed = "action_failed"
    case superseded
    case targetChanged = "target_changed"
    case timedOut = "timed_out"
}

enum VoiceInputDestinationWaitResult: Equatable {
    case ready
    case cancelled(VoiceInputDestinationCancellation)
}

enum VoiceInputDestinationWait {
    case immediate
    case cancelled(VoiceInputDestinationCancellation)
    case waiting(VoiceFnTapScheduledTask)
}

enum VoiceInputDestinationState: Equatable {
    case waiting
    case ready
    case cancelled(VoiceInputDestinationCancellation)
}

enum VoiceInputDestinationIntent: Equatable {
    case application(bundleIdentifier: String)
    case shortcut

    static func resolve(
        configured: ConfiguredButtonAction,
        applicationProfile: CustomApplicationProfile?
    ) -> VoiceInputDestinationIntent? {
        if let application = configured.action.presetApplication {
            return .application(bundleIdentifier: application.bundleIdentifier)
        }
        if configured.action == .openCustomApplication, let applicationProfile {
            return .application(bundleIdentifier: applicationProfile.bundleIdentifier)
        }
        if configured.action == .customShortcut, configured.shortcut != nil {
            return .shortcut
        }
        return nil
    }
}

struct VoiceInputDestinationSnapshot: Equatable {
    let bundleIdentifier: String?
    let role: String
    let subrole: String
    let enabled: Bool
    let editable: Bool
    let protectedContent: Bool
    let semanticText: String
    let focusIdentity: String

    init(
        bundleIdentifier: String?,
        role: String,
        subrole: String,
        enabled: Bool,
        editable: Bool,
        protectedContent: Bool,
        semanticText: String,
        focusIdentity: String = ""
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.subrole = subrole
        self.enabled = enabled
        self.editable = editable
        self.protectedContent = protectedContent
        self.semanticText = semanticText
        self.focusIdentity = focusIdentity
    }

    var isSafeEditableDestination: Bool {
        guard enabled, editable, !protectedContent else { return false }
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return false }
        let normalized = semanticText.lowercased()
        let sensitiveTerms = [
            "password", "passcode", "secret", "api key", "apikey", "token",
            "credit card", "密码", "口令", "密钥", "令牌", "信用卡", "银行卡",
        ]
        return !sensitiveTerms.contains(where: normalized.contains)
    }

    static func system() -> VoiceInputDestinationSnapshot {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard AXIsProcessTrusted() else {
            return empty(bundleIdentifier: frontmostBundleIdentifier)
        }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElement(
            systemWideElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) else {
            return empty(bundleIdentifier: frontmostBundleIdentifier)
        }

        var processIdentifier: pid_t = 0
        let focusedBundleIdentifier: String?
        if AXUIElementGetPid(focusedElement, &processIdentifier) == .success {
            focusedBundleIdentifier = NSRunningApplication(
                processIdentifier: processIdentifier
            )?.bundleIdentifier
        } else {
            focusedBundleIdentifier = nil
        }
        let role = axString(focusedElement, attribute: kAXRoleAttribute as CFString)
        let subrole = axString(focusedElement, attribute: kAXSubroleAttribute as CFString)
        let semanticText = [
            axString(focusedElement, attribute: kAXIdentifierAttribute as CFString),
            axString(focusedElement, attribute: kAXTitleAttribute as CFString),
            axString(focusedElement, attribute: kAXDescriptionAttribute as CFString),
            axString(focusedElement, attribute: kAXHelpAttribute as CFString),
            axString(focusedElement, attribute: kAXPlaceholderValueAttribute as CFString),
        ].joined(separator: " ")
        let roleIsEditable = role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox"
        let exposesEditableText = [
            kAXValueAttribute,
            kAXSelectedTextAttribute,
            kAXSelectedTextRangeAttribute,
        ].contains { axAttributeIsSettable(focusedElement, attribute: $0 as CFString) }
        return VoiceInputDestinationSnapshot(
            bundleIdentifier: focusedBundleIdentifier ?? frontmostBundleIdentifier,
            role: role,
            subrole: subrole,
            enabled: axBool(focusedElement, attribute: kAXEnabledAttribute as CFString) ?? true,
            editable: (axBool(focusedElement, attribute: "AXEditable" as CFString) ?? false) ||
                roleIsEditable || exposesEditableText,
            protectedContent: axBool(
                focusedElement,
                attribute: "AXProtectedContent" as CFString
            ) ?? false,
            semanticText: semanticText,
            focusIdentity: "\(processIdentifier):\(CFHash(focusedElement))"
        )
    }

    private static func empty(bundleIdentifier: String?) -> VoiceInputDestinationSnapshot {
        VoiceInputDestinationSnapshot(
            bundleIdentifier: bundleIdentifier,
            role: "",
            subrole: "",
            enabled: false,
            editable: false,
            protectedContent: false,
            semanticText: ""
        )
    }

    private static func axElement(
        _ element: AXUIElement,
        attribute: CFString
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axString(_ element: AXUIElement, attribute: CFString) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private static func axBool(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func axAttributeIsSettable(
        _ element: AXUIElement,
        attribute: CFString
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success &&
            settable.boolValue
    }
}

final class VoiceInputDestinationCoordinator {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> VoiceFnTapScheduledTask
    typealias SnapshotProvider = () -> VoiceInputDestinationSnapshot

    private struct PendingRequest {
        let id: UInt64
        let intent: VoiceInputDestinationIntent
        let initialBundleIdentifier: String?
        let initialFocusIdentity: String
        let initialWasSafeEditable: Bool
        var adoptedShortcutBundleIdentifier: String?
        var observedExpectedApplication = false
        var waiter: ((VoiceInputDestinationWaitResult) -> Void)?
    }

    private enum Evaluation {
        case waiting
        case ready
        case cancelled(VoiceInputDestinationCancellation)
    }

    private let pollInterval: TimeInterval
    private let maximumWait: TimeInterval
    private let schedule: Scheduler
    private let snapshot: SnapshotProvider
    private let onStateChange: (VoiceInputDestinationState) -> Void
    private var generation: UInt64 = 0
    private var pendingRequest: PendingRequest?
    private var timeoutTask: VoiceFnTapScheduledTask?
    private var pollTask: VoiceFnTapScheduledTask?

    init(
        pollInterval: TimeInterval = 0.05,
        maximumWait: TimeInterval = 5,
        schedule: @escaping Scheduler = VoiceFnTapScheduledTask.mainQueue,
        snapshot: @escaping SnapshotProvider = VoiceInputDestinationSnapshot.system,
        onStateChange: @escaping (VoiceInputDestinationState) -> Void = { _ in }
    ) {
        self.pollInterval = pollInterval
        self.maximumWait = maximumWait
        self.schedule = schedule
        self.snapshot = snapshot
        self.onStateChange = onStateChange
    }

    @discardableResult
    func beginTargetSwitch(intent: VoiceInputDestinationIntent) -> UInt64 {
        cancelPending(reason: .superseded)
        generation &+= 1
        let requestID = generation
        let initialSnapshot = snapshot()
        pendingRequest = PendingRequest(
            id: requestID,
            intent: intent,
            initialBundleIdentifier: initialSnapshot.bundleIdentifier,
            initialFocusIdentity: initialSnapshot.focusIdentity,
            initialWasSafeEditable: initialSnapshot.isSafeEditableDestination
        )
        timeoutTask = schedule(maximumWait) { [weak self] in
            guard self?.pendingRequest?.id == requestID else { return }
            self?.cancelPending(reason: .timedOut)
        }
        AppLogger.shared.write("VOICE DESTINATION pending request=\(requestID) intent=\(intent.logValue)")
        return requestID
    }

    func cancel(requestID: UInt64, reason: VoiceInputDestinationCancellation) {
        guard pendingRequest?.id == requestID else { return }
        cancelPending(reason: reason)
    }

    func waitUntilReady(
        completion: @escaping (VoiceInputDestinationWaitResult) -> Void
    ) -> VoiceInputDestinationWait {
        guard var request = pendingRequest else { return .immediate }
        switch evaluate(snapshot(), request: &request) {
        case .ready:
            pendingRequest = request
            completePending(with: .ready)
            return .immediate
        case let .cancelled(reason):
            pendingRequest = request
            completePending(with: .cancelled(reason))
            return .cancelled(reason)
        case .waiting:
            request.waiter = completion
            pendingRequest = request
            onStateChange(.waiting)
            schedulePoll(requestID: request.id)
            return .waiting(VoiceFnTapScheduledTask { [weak self] in
                self?.removeWaiter(requestID: request.id)
            })
        }
    }

    func shutdown() {
        cancelPending(reason: .superseded)
    }

    private func schedulePoll(requestID: UInt64) {
        pollTask?.cancel()
        pollTask = schedule(pollInterval) { [weak self] in
            self?.poll(requestID: requestID)
        }
    }

    private func poll(requestID: UInt64) {
        guard var request = pendingRequest, request.id == requestID else { return }
        switch evaluate(snapshot(), request: &request) {
        case .waiting:
            pendingRequest = request
            schedulePoll(requestID: requestID)
        case .ready:
            pendingRequest = request
            completePending(with: .ready)
        case let .cancelled(reason):
            pendingRequest = request
            completePending(with: .cancelled(reason))
        }
    }

    private func evaluate(
        _ current: VoiceInputDestinationSnapshot,
        request: inout PendingRequest
    ) -> Evaluation {
        switch request.intent {
        case let .application(expectedBundleIdentifier):
            if current.bundleIdentifier == expectedBundleIdentifier {
                request.observedExpectedApplication = true
                return current.isSafeEditableDestination ? .ready : .waiting
            }
            if request.observedExpectedApplication {
                return .cancelled(.targetChanged)
            }
            return .waiting

        case .shortcut:
            if let adopted = request.adoptedShortcutBundleIdentifier {
                guard current.bundleIdentifier == adopted else {
                    return .cancelled(.targetChanged)
                }
                return current.isSafeEditableDestination ? .ready : .waiting
            }
            if current.bundleIdentifier != request.initialBundleIdentifier,
               let currentBundleIdentifier = current.bundleIdentifier {
                request.adoptedShortcutBundleIdentifier = currentBundleIdentifier
                return current.isSafeEditableDestination ? .ready : .waiting
            }
            guard current.isSafeEditableDestination else { return .waiting }
            if request.initialWasSafeEditable,
               current.focusIdentity == request.initialFocusIdentity {
                return .waiting
            }
            return .ready
        }
    }

    private func completePending(with result: VoiceInputDestinationWaitResult) {
        guard let request = pendingRequest else { return }
        let waiter = request.waiter
        timeoutTask?.cancel()
        timeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        pendingRequest = nil
        switch result {
        case .ready:
            AppLogger.shared.write("VOICE DESTINATION ready request=\(request.id)")
            onStateChange(.ready)
        case let .cancelled(reason):
            AppLogger.shared.write(
                "VOICE DESTINATION cancelled request=\(request.id) reason=\(reason.rawValue)"
            )
            if waiter != nil {
                onStateChange(.cancelled(reason))
            }
        }
        waiter?(result)
    }

    private func cancelPending(reason: VoiceInputDestinationCancellation) {
        guard pendingRequest != nil else { return }
        completePending(with: .cancelled(reason))
    }

    private func removeWaiter(requestID: UInt64) {
        guard pendingRequest?.id == requestID else { return }
        cancelPending(reason: .superseded)
    }
}

private extension VoiceInputDestinationIntent {
    var logValue: String {
        switch self {
        case let .application(bundleIdentifier): return "application:\(bundleIdentifier)"
        case .shortcut: return "shortcut"
        }
    }
}
