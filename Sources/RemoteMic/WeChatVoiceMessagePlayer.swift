import AppKit
import ApplicationServices
import Foundation

enum WeChatVoiceMessagePlayer {
    struct Candidate: Equatable {
        let role: String
        let semanticText: String
        let frame: CGRect
        let supportsPress: Bool
        let isLikelyIncoming: Bool

        init(
            role: String,
            semanticText: String,
            frame: CGRect,
            supportsPress: Bool,
            isLikelyIncoming: Bool = false
        ) {
            self.role = role
            self.semanticText = semanticText
            self.frame = frame
            self.supportsPress = supportsPress
            self.isLikelyIncoming = isLikelyIncoming
        }
    }

    static func playCurrentVoiceMessage(
        frontmostBundleIdentifier: () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        frontmostProcessIdentifier: () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        press: (AXUIElement) -> AXError = { element in
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        },
        cursorLocation: () -> CGPoint = {
            quartzMouseLocation()
        },
        click: (CGPoint) -> Bool = { point in
            postMouseClick(at: point)
        }
    ) -> Bool {
        guard frontmostBundleIdentifier() == PresetApplication.weChat.bundleIdentifier else {
            AppLogger.shared.write("WECHAT VOICE PLAY skipped reason=not_frontmost")
            return false
        }
        guard accessibilityTrusted(), let processIdentifier = frontmostProcessIdentifier() else {
            AppLogger.shared.write("WECHAT VOICE PLAY failed reason=accessibility_unavailable")
            return false
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        let candidates = applicationWindows(application).flatMap { window in
            voiceCandidates(in: window).map { (element: $0.element, candidate: $0.candidate) }
        }
        let incomingCandidates = candidates.filter { $0.candidate.isLikelyIncoming }
        guard let target = incomingCandidates.max(by: { lhs, rhs in
            candidateScore(lhs.candidate) < candidateScore(rhs.candidate)
        }) else {
            if let windowFrame = frontmostWindowFrame(for: processIdentifier),
               let point = cursorClickPoint(
                   in: windowFrame,
                   cursorLocation: cursorLocation()
               ),
               click(point) {
                AppLogger.shared.write(
                    "WECHAT VOICE PLAY fallback=cursor_click " +
                    "location=\(Int(point.x)),\(Int(point.y))"
                )
                return true
            }
            AppLogger.shared.write("WECHAT VOICE PLAY failed reason=voice_bubble_not_found")
            return false
        }

        let result = press(target.element)
        guard result == .success else {
            AppLogger.shared.write(
                "WECHAT VOICE PLAY failed reason=ax_press status=\(result.rawValue)"
            )
            return false
        }
        AppLogger.shared.write("WECHAT VOICE PLAY posted")
        return true
    }

    static func candidateScore(_ candidate: Candidate) -> Int {
        let text = candidate.semanticText.lowercased()
        guard candidate.supportsPress, isVoiceSemantic(text) else { return Int.min }

        var score = candidate.role == "AXButton" ? 100 : 0
        if text.contains("语音") || text.contains("voice") || text.contains("audio") {
            score += 80
        }
        if text.range(of: #"\d{1,3}\s*(?:秒|s|\"|″)"#, options: .regularExpression) != nil {
            score += 100
        }
        // Prefer the lowest visible voice bubble, which is normally the latest one.
        score += Int(min(max(candidate.frame.midY, 0), 10_000) / 10)
        return score
    }

    static func isVoiceSemantic(_ semanticText: String) -> Bool {
        let normalized = semanticText.lowercased()
        if ["语音", "voice", "audio", "播放语音", "voice message"].contains(where: normalized.contains) {
            return true
        }
        return normalized.range(
            of: #"\d{1,3}\s*(?:秒|s|\"|″)"#,
            options: .regularExpression
        ) != nil
    }

    static func cursorClickPoint(
        in windowFrame: CGRect,
        cursorLocation: CGPoint
    ) -> CGPoint? {
        let contentFrame = windowFrame.insetBy(dx: 2, dy: 44)
        guard contentFrame.contains(cursorLocation) else { return nil }
        return cursorLocation
    }

    private static func postMouseClick(at point: CGPoint) -> Bool {
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }

        down.setIntegerValueField(.eventSourceUserData, value: 0x524D_5743)
        up.setIntegerValueField(.eventSourceUserData, value: 0x524D_5743)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func quartzMouseLocation() -> CGPoint {
        let appKitLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitLocation) }) else {
            return appKitLocation
        }
        return CGPoint(
            x: appKitLocation.x,
            y: screen.frame.maxY - appKitLocation.y
        )
    }

    private static func frontmostWindowFrame(for processIdentifier: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return windows.compactMap { window -> CGRect? in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsValue = window[kCGWindowBounds as String]
            else { return nil }

            let bounds = boundsValue as! CFDictionary
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &frame),
                  frame.width > 0,
                  frame.height > 0 else { return nil }
            return frame
        }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    private static func applicationWindows(_ application: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for window in [
            axElement(application, attribute: kAXFocusedWindowAttribute),
            axElement(application, attribute: kAXMainWindowAttribute),
        ].compactMap({ $0 }) + axElements(application, attribute: kAXWindowsAttribute) {
            if !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        return windows
    }

    private static func voiceCandidates(in window: AXUIElement) -> [(element: AXUIElement, candidate: Candidate)] {
        struct Pending {
            let element: AXUIElement
        }

        var pending = [Pending(element: window)]
        var visited = Set<CFHashCode>()
        var result: [(element: AXUIElement, candidate: Candidate)] = []

        while let current = pending.popLast(), visited.count < 5_000 {
            let hash = CFHash(current.element)
            guard visited.insert(hash).inserted else { continue }

            let semanticText = [
                axString(current.element, attribute: kAXRoleAttribute),
                axString(current.element, attribute: kAXSubroleAttribute),
                axString(current.element, attribute: kAXIdentifierAttribute),
                axString(current.element, attribute: kAXTitleAttribute),
                axString(current.element, attribute: kAXDescriptionAttribute),
                axString(current.element, attribute: kAXHelpAttribute),
                axString(current.element, attribute: kAXValueAttribute),
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

            if let frame = axFrame(current.element) {
                let candidate = Candidate(
                    role: axString(current.element, attribute: kAXRoleAttribute),
                    semanticText: semanticText,
                    frame: frame,
                    supportsPress: actionNames(current.element).contains(kAXPressAction as String),
                    isLikelyIncoming: axFrame(window).map { frame.midX < $0.midX } ?? false
                )
                if candidateScore(candidate) > Int.min {
                    result.append((current.element, candidate))
                }
            }

            for attribute in [
                "AXChildrenInNavigationOrder",
                kAXVisibleChildrenAttribute,
                kAXContentsAttribute,
                kAXChildrenAttribute,
            ] {
                pending.append(contentsOf: axElements(current.element, attribute: attribute).map {
                    Pending(element: $0)
                })
            }
        }
        return result
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names
        else { return [] }
        return (names as NSArray).compactMap { $0 as? String }
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

    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = axAttribute(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let values = axAttribute(element, attribute: attribute) as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
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
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }
}
