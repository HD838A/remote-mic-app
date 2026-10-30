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
        case lineWheel

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "accessibilityPageAction": self = .accessibilityPageAction
            // `pixelWheel` was written by early builds; treat it as a line wheel.
            case "lineWheel", "pixelWheel": self = .lineWheel
            default: self = .lineWheel
            }
        }
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
    /// Wheel chunks were accepted by the queue; the final result arrives in the
    /// log as `completed` or `aborted`, never as a synchronous success.
    case queued
    /// Remaining chunks were cancelled because the target changed or a newer
    /// page request superseded this one.
    case cancelled
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

    var wasHandled: Bool {
        didScroll || self == .queued
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
    static let linesPerChunk: Int32 = 30
    static let chunkPoints: Double = 215
    static let maximumPageChunks = 3
    static let chunkInterval: TimeInterval = 0.060

    /// Number of wheel chunks that approximate one viewport.
    static func pageScrollChunks(regionHeight: Double) -> Int {
        guard regionHeight > 0 else { return 1 }
        let target = regionHeight * (1 - overlapRatio)
        return min(maximumPageChunks, max(1, Int((target / chunkPoints).rounded())))
    }

    /// Rejects records that would map outside the target window.
    static func isValid(normalizedFrame frame: NormalizedAccessibilityFrame) -> Bool {
        let values = [frame.x, frame.y, frame.width, frame.height]
        guard values.allSatisfy(\.isFinite) else { return false }
        guard frame.width > 0, frame.height > 0 else { return false }
        guard (0...1).contains(frame.x), (0...1).contains(frame.y) else { return false }
        return frame.x + frame.width <= 1.0001 && frame.y + frame.height <= 1.0001
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
    /// How a preset app finds its region without learning.
    enum Placement: String {
        /// Use the measured content container when one is smaller than the window.
        case container
        /// Scroll the window rectangle at its centre. Used for apps that expose a
        /// single whole-window web area; safer than picking the largest container,
        /// which can be a sidebar.
        case windowRect
    }

    struct Rule {
        let bundleIdentifier: String
        let strategy: ScrollRegionTarget.Strategy
        let placement: Placement
    }

    /// Every app the product ships as a preset works without learning. Apps with
    /// a measured content container use it; the rest scroll the window rectangle,
    /// and the UI reports them as built-in rather than asking for learning.
    static let rules: [Rule] = [
        Rule(bundleIdentifier: "com.cmuxterm.app", strategy: .accessibilityPageAction, placement: .container),
        Rule(bundleIdentifier: "com.tencent.WeWorkMac", strategy: .accessibilityPageAction, placement: .container),
        Rule(bundleIdentifier: "com.google.Chrome", strategy: .lineWheel, placement: .container),
        Rule(bundleIdentifier: "com.tinyspeck.slackmacgap", strategy: .lineWheel, placement: .container),
        Rule(bundleIdentifier: "com.openai.codex", strategy: .lineWheel, placement: .container),
        Rule(bundleIdentifier: "com.tencent.workbuddy.mac", strategy: .lineWheel, placement: .windowRect),
    ]

    static func rule(for bundleIdentifier: String) -> Rule? {
        rules.first { $0.bundleIdentifier == bundleIdentifier }
            ?? PresetApplication.allCases
                .first { $0.bundleIdentifier == bundleIdentifier }
                .map { _ in Rule(bundleIdentifier: bundleIdentifier, strategy: .lineWheel, placement: .windowRect) }
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
