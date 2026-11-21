import AppKit

/// 语音时长倒计时的屏幕坐标。
///
/// 语音输入的提示条（豆包、微信输入法等）固定在屏幕**下方居中**，位置和光标无关，
/// 所以倒计时也固定在屏幕上方居中显示：用户看同一个区域就能同时看到提示条和数字，
/// 不需要在光标和提示条之间来回找。
enum VoiceLimitCountdownAnchor {
    /// 浮层中心距屏幕底部的比例。语音输入提示条占据最底部一条，
    /// 浮层紧贴它上方，让两件东西在同一片视线里且互不遮挡。
    static let centerHeightRatio: CGFloat = 0.16
    /// 浮层与可见区域边缘的最小留白。
    static let screenInset: CGFloat = 24

    /// 浮层左下角在屏幕坐标中的位置（原点在主屏左下角，与 `NSPanel` 一致）。
    ///
    /// 只依赖屏幕可见区域，不读取任何目标 App、光标或输入法状态。
    static func placement(
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.minY + visibleFrame.height * centerHeightRatio - panelSize.height / 2
        return CGPoint(
            x: clamp(x, lower: visibleFrame.minX + screenInset, upper: visibleFrame.maxX - panelSize.width - screenInset),
            y: clamp(y, lower: visibleFrame.minY + 120, upper: visibleFrame.maxY - panelSize.height - screenInset)
        )
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        // 可见区域比浮层还小时以 lower 为准，避免上下界打架后给出负值。
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}
