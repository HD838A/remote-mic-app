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
    private let standardGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let emphasizedGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let releaseGenerator = UIImpactFeedbackGenerator(style: .light)

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
            standardGenerator.impactOccurred(intensity: 1)
            standardGenerator.prepare()
        case .emphasized:
            emphasizedGenerator.impactOccurred(intensity: 1)
            emphasizedGenerator.prepare()
        case .release:
            releaseGenerator.impactOccurred(intensity: 0.8)
            releaseGenerator.prepare()
        }
    }
}
