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
    /// 落在 3/3 的重复边沿次数：按住时长短到不可能是长按。
    var discardedLongPressEdges = 0

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
    /// 按下远快于 20 ms 做不到，短于它的按下连同配对的松开整对忽略：双击计数
    /// 与第一次松手时刻都保持不变，用户不需要补按，随后的真实第二下照常计时。
    static let minimumDoubleClickIntervalMilliseconds = 20

    /// 长按测量的最短可信按住时长。
    ///
    /// 第二下点击之后跟着的重复边沿会落进 3/3：那对边沿只有个位数毫秒，旧实现
    /// 直接把它当成长按写进结果并结束学习。它不是用户做的长按，整对忽略后停在
    /// 3/3 即可，用户照常完成本该做的那次长按。合法范围下限是 300 ms，150 ms
    /// 远低于它，不会误伤真实长按。
    static let minimumLongPressMilliseconds = 150

    private(set) var status = RemoteButtonGestureLearningStatus()
    private var pressStartedAt: Int?
    private var firstDoubleReleaseAt: Int?
    private var doublePressCount = 0
    /// 当前这次按下被判定为重复边沿，与它配对的松开也要整对忽略，
    /// 否则那一对会把双击计数推过一次，直接跳进长按步骤。
    private var ignoresNextRelease = false

    mutating func start(model: XiaomiRemoteModel) {
        status = RemoteButtonGestureLearningStatus(step: .singleClick, model: model)
        pressStartedAt = nil
        firstDoubleReleaseAt = nil
        doublePressCount = 0
        ignoresNextRelease = false
    }

    mutating func cancel() {
        status = RemoteButtonGestureLearningStatus()
        pressStartedAt = nil
        firstDoubleReleaseAt = nil
        doublePressCount = 0
        ignoresNextRelease = false
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
                        // 重复边沿不是用户的第二次按下：这一对按下/松开整对忽略，
                        // 双击计数不变，用户随后的真实第二下仍从第一次松手计时。
                        ignoresNextRelease = true
                        status.discardedDoubleClickEdges += 1
                    } else {
                        ignoresNextRelease = false
                        status.doubleClickMilliseconds = interval
                    }
                } else {
                    ignoresNextRelease = false
                }
                pressStartedAt = timestampMilliseconds
            } else if pressStartedAt != nil {
                pressStartedAt = nil
                if ignoresNextRelease {
                    ignoresNextRelease = false
                } else {
                    doublePressCount += 1
                    if doublePressCount == 1 {
                        firstDoubleReleaseAt = timestampMilliseconds
                    } else {
                        firstDoubleReleaseAt = nil
                        status.step = .longPress
                    }
                }
            }
        case .longPress:
            if phase == .press {
                pressStartedAt = timestampMilliseconds
            } else if let pressStartedAt,
                      let single = status.singleClickMilliseconds,
                      let double = status.doubleClickMilliseconds {
                let long = timestampMilliseconds - pressStartedAt
                self.pressStartedAt = nil
                guard long >= Self.minimumLongPressMilliseconds else {
                    // 重复边沿不是长按：留在 3/3，用户照常做自己那次长按即可。
                    status.discardedLongPressEdges += 1
                    return nil
                }
                status.longPressMilliseconds = long
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
