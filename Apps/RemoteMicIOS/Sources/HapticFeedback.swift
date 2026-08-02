import CoreHaptics
import UIKit

@MainActor
final class HapticFeedback {
    enum Strength {
        case standard
        case emphasized
        case release
    }

    static let shared = HapticFeedback()

    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private let standardGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let emphasizedGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let releaseGenerator = UISelectionFeedbackGenerator()

    private init() {}

    func prepare() {
        guard supportsHaptics else { return }
        standardGenerator.prepare()
        emphasizedGenerator.prepare()
        releaseGenerator.prepare()
    }

    func trigger(_ strength: Strength) {
        guard supportsHaptics else { return }

        switch strength {
        case .standard:
            standardGenerator.impactOccurred(intensity: 0.72)
            standardGenerator.prepare()
        case .emphasized:
            emphasizedGenerator.impactOccurred(intensity: 0.9)
            emphasizedGenerator.prepare()
        case .release:
            releaseGenerator.selectionChanged()
            releaseGenerator.prepare()
        }
    }
}
