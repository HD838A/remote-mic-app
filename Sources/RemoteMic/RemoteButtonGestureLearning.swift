import Foundation

enum RemoteButtonGestureLearningStep: String, Equatable {
    case idle
    case singleClick
    case doubleClick
    case longPress
    case complete
}

struct RemoteButtonGestureLearningResult: Equatable {
    let singleClickMilliseconds: Int
    let doubleClickMilliseconds: Int
    let longPressMilliseconds: Int
    let suggestedTiming: RemoteButtonGestureTiming
    let adjustedToAllowedRange: Bool
}

struct RemoteButtonGestureLearningStatus: Equatable {
    var step: RemoteButtonGestureLearningStep = .idle
    var model: XiaomiRemoteModel?
    var button: RemoteButton?
    var singleClickMilliseconds: Int?
    var doubleClickMilliseconds: Int?
    var longPressMilliseconds: Int?
    var adjustedToAllowedRange = false

    var isActive: Bool {
        step != .idle && step != .complete
    }
}

struct RemoteButtonGestureLearningAvailability: Equatable {
    let canSaveTiming: Bool
    let canLearn: Bool

    init(model: XiaomiRemoteModel?, isConnected: Bool) {
        canSaveTiming = model != nil && model != .unknown
        canLearn = canSaveTiming && isConnected
    }
}

/// Measures one single click, one double click and one long press on the same physical button.
/// Timestamps use a monotonic clock supplied by the caller.
struct RemoteButtonGestureLearner {
    private(set) var status = RemoteButtonGestureLearningStatus()
    private var pressStartedAt: Int?
    private var firstDoubleReleaseAt: Int?
    private var doublePressCount = 0

    mutating func start(model: XiaomiRemoteModel) {
        status = RemoteButtonGestureLearningStatus(step: .singleClick, model: model)
        pressStartedAt = nil
        firstDoubleReleaseAt = nil
        doublePressCount = 0
    }

    mutating func cancel() {
        status = RemoteButtonGestureLearningStatus()
        pressStartedAt = nil
        firstDoubleReleaseAt = nil
        doublePressCount = 0
    }

    mutating func handle(
        _ phase: RemoteButtonPhase,
        button: RemoteButton,
        model: XiaomiRemoteModel,
        timestampMilliseconds: Int
    ) -> RemoteButtonGestureLearningResult? {
        guard status.isActive, status.model == model else { return nil }
        if let learnedButton = status.button {
            guard learnedButton == button else { return nil }
        } else if phase == .press {
            status.button = button
        }
        guard status.button == button else { return nil }

        switch status.step {
        case .singleClick:
            if phase == .press {
                pressStartedAt = timestampMilliseconds
            } else if let pressStartedAt {
                status.singleClickMilliseconds = max(0, timestampMilliseconds - pressStartedAt)
                self.pressStartedAt = nil
                status.step = .doubleClick
            }
        case .doubleClick:
            if phase == .press {
                if doublePressCount == 1, let firstDoubleReleaseAt {
                    status.doubleClickMilliseconds = max(0, timestampMilliseconds - firstDoubleReleaseAt)
                }
                pressStartedAt = timestampMilliseconds
            } else if pressStartedAt != nil {
                pressStartedAt = nil
                doublePressCount += 1
                if doublePressCount == 1 {
                    firstDoubleReleaseAt = timestampMilliseconds
                } else {
                    firstDoubleReleaseAt = nil
                    status.step = .longPress
                }
            }
        case .longPress:
            if phase == .press {
                pressStartedAt = timestampMilliseconds
            } else if let pressStartedAt,
                      let single = status.singleClickMilliseconds,
                      let double = status.doubleClickMilliseconds {
                let long = max(0, timestampMilliseconds - pressStartedAt)
                status.longPressMilliseconds = long
                self.pressStartedAt = nil
                let roundedDouble = Self.rounded(double, step: 50, direction: .up)
                let roundedLong = Self.rounded(long, step: 50, direction: .down)
                let suggested = RemoteButtonGestureTiming(
                    doubleClickMilliseconds: min(500, max(150, roundedDouble)),
                    longPressMilliseconds: min(1000, max(300, roundedLong))
                )
                let adjusted = suggested.doubleClickMilliseconds != double ||
                    suggested.longPressMilliseconds != long
                status.adjustedToAllowedRange = adjusted
                status.step = .complete
                return RemoteButtonGestureLearningResult(
                    singleClickMilliseconds: single,
                    doubleClickMilliseconds: double,
                    longPressMilliseconds: long,
                    suggestedTiming: suggested,
                    adjustedToAllowedRange: adjusted
                )
            }
        case .idle, .complete:
            break
        }
        return nil
    }

    private enum RoundingDirection {
        case up
        case down
    }

    private static func rounded(_ value: Int, step: Int, direction: RoundingDirection) -> Int {
        guard value > 0 else { return 0 }
        switch direction {
        case .up:
            return ((value + step - 1) / step) * step
        case .down:
            return (value / step) * step
        }
    }
}
