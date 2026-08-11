import AppKit
import ApplicationServices
import Foundation

enum PostDictationPolishState: Equatable {
    case idle
    case waitingForText
    case waitingForStability
    case requesting
    case completed
    case skipped
    case failed
}

struct PostDictationTextChange: Equatable {
    let oldRange: NSRange
    let newRange: NSRange
    let newText: String
}

final class PostDictationPolishCoordinator {
    private static let pollIntervalNanoseconds: UInt64 = 125_000_000
    private static let stableDuration: TimeInterval = 0.9
    private static let totalTimeout: TimeInterval = 8
    private static let maximumDictationCharacters = 8_000

    private let client: DeepSeekTextPolishingClient
    private let isEnabled: () -> Bool
    private let loadAPIKey: () throws -> String?
    private let enabledTerms: () -> [ProgrammingTerm]
    private let statusChanged: (PostDictationPolishState, LocalizedMessage) -> Void
    private let resultChanged: (String?) -> Void

    private var generation: UInt64 = 0
    private var target: Target?
    private var task: Task<Void, Never>?

    init(
        client: DeepSeekTextPolishingClient = DeepSeekTextPolishingClient(),
        isEnabled: @escaping () -> Bool,
        loadAPIKey: @escaping () throws -> String?,
        enabledTerms: @escaping () -> [ProgrammingTerm],
        statusChanged: @escaping (PostDictationPolishState, LocalizedMessage) -> Void,
        resultChanged: @escaping (String?) -> Void
    ) {
        self.client = client
        self.isEnabled = isEnabled
        self.loadAPIKey = loadAPIKey
        self.enabledTerms = enabledTerms
        self.statusChanged = statusChanged
        self.resultChanged = resultChanged
    }

    func startSession() {
        guard isEnabled() else { return }
        cancel(resetStatus: false)
        guard let apiKey = try? loadAPIKey(), !apiKey.isEmpty else {
            publish(.failed, "post_dictation.status.missing_key")
            return
        }
        guard let captured = Self.captureTarget() else {
            publish(.skipped, "post_dictation.status.unsupported_target")
            return
        }
        generation &+= 1
        target = captured
        publish(.waitingForText, "post_dictation.status.recording")
    }

    func finishSession() {
        guard isEnabled(), let target else { return }
        let currentGeneration = generation
        publish(.waitingForText, "post_dictation.status.waiting_for_text")
        task = Task { [weak self] in
            await self?.observeAndPolish(target: target, generation: currentGeneration)
        }
    }

    func cancel(resetStatus: Bool = true) {
        generation &+= 1
        task?.cancel()
        task = nil
        target = nil
        publishResult(nil)
        if resetStatus {
            publish(.idle, "post_dictation.status.ready")
        }
    }

    private func observeAndPolish(target: Target, generation: UInt64) async {
        let deadline = Date().addingTimeInterval(Self.totalTimeout)
        var stableText: String?
        var stableSince: Date?
        var acceptedChange: PostDictationTextChange?

        while !Task.isCancelled, Date() < deadline {
            guard isCurrent(generation), isEnabled(), Self.isTargetCurrent(target),
                  let currentText = Self.stringAttribute(target.element, kAXValueAttribute)
            else {
                finish(.skipped, "post_dictation.status.target_changed", generation: generation)
                return
            }

            if currentText == target.originalText {
                stableText = nil
                stableSince = nil
                acceptedChange = nil
            } else if let change = Self.continuousChange(
                original: target.originalText,
                updated: currentText,
                originalSelection: target.originalSelection
            ), change.oldRange == target.originalSelection,
                      !change.newText.isEmpty,
                      change.newText.count <= Self.maximumDictationCharacters {
                if stableText != currentText {
                    stableText = currentText
                    stableSince = Date()
                    acceptedChange = change
                    publish(.waitingForStability, "post_dictation.status.waiting_for_stability")
                } else if let stableSince,
                          Date().timeIntervalSince(stableSince) >= Self.stableDuration {
                    guard Self.selectionIsAtEnd(of: change, in: target.element) else {
                        finish(.skipped, "post_dictation.status.target_changed", generation: generation)
                        return
                    }
                    await requestAndReplace(
                        target: target,
                        stableText: currentText,
                        change: acceptedChange ?? change,
                        generation: generation
                    )
                    return
                }
            } else {
                finish(.skipped, "post_dictation.status.range_unavailable", generation: generation)
                return
            }

            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }

        if !Task.isCancelled {
            finish(.skipped, "post_dictation.status.timeout", generation: generation)
        }
    }

    private func requestAndReplace(
        target: Target,
        stableText: String,
        change: PostDictationTextChange,
        generation: UInt64
    ) async {
        guard let apiKey = try? loadAPIKey(), !apiKey.isEmpty else {
            finish(.failed, "post_dictation.status.missing_key", generation: generation)
            return
        }
        publish(.requesting, "post_dictation.status.requesting")
        let input = DeepSeekPolishInput(
            applicationName: target.applicationName,
            bundleIdentifier: target.bundleIdentifier,
            contextBefore: target.contextBefore,
            contextAfter: target.contextAfter,
            currentDictation: change.newText,
            programmingTerms: enabledTerms()
        )

        do {
            let refinedText = try await client.polish(input: input, apiKey: apiKey)
            guard isCurrent(generation), isEnabled(), Self.isTargetCurrent(target),
                  Self.stringAttribute(target.element, kAXValueAttribute) == stableText,
                  Self.selectionIsAtEnd(of: change, in: target.element)
            else {
                finish(.skipped, "post_dictation.status.target_changed", generation: generation)
                return
            }
            guard Self.replace(
                change: change,
                in: target.element,
                fullText: stableText,
                with: refinedText
            ) else {
                publishResult(refinedText)
                finish(.skipped, "post_dictation.status.result_available", generation: generation)
                return
            }
            finish(.completed, "post_dictation.status.completed", generation: generation)
        } catch is CancellationError {
            return
        } catch {
            finish(.failed, "post_dictation.status.request_failed", generation: generation)
        }
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation && !Task.isCancelled
    }

    private func finish(
        _ state: PostDictationPolishState,
        _ key: String,
        generation: UInt64
    ) {
        guard isCurrent(generation) else { return }
        task = nil
        target = nil
        publish(state, key)
    }

    private func publish(_ state: PostDictationPolishState, _ key: String) {
        DispatchQueue.main.async { [statusChanged] in
            statusChanged(state, LocalizedMessage(key))
        }
    }

    private func publishResult(_ result: String?) {
        DispatchQueue.main.async { [resultChanged] in
            resultChanged(result)
        }
    }

    static func continuousChange(
        original: String,
        updated: String,
        originalSelection: NSRange? = nil
    ) -> PostDictationTextChange? {
        if let originalSelection {
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
            return PostDictationTextChange(
                oldRange: originalSelection,
                newRange: newRange,
                newText: updatedNSString.substring(with: newRange)
            )
        }

        let originalCharacters = Array(original)
        let updatedCharacters = Array(updated)
        var prefixCount = 0
        while prefixCount < originalCharacters.count,
              prefixCount < updatedCharacters.count,
              originalCharacters[prefixCount] == updatedCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < originalCharacters.count - prefixCount,
              suffixCount < updatedCharacters.count - prefixCount,
              originalCharacters[originalCharacters.count - suffixCount - 1]
                == updatedCharacters[updatedCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        let originalStart = original.index(original.startIndex, offsetBy: prefixCount)
        let originalEnd = original.index(original.endIndex, offsetBy: -suffixCount)
        let updatedStart = updated.index(updated.startIndex, offsetBy: prefixCount)
        let updatedEnd = updated.index(updated.endIndex, offsetBy: -suffixCount)
        let oldRange = NSRange(originalStart..<originalEnd, in: original)
        let newRange = NSRange(updatedStart..<updatedEnd, in: updated)
        guard oldRange.length > 0 || newRange.length > 0 else { return nil }
        return PostDictationTextChange(
            oldRange: oldRange,
            newRange: newRange,
            newText: String(updated[updatedStart..<updatedEnd])
        )
    }

    static func frozenContext(text: String, selection: NSRange) -> (before: String, after: String)? {
        guard let range = Range(selection, in: text) else { return nil }
        return (
            before: String(text[..<range.lowerBound].suffix(100)),
            after: String(text[range.upperBound...].prefix(100))
        )
    }

    private static func captureTarget() -> Target? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated,
              let focusedElement = focusedElement(for: application.processIdentifier),
              let role = stringAttribute(focusedElement, kAXRoleAttribute),
              let originalText = stringAttribute(focusedElement, kAXValueAttribute),
              let selection = rangeAttribute(focusedElement, kAXSelectedTextRangeAttribute),
              selection.location >= 0,
              NSMaxRange(selection) <= (originalText as NSString).length,
              isSettable(focusedElement, kAXSelectedTextRangeAttribute),
              isSettable(focusedElement, kAXSelectedTextAttribute),
              !role.localizedCaseInsensitiveContains("secure"),
              !(stringAttribute(focusedElement, kAXSubroleAttribute) ?? "")
                .localizedCaseInsensitiveContains("secure"),
              let context = frozenContext(text: originalText, selection: selection)
        else { return nil }

        return Target(
            appPID: application.processIdentifier,
            applicationName: application.localizedName ?? "",
            bundleIdentifier: application.bundleIdentifier ?? "",
            element: focusedElement,
            originalText: originalText,
            originalSelection: selection,
            contextBefore: context.before,
            contextAfter: context.after
        )
    }

    private static func isTargetCurrent(_ target: Target) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.appPID,
              let focused = focusedElement(for: target.appPID)
        else { return false }
        return CFEqual(focused, target.element)
    }

    private static func selectionIsAtEnd(
        of change: PostDictationTextChange,
        in element: AXUIElement
    ) -> Bool {
        guard let selection = rangeAttribute(element, kAXSelectedTextRangeAttribute) else {
            return false
        }
        return selection.length == 0 && selection.location == NSMaxRange(change.newRange)
    }

    private static func replace(
        change: PostDictationTextChange,
        in element: AXUIElement,
        fullText: String,
        with refinedText: String
    ) -> Bool {
        let expected = (fullText as NSString).replacingCharacters(
            in: change.newRange,
            with: refinedText
        )
        var range = CFRange(location: change.newRange.location, length: change.newRange.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success,
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                refinedText as CFString
              ) == .success
        else { return false }
        return stringAttribute(element, kAXValueAttribute) == expected
    }

    private static func focusedElement(for pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private struct Target {
        let appPID: pid_t
        let applicationName: String
        let bundleIdentifier: String
        let element: AXUIElement
        let originalText: String
        let originalSelection: NSRange
        let contextBefore: String
        let contextAfter: String
    }
}
