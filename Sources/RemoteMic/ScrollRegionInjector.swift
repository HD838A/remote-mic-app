import AppKit
import ApplicationServices
import CoreGraphics

struct ScrollPageResult {
    let outcome: ScrollPageOutcome
    /// `nil` when movement was not measured; otherwise whether visible text moved.
    let verifiedMovement: Bool?
}

/// Reads the accessibility tree just enough to find, record and scroll the area
/// that Page Up / Page Down should act on.
///
/// Deliberately does not read `AXValue`, does not take screenshots and never
/// moves keyboard focus (decisions S6, S12, S17).
enum ScrollRegionInjector {
    static let maximumScanNodes = 5_000

    // MARK: - Learning

    static func captureTarget(bundleIdentifier: String, point: CGPoint) -> ScrollRegionTarget? {
        guard AXIsProcessTrusted() else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(),
            Float(point.x), Float(point.y), &hit
        ) == .success, let element = hit else { return nil }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier == bundleIdentifier
        else { return nil }

        // Chromium nests web content ~20 levels deep, so read the window from the
        // dedicated attribute first and only then walk parents.
        let window = axElement(element, kAXWindowAttribute) ?? ancestorWindow(of: element)
        let windowFrame = window.flatMap(axFrame) ?? .zero
        let container = scrollAncestor(of: element).flatMap { candidate -> AXUIElement? in
            guard let containerFrame = axFrame(candidate),
                  ScrollRegionRule.acceptsContainer(
                      containerArea: Double(containerFrame.width * containerFrame.height),
                      windowArea: Double(windowFrame.width * windowFrame.height)
                  )
            else { return nil }
            return candidate
        }
        let anchor = container ?? window ?? element
        let frame = axFrame(anchor) ?? .zero
        guard windowFrame.width > 0, windowFrame.height > 0, frame.width > 0, frame.height > 0 else {
            return nil
        }

        let supportsPageAction = container.map { axActions($0).contains("AXScrollUpByPage") } ?? false
        return ScrollRegionTarget(
            role: axString(anchor, kAXRoleAttribute),
            identifier: axString(anchor, kAXIdentifierAttribute),
            windowTitle: window.map { axString($0, kAXTitleAttribute) } ?? "",
            context: ancestorContext(of: element, stoppingAt: window),
            normalizedFrame: ScrollRegionRule.normalizedFrame(
                elementFrame: frame, windowFrame: windowFrame
            ),
            source: .learned,
            strategy: supportsPageAction ? .accessibilityPageAction : .lineWheel
        )
    }

    // MARK: - Scrolling

    static func scrollPage(
        direction: ScrollPageDirection,
        learnedTarget: ScrollRegionTarget? = nil,
        verifyMovement: Bool = false
    ) -> ScrollPageResult {
        let started = Date()
        let result = performScroll(direction: direction, learnedTarget: learnedTarget,
                                   verifyMovement: verifyMovement)
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
        AppLogger.shared.write(
            "SCROLL PAGE bundle=\(bundle) direction=\(direction == .up ? "up" : "down") " +
            "strategy=\(learnedTarget?.strategy.rawValue ?? "preset") result=\(result.outcome.rawValue) " +
            "verified=\(result.verifiedMovement.map(String.init) ?? "unknown") " +
            "elapsed_ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        )
        return result
    }

    private static func performScroll(
        direction: ScrollPageDirection,
        learnedTarget: ScrollRegionTarget?,
        verifyMovement: Bool
    ) -> ScrollPageResult {
        guard AXIsProcessTrusted() else { return ScrollPageResult(outcome: .accessibilityUnavailable, verifiedMovement: nil) }
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier
        else { return ScrollPageResult(outcome: .noFrontmostApplication, verifiedMovement: nil) }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = focusedWindow(of: applicationElement) else {
            return ScrollPageResult(outcome: .regionUnavailable, verifiedMovement: nil)
        }
        let windowFrame = axFrame(window) ?? .zero

        // Records taken on anonymous containers have no role to match against a
        // live scroll area; they are replayed as a rectangle (S3).
        if let learnedTarget, !usesContainerMatching(role: learnedTarget.role) {
            return scrollRecordedRect(
                learnedTarget, window: window, windowFrame: windowFrame,
                direction: direction, verifyMovement: verifyMovement
            )
        }

        let candidates = scrollCandidates(in: window, windowFrame: windowFrame)

        let candidate: Candidate
        if let learnedTarget {
            switch ScrollRegionRule.bestMatchIndex(in: candidates.map(\.descriptor), recorded: learnedTarget) {
            case .matched(let found):
                candidate = candidates[found]
            case .failed(let outcome):
                return ScrollPageResult(outcome: outcome, verifiedMovement: nil)
            }
        } else {
            guard ScrollRegionPreset.rule(for: bundleIdentifier) != nil else {
                return ScrollPageResult(outcome: .needsCalibration, verifiedMovement: nil)
            }
            // Presets only accept containers that are smaller than the window;
            // apps exposing one whole-window web area scroll by window rect.
            let containers = candidates.filter {
                ScrollRegionRule.acceptsContainer(
                    containerArea: Double($0.descriptor.frame.width * $0.descriptor.frame.height),
                    windowArea: Double(windowFrame.width * windowFrame.height)
                )
            }
            guard let found = ScrollRegionRule.presetCandidateIndex(in: containers.map(\.descriptor)) else {
                return scrollRect(
                    windowFrame, window: window, direction: direction, verifyMovement: verifyMovement
                )
            }
            candidate = containers[found]
        }
        let before = verifyMovement
            ? textSignature(in: window, region: candidate.descriptor.frame)
            : [:]

        if axActions(candidate.element).contains("AXScrollUpByPage") {
            let action = direction == .up ? "AXScrollUpByPage" : "AXScrollDownByPage"
            guard AXUIElementPerformAction(candidate.element, action as CFString) == .success else {
                return ScrollPageResult(outcome: .eventFailed, verifiedMovement: nil)
            }
            return finish(window: window, region: candidate.descriptor.frame, before: before,
                          outcome: .scrolledByPageAction, verifyMovement: verifyMovement)
        }

        // No page action: scroll the recorded region by its visible height,
        // never by the window centre (S6).
        let center = CGPoint(x: candidate.descriptor.frame.midX, y: candidate.descriptor.frame.midY)
        guard postPageWheel(
            direction: direction,
            chunks: ScrollRegionRule.pageScrollChunks(regionHeight: Double(candidate.descriptor.frame.height)),
            at: center
        ) else {
            return ScrollPageResult(outcome: .eventFailed, verifiedMovement: nil)
        }
        return finish(window: window, region: candidate.descriptor.frame, before: before,
                      outcome: .scrolledByPixelWheel, verifyMovement: verifyMovement)
    }

    static func usesContainerMatching(role: String) -> Bool {
        role == "AXScrollArea" || role == "AXWebArea"
    }

    private static func scrollRecordedRect(
        _ target: ScrollRegionTarget,
        window: AXUIElement,
        windowFrame: CGRect,
        direction: ScrollPageDirection,
        verifyMovement: Bool
    ) -> ScrollPageResult {
        guard let frame = target.normalizedFrame,
              windowFrame.width > 0, windowFrame.height > 0
        else { return ScrollPageResult(outcome: .regionUnavailable, verifiedMovement: nil) }

        let rect = CGRect(
            x: windowFrame.minX + frame.x * windowFrame.width,
            y: windowFrame.minY + frame.y * windowFrame.height,
            width: frame.width * windowFrame.width,
            height: frame.height * windowFrame.height
        )
        return scrollRect(rect, window: window, direction: direction, verifyMovement: verifyMovement)
    }

    private static func scrollRect(
        _ rect: CGRect,
        window: AXUIElement,
        direction: ScrollPageDirection,
        verifyMovement: Bool
    ) -> ScrollPageResult {
        guard rect.width >= 8, rect.height >= 8 else {
            return ScrollPageResult(outcome: .regionUnavailable, verifiedMovement: nil)
        }
        let before = verifyMovement ? textSignature(in: window, region: rect) : [:]
        guard postPageWheel(
            direction: direction,
            chunks: ScrollRegionRule.pageScrollChunks(regionHeight: Double(rect.height)),
            at: CGPoint(x: rect.midX, y: rect.midY)
        ) else {
            return ScrollPageResult(outcome: .eventFailed, verifiedMovement: nil)
        }
        return finish(window: window, region: rect, before: before,
                      outcome: .scrolledByPixelWheel, verifyMovement: verifyMovement)
    }

    private static func finish(
        window: AXUIElement,
        region: CGRect?,
        before: [String: CGFloat],
        outcome: ScrollPageOutcome,
        verifyMovement: Bool
    ) -> ScrollPageResult {
        guard verifyMovement, !before.isEmpty else {
            return ScrollPageResult(outcome: outcome, verifiedMovement: nil)
        }
        Thread.sleep(forTimeInterval: 0.35)
        let after = textSignature(in: window, region: region)
        let moved = before.contains { key, y in
            guard let newY = after[key] else { return false }
            return abs(newY - y) > 1
        }
        return ScrollPageResult(outcome: outcome, verifiedMovement: moved)
    }

    // MARK: - Accessibility helpers

    private struct Candidate {
        let element: AXUIElement
        let descriptor: ScrollRegionDescriptor
    }

    private static func focusedWindow(of applicationElement: AXUIElement) -> AXUIElement? {
        [
            axElement(applicationElement, kAXFocusedWindowAttribute),
            axElement(applicationElement, kAXMainWindowAttribute),
        ].compactMap { $0 }.first ?? axElements(applicationElement, kAXWindowsAttribute).first
    }

    private static func scrollCandidates(in window: AXUIElement, windowFrame: CGRect) -> [Candidate] {
        var result: [Candidate] = []
        var stack: [(element: AXUIElement, depth: Int, context: String)] = [(window, 0, "")]
        var visited = 0

        while let current = stack.popLast(), visited < maximumScanNodes {
            visited += 1
            let role = axString(current.element, kAXRoleAttribute)
            let identifier = axString(current.element, kAXIdentifierAttribute)
            let own = [role, identifier].filter { !$0.isEmpty }.joined(separator: ":")
            let context = String(([current.context, own].filter { !$0.isEmpty }
                .joined(separator: " ")).suffix(256))

            if role == "AXScrollArea" || role == "AXWebArea", let frame = axFrame(current.element) {
                result.append(Candidate(
                    element: current.element,
                    descriptor: ScrollRegionDescriptor(
                        role: role,
                        identifier: identifier,
                        context: context,
                        frame: frame,
                        windowFrame: windowFrame
                    )
                ))
            }
            if current.depth < 40 {
                for child in axChildren(current.element) {
                    stack.append((child, current.depth + 1, context))
                }
            }
        }
        return result
    }

    /// Fingerprint of visible text positions, used only to confirm that a page
    /// scroll actually moved content. Values are hashed and never persisted.
    /// Visible text positions inside the scrolled region. Values are hashed and
    /// only used to confirm the page actually moved; nothing is persisted.
    private static func textSignature(in window: AXUIElement, region: CGRect?) -> [String: CGFloat] {
        var signature: [String: CGFloat] = [:]
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 4_000, signature.count < 600 {
            visited += 1
            if axString(element, kAXRoleAttribute) == "AXStaticText" {
                let value = axString(element, kAXValueAttribute)
                if !value.isEmpty, let frame = axFrame(element),
                   region.map({ $0.intersects(frame) }) ?? true {
                    signature["\(value.hashValue)@\(Int(frame.width))x\(Int(frame.height))"] = frame.minY
                }
            }
            stack.append(contentsOf: axChildren(element))
        }
        return signature
    }

    private static func scrollAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 40 {
            let role = axString(node, kAXRoleAttribute)
            if role == "AXScrollArea" || role == "AXWebArea" { return node }
            current = axElement(node, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    private static func ancestorWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let node = current, depth < 40 {
            if axString(node, kAXRoleAttribute) == "AXWindow" { return node }
            current = axElement(node, kAXParentAttribute)
            depth += 1
        }
        return nil
    }

    private static func ancestorContext(of element: AXUIElement, stoppingAt window: AXUIElement?) -> String {
        var parts: [String] = []
        var current: AXUIElement? = axElement(element, kAXParentAttribute)
        var depth = 0
        while let node = current, depth < 12 {
            let role = axString(node, kAXRoleAttribute)
            if role == "AXWindow" { break }
            let identifier = axString(node, kAXIdentifierAttribute)
            if !role.isEmpty { parts.append(identifier.isEmpty ? role : "\(role):\(identifier)") }
            if window.map({ CFEqual($0, node) }) == true { break }
            current = axElement(node, kAXParentAttribute)
            depth += 1
        }
        return String(parts.joined(separator: " ").suffix(256))
    }

    /// Wheel chunks are posted from a serial queue: spacing them on the HID
    /// thread blocked event delivery and Chromium coalesced them into almost
    /// nothing, which is why a single press only moved a few lines.
    private static let pageScrollQueue = DispatchQueue(label: "RemoteMic.scroll-page")

    private static func postPageWheel(
        direction: ScrollPageDirection,
        chunks: Int,
        at point: CGPoint
    ) -> Bool {
        guard chunks > 0 else { return false }
        AppLogger.shared.write(
            "SCROLL PAGE wheel chunks=\(chunks) lines_per_chunk=\(ScrollRegionRule.linesPerChunk) " +
            "interval_ms=\(Int(ScrollRegionRule.chunkInterval * 1000))"
        )
        pageScrollQueue.async {
            for index in 0..<chunks {
                _ = postLineWheel(
                    direction: direction,
                    lines: ScrollRegionRule.linesPerChunk,
                    at: point
                )
                if index < chunks - 1 {
                    Thread.sleep(forTimeInterval: ScrollRegionRule.chunkInterval)
                }
            }
        }
        return true
    }

    private static func postLineWheel(direction: ScrollPageDirection, lines: Int32, at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .line,
                  wheelCount: 1,
                  wheel1: direction.wheelSign * lines,
                  wheel2: 0,
                  wheel3: 0
              )
        else { return false }
        event.location = point
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String {
        axAttribute(element, attribute) as? String ?? ""
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = axAttribute(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    private static func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        axAttribute(element, attribute) as? [AXUIElement] ?? []
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        axElements(element, kAXChildrenAttribute)
    }

    private static func axActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = axAttribute(element, kAXPositionAttribute),
              let sizeValue = axAttribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

/// Process-wide lookup so the action path does not need to reach into settings.
final class ScrollRegionTargetStore: @unchecked Sendable {
    static let shared = ScrollRegionTargetStore()

    private let lock = NSLock()
    private var targets: [String: ScrollRegionTarget] = [:]

    func replace(with profiles: [CustomApplicationProfile]) {
        lock.lock()
        defer { lock.unlock() }
        targets = profiles.reduce(into: [String: ScrollRegionTarget]()) { result, profile in
            guard let target = profile.scrollRegionTarget else { return }
            result[profile.bundleIdentifier] = target
        }
    }

    func target(for bundleIdentifier: String) -> ScrollRegionTarget? {
        lock.lock()
        defer { lock.unlock() }
        return targets[bundleIdentifier]
    }
}
