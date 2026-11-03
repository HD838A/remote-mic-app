import Foundation

/// 虚拟声卡自身的音量：由 App 独占并固定写成 100%，用户只通过 `VirtualAudioOutputLevelPolicy` 的
/// 单一「音量」调节。这样设备音量既不会被子系统的外部改动留在低位，也不会和界面上的滑块打架。
enum VirtualAudioDeviceLevelPolicy {
    /// BlackHole 系驱动把 `kAudioDevicePropertyVolumeScalar` 编码成 dB：0 对应 −64 dB，1 对应 0 dB，
    /// 因此 1 才是「不衰减」。
    static let fixedVolumeScalar: Float32 = 1
    /// 驱动标量的比较容差，覆盖 dB 与线性幅度来回换算的舍入误差。
    static let volumeTolerance: Float32 = 0.002

    static func requiresUnmute(mute: Bool?) -> Bool {
        mute == true
    }

    static func requiresVolumeAdjustment(volume: Float32?, target: Float32) -> Bool {
        guard let volume, volume.isFinite else { return false }
        return abs(volume - target) > volumeTolerance
    }
}

/// 用户可见的唯一音量。0% 静音，100% 是原始音量，上限 1000%（约 +20 dB）。
/// 它作用在 `VirtualAudioOutput` 写缓冲的唯一出口，因此对所有遥控器链路一致生效。
///
/// 单独成文件的原因：`scripts/test.sh` 用 `xcrun swiftc` 手工列出自测二进制要编译的源文件，
/// 而 `AppSettings.swift` 在该列表里、`AudioOutput.swift` 不在。策略本身只依赖 Foundation，
/// 因此放在这里既能被 App 也能被自测二进制引用。
enum VirtualAudioOutputLevelPolicy {
    static let percentRange: ClosedRange<Double> = 0...1000
    static let defaultPercent: Double = 100
    /// 0% 没有对应的分贝值；对外暴露 dB 时用它兜底，避免 −inf 传到界面。
    static let floorDecibels: Double = -60

    static func clampedPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return defaultPercent }
        return min(percentRange.upperBound, max(percentRange.lowerBound, percent))
    }

    static func linearScale(percent: Double) -> Float {
        Float(clampedPercent(percent) / 100)
    }

    static func decibels(percent: Double) -> Double {
        let clamped = clampedPercent(percent)
        guard clamped > 0 else { return floorDecibels }
        // 保留两位小数：`percent(decibels:)` 的往返误差不应让「3 dB」变成 3.0000000000000004。
        return (20 * log10(clamped / 100) * 100).rounded() / 100
    }

    static func percent(decibels: Double) -> Double {
        guard decibels.isFinite else { return defaultPercent }
        // 与 `decibels(percent: 0)` 保持可逆，避免「静音」经 dB 往返变成 0.1%。
        guard decibels > floorDecibels else { return 0 }
        return clampedPercent(pow(10, decibels / 20) * 100)
    }

    static func clampedSample(_ sample: Float, scale: Float) -> Float {
        let scaled = sample * scale
        guard scaled.isFinite else { return 0 }
        return min(1, max(-1, scaled))
    }

    /// 把解码后的 Int16 PCM 归一化并按用户音量缩放，是写缓冲前的最后一步。
    static func scaled(_ samples: [Int16], scale: Float) -> [Float] {
        samples.map { clampedSample(Float($0) / Float(Int16.max), scale: scale) }
    }
}
