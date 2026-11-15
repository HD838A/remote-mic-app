import Foundation

/// 决定何时为刚发现的 HID 指纹重建一组全新的 profile monitor。
///
/// 现场日志 `9E9EB1D0`：discovery monitor 探测到已知遥控器后被提升为
/// profile monitor，接收了一条 `volume_up`，随后 device 与 manager 回调
/// 同时静默；新启动的 discovery monitor 收到后续 73 条报告，全部按
/// `excluded_fingerprint` 拒绝。提升旧 monitor 不能恢复投递，必须在提升后
/// 重新创建 `IOHIDManager` 和 device callback。
enum HIDMonitorRebuildPolicy {
    static func shouldSchedule(
        started: Bool,
        customMappingEnabled: Bool,
        isStreaming: Bool
    ) -> Bool {
        started && customMappingEnabled && !isStreaming
    }

    static func shouldRetryAfterVoiceStop(
        wasDeferred: Bool,
        started: Bool,
        customMappingEnabled: Bool
    ) -> Bool {
        wasDeferred && started && customMappingEnabled
    }
}
