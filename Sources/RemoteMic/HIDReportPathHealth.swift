import Foundation

/// 一个 10 秒窗口内的 HID 报告路径计数。
///
/// 这是现场判读的核心证据：拥有设备的 monitor 在 device 回调静默后，
/// 只要 manager 回调还在投递，就应该看到 `manager_reports > 0`、
/// `device_reports == 0`，而不是两条路径都为 0。
struct HIDReportPathWindow: Equatable {
    let windowMilliseconds: Int
    let deviceReports: Int
    let managerReports: Int
    let duplicateReports: Int
    let fallbackReports: Int

    var deviceHealthy: Bool { deviceReports > 0 }
}

enum HIDReportPathHealthEvent: Equatable {
    case deviceDeliveryConfirmed
    case deviceDeliveryRecovered
    case managerFallback
    case window(HIDReportPathWindow)
    case recoveryCandidate(attempt: Int, managerReports: Int)
    case recoveryExhausted(attempts: Int)
}

/// 双路径去重之外的路径健康状态。
///
/// 旧实现只要 device 回调已注册就丢弃 manager 报告。macOS 27 上 device
/// 回调可能注册成功但不再投递，于是拥有设备的 monitor 完全收不到报告。
/// 这里按实际到达的报告统计两条路径，并在 manager 连续两个窗口有报告、
/// device 没有报告时请求重挂 device 回调。
///
/// 状态按 monitor 实例隔离；不记录设备身份、原始 payload 或用户内容。
struct HIDReportPathHealth {
    static let windowNanoseconds: UInt64 = 10_000_000_000
    static let recentDeviceWindowNanoseconds: UInt64 = 2_000_000_000
    static let recoveryThrottleNanoseconds: UInt64 = 60_000_000_000
    static let maximumRecoveryAttempts = 3

    private var windowStartNanoseconds: UInt64?
    private var lastReportNanoseconds: UInt64?
    private var lastDeviceReportNanoseconds: UInt64?
    private var deviceReports = 0
    private var managerReports = 0
    private var duplicateReports = 0
    private var fallbackReports = 0
    private var consecutiveManagerOnlyWindows = 0
    private var didLogDeviceDeliveryConfirmed = false
    private var didLogManagerFallback = false
    private var lastRecoveryNanoseconds: UInt64?
    private var recoveryAttempts = 0
    private var didLogRecoveryExhausted = false

    /// 报告线程每收到一条实际到达的报告调用一次。
    ///
    /// `recoveryEnabled` 在 macOS 27 的 device 回调路径上为 true；旧系统
    /// 只有 manager 路径时不应触发 device 回调重挂。
    mutating func record(
        path: HIDReportCallbackPath,
        duplicate: Bool,
        nowNanoseconds: UInt64,
        recoveryEnabled: Bool
    ) -> [HIDReportPathHealthEvent] {
        guard path != .simulated else { return [] }

        // 长时间没有报告时丢弃旧窗口，不补发一条没有意义的汇总。
        if let last = lastReportNanoseconds, nowNanoseconds >= last,
           nowNanoseconds - last > Self.windowNanoseconds {
            resetWindow(nowNanoseconds: nowNanoseconds)
        }
        if windowStartNanoseconds == nil {
            windowStartNanoseconds = nowNanoseconds
        }
        lastReportNanoseconds = nowNanoseconds

        var events: [HIDReportPathHealthEvent] = []
        switch path {
        case .device:
            deviceReports += 1
            lastDeviceReportNanoseconds = nowNanoseconds
            if !didLogDeviceDeliveryConfirmed {
                didLogDeviceDeliveryConfirmed = true
                if !didLogManagerFallback {
                    events.append(.deviceDeliveryConfirmed)
                }
            }
            if didLogManagerFallback {
                didLogManagerFallback = false
                events.append(.deviceDeliveryRecovered)
            }
        case .manager:
            managerReports += 1
        case .simulated:
            return []
        }

        if duplicate {
            duplicateReports += 1
        } else if path == .manager {
            let deviceIsRecent = lastDeviceReportNanoseconds.map {
                nowNanoseconds >= $0 &&
                    nowNanoseconds - $0 <= Self.recentDeviceWindowNanoseconds
            } ?? false
            if !deviceIsRecent {
                fallbackReports += 1
                if !didLogManagerFallback {
                    didLogManagerFallback = true
                    events.append(.managerFallback)
                }
            }
        }

        events.append(contentsOf: recordWindowIfNeeded(
            nowNanoseconds: nowNanoseconds,
            recoveryEnabled: recoveryEnabled
        ))
        return events
    }

    private mutating func recordWindowIfNeeded(
        nowNanoseconds: UInt64,
        recoveryEnabled: Bool
    ) -> [HIDReportPathHealthEvent] {
        guard let start = windowStartNanoseconds,
              nowNanoseconds >= start,
              nowNanoseconds - start >= Self.windowNanoseconds
        else { return [] }

        let window = HIDReportPathWindow(
            windowMilliseconds: Int((nowNanoseconds - start) / 1_000_000),
            deviceReports: deviceReports,
            managerReports: managerReports,
            duplicateReports: duplicateReports,
            fallbackReports: fallbackReports
        )
        var events: [HIDReportPathHealthEvent] = [.window(window)]

        if window.managerReports > 0, window.deviceReports == 0 {
            consecutiveManagerOnlyWindows += 1
        } else {
            consecutiveManagerOnlyWindows = 0
        }
        resetWindow(nowNanoseconds: nowNanoseconds)

        if consecutiveManagerOnlyWindows >= 2 {
            events.append(contentsOf: requestRecovery(
                nowNanoseconds: nowNanoseconds,
                managerReports: window.managerReports,
                recoveryEnabled: recoveryEnabled
            ))
        }
        return events
    }

    private mutating func requestRecovery(
        nowNanoseconds: UInt64,
        managerReports: Int,
        recoveryEnabled: Bool
    ) -> [HIDReportPathHealthEvent] {
        if let last = lastRecoveryNanoseconds,
           nowNanoseconds >= last,
           nowNanoseconds - last < Self.recoveryThrottleNanoseconds {
            return []
        }
        if recoveryAttempts >= Self.maximumRecoveryAttempts {
            guard !didLogRecoveryExhausted else { return [] }
            didLogRecoveryExhausted = true
            return [.recoveryExhausted(attempts: recoveryAttempts)]
        }

        lastRecoveryNanoseconds = nowNanoseconds
        consecutiveManagerOnlyWindows = 0
        guard recoveryEnabled else { return [] }

        recoveryAttempts += 1
        return [.recoveryCandidate(attempt: recoveryAttempts, managerReports: managerReports)]
    }

    private mutating func resetWindow(nowNanoseconds: UInt64) {
        windowStartNanoseconds = nowNanoseconds
        deviceReports = 0
        managerReports = 0
        duplicateReports = 0
        fallbackReports = 0
    }
}
