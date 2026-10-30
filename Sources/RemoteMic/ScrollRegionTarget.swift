import AppKit
import ApplicationServices
import CoreGraphics

/// A recorded or preset definition of the area that Page Up / Page Down scrolls.
///
/// This is deliberately independent from `AccessibilityFocusTarget`: scroll
/// regions and input fields describe different things and must never share a
/// field or a matching path (decision S17).
struct ScrollRegionTarget: Codable, Equatable {
    enum Source: String, Codable {
        case preset
        case learned
    }

    enum Strategy: String, Codable {
        case accessibilityPageAction
        case pixelWheel
    }

    var role: String
    var identifier: String
    var windowTitle: String
    var context: String
    var normalizedFrame: NormalizedAccessibilityFrame?
    var source: Source
    var strategy: Strategy
}

enum ScrollPageDirection {
    case up
    case down

    /// Positive deltas reveal earlier content, matching the existing line-scroll
    /// actions (decision S5).
    var wheelSign: Int32 {
        switch self {
        case .up: return 1
        case .down: return -1
        }
    }
}

enum ScrollRegionMatch {
    case matched(Int)
    case failed(ScrollPageOutcome)
}

enum ScrollPageOutcome: String, Equatable {
    case scrolledByPageAction
    case scrolledByPixelWheel
    case accessibilityUnavailable
    case noFrontmostApplication
    case needsCalibration
    case regionUnavailable
    case regionMismatch
    case ambiguous
    case eventFailed

    var didScroll: Bool {
        self == .scrolledByPageAction || self == .scrolledByPixelWheel
    }
}

/// Snapshot of one scrollable node, used by the pure selection and matching
/// helpers so they can be tested without a live accessibility tree.
struct ScrollRegionDescriptor: Equatable {
    let role: String
    let identifier: String
    let context: String
    let frame: CGRect
    let windowFrame: CGRect
}

enum ScrollRegionRule {
    /// Narrower than this fraction of the window is treated as a sidebar and
    /// skipped when a wider content area exists.
    static let sidebarWidthRatio: Double = 0.45

    /// Chromium ignores synthetic pixel-unit wheel events and accelerates large
    /// line deltas, so a page is posted as several equal chunks: one chunk of
    /// ten lines moves content by roughly 120 pt on WorkBuddy, and more than six
    /// chunks typically runs past the end of the document.
    static let overlapRatio: Double = 0.10
    static let linesPerChunk: Int32 = 10
    static let chunkPoints: Double = 120
    static let maximumPageChunks = 6
    static let chunkInterval: TimeInterval = 0.015

    /// Number of wheel chunks that approximate one viewport.
    static func pageScrollChunks(regionHeight: Double) -> Int {
        guard regionHeight > 0 else { return 1 }
        let target = regionHeight * (1 - overlapRatio)
        return min(maximumPageChunks, max(1, Int((target / chunkPoints).rounded())))
    }

    static func normalizedFrame(
        elementFrame: CGRect,
        windowFrame: CGRect
    ) -> NormalizedAccessibilityFrame? {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        return NormalizedAccessibilityFrame(
            x: (elementFrame.minX - windowFrame.minX) / windowFrame.width,
            y: (elementFrame.minY - windowFrame.minY) / windowFrame.height,
            width: elementFrame.width / windowFrame.width,
            height: elementFrame.height / windowFrame.height
        )
    }

    /// Picks the content area of a window: the largest candidate that is wide
    /// enough to be content, falling back to the largest candidate when an app
    /// only exposes a narrow list (企业微信 only exposes its conversation list).
    /// A container covering (almost) the whole window is not a useful region:
    /// Chromium exposes the entire page as one `AXWebArea`, and scrolling its
    /// centre says nothing about which column the user meant.
    static func acceptsContainer(containerArea: Double, windowArea: Double) -> Bool {
        guard windowArea > 0, containerArea > 0 else { return false }
        let ratio = containerArea / windowArea
        return ratio >= 0.02 && ratio <= 0.90
    }

    static func presetCandidateIndex(in descriptors: [ScrollRegionDescriptor]) -> Int? {
        guard !descriptors.isEmpty else { return nil }
        let wide = descriptors.enumerated().filter { _, descriptor in
            descriptor.windowFrame.width > 0 &&
                descriptor.frame.width / descriptor.windowFrame.width >= sidebarWidthRatio
        }
        let pool = wide.isEmpty ? Array(descriptors.enumerated()) : wide
        return pool.max { lhs, rhs in
            area(lhs.element.frame) < area(rhs.element.frame)
        }?.offset
    }

    /// Scores a live candidate against a learned record. Returns `nil` when the
    /// candidate cannot plausibly be the recorded region.
    static func matchScore(
        candidate: ScrollRegionDescriptor,
        recorded: ScrollRegionTarget
    ) -> Int? {
        guard candidate.role == recorded.role else { return nil }
        var score = 0
        var strong = 0
        if valuesMatch(candidate.identifier, recorded.identifier) {
            score += 500
            strong += 1
        }
        if valuesMatch(candidate.context, recorded.context) {
            score += 160
            strong += 1
        } else if contextSimilarity(candidate.context, recorded.context) >= 0.5 {
            score += 90
            strong += 1
        }

        if let recordedFrame = recorded.normalizedFrame,
           let candidateFrame = normalizedFrame(
               elementFrame: candidate.frame,
               windowFrame: candidate.windowFrame
           ) {
            let distance = abs(recordedFrame.x - candidateFrame.x) +
                abs(recordedFrame.y - candidateFrame.y) +
                abs(recordedFrame.width - candidateFrame.width) +
                abs(recordedFrame.height - candidateFrame.height)
            score += max(0, 120 - Int(distance * 120))
            if distance <= 0.08 { strong += 1 }
        }
        guard strong > 0 else { return nil }
        return score >= 120 ? score : nil
    }

    /// Picks the learned target only when it wins by a clear margin; ties are
    /// reported as ambiguous instead of guessing (decision S13).
    static func bestMatchIndex(
        in descriptors: [ScrollRegionDescriptor],
        recorded: ScrollRegionTarget
    ) -> ScrollRegionMatch {
        let scored = descriptors.enumerated().compactMap { index, descriptor -> (Int, Int)? in
            guard let score = matchScore(candidate: descriptor, recorded: recorded) else { return nil }
            return (index, score)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return .failed(.regionMismatch) }
        if let second = scored.filter({ $0.0 != best.0 }).map(\.1).max(), best.1 - second < 40 {
            return .failed(.ambiguous)
        }
        return .matched(best.0)
    }

    private static func area(_ rect: CGRect) -> Double {
        Double(max(0, rect.width)) * Double(max(0, rect.height))
    }

    private static func valuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    private static func contextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(
            value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 2 }
        )
    }
}

enum ScrollRegionPreset {
    struct Rule {
        let bundleIdentifier: String
        let strategy: ScrollRegionTarget.Strategy
    }

    /// Only apps whose accessibility structure was measured on this machine.
    /// Everything else reports `needsCalibration` instead of guessing (S3).
    static let calibrated: [Rule] = [
        Rule(bundleIdentifier: "com.cmuxterm.app", strategy: .accessibilityPageAction),
        Rule(bundleIdentifier: "com.openai.codex", strategy: .pixelWheel),
        Rule(bundleIdentifier: "com.google.Chrome", strategy: .pixelWheel),
        Rule(bundleIdentifier: "com.tinyspeck.slackmacgap", strategy: .pixelWheel),
        Rule(bundleIdentifier: "com.tencent.WeWorkMac", strategy: .accessibilityPageAction),
    ]

    static func rule(for bundleIdentifier: String) -> Rule? {
        calibrated.first { $0.bundleIdentifier == bundleIdentifier }
    }
}
