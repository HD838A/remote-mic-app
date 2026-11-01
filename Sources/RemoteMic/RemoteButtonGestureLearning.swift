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
    /// 松手到下一次按下短到不可能由手指完成的次数。报告层把一个按压拆成
    /// 相邻边沿时会走到这里，诊断日志据此区分「用户慢」与「事件重复」。
    var discardedDoubleClickEdges = 0

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
    /// 松手到下一次按下的最短可信间隔。
    ///
    /// 真机日志里出现过 0 ms 和 1 ms：报告在主线程排队后，处理时刻被压到与
    /// 相邻边沿同一毫秒，`max(0, …)` 又把负值静默变成 0。手指完成一次松手再
    /// 按下远快于 20 ms 做不到，短于它的间隔按重复边沿处理，既不写入学习结果，
    /// 也不把步骤推进到长按，让用户的下一次真实点击重新计数。
    static let minimumDoubleClickIntervalMilliseconds = 20

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
                    let interval = timestampMilliseconds - firstDoubleReleaseAt
                    if interval < Self.minimumDoubleClickIntervalMilliseconds {
                        // 重复边沿或时间戳被压缩：不可能是用户的双击第二下。
                        // 从这一次按压重新开始计数，避免把 0/1 ms 写进学习结果。
                        doublePressCount = 0
                        self.firstDoubleReleaseAt = nil
                        status.discardedDoubleClickEdges += 1
                    } else {
                        status.doubleClickMilliseconds = interval
                    }
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
