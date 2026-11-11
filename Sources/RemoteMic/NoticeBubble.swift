import SwiftUI

/// 提示气泡的语义档位。
///
/// 颜色按“用户需要的行动量”分三档，不按状态种类分：
/// 成功与引导同档，因为它们都只需要看一眼，不需要额外抢占注意力。
enum NoticeTier: String, CaseIterable {
    /// 引导、信息、成功。
    case tip
    /// 警告：需要用户判断，但仍可继续。
    case warning
    /// 错误：必须处理，或有明确失败。
    case error

    /// 替换优先级。数字越大越不会被轻提示顶掉。
    var priority: Int {
        switch self {
        case .tip: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    /// 浅色外观用深色实心底 + 微渐变；深色外观各提亮一档并改用纯色。
    ///
    /// 深色下不用渐变，是因为渐变末端更暗，会把“提亮一档”的分离度吃回去。
    func fill(for scheme: ColorScheme) -> (base: Color, deep: Color) {
        if scheme == .dark {
            let hex = NoticePalette.darkFill(self)
            return (Color(hex: hex), Color(hex: hex))
        }
        let pair = NoticePalette.lightFill(self)
        return (Color(hex: pair.base), Color(hex: pair.deep))
    }

    /// 无障碍播报前缀，让 VoiceOver 先说清严重程度。
    var accessibilityPrefixKey: String? {
        switch self {
        case .tip: return nil
        case .warning: return "notice.accessibility.warning_prefix"
        case .error: return "notice.accessibility.error_prefix"
        }
    }
}

/// 设计稿色值的唯一来源。
///
/// 用十六进制常量而不是直接写 `Color`，是为了让测试能脱离 SwiftUI 计算对比度，
/// 防止以后调色时悄悄破坏「白字 ≥ 4.5、深色底分离 ≥ 3.0」这两条硬线。
enum NoticePalette {
    /// 深色界面里气泡与之比较分离度的背景色。
    static let darkSurface: UInt32 = 0x1C1C1E

    static func lightFill(_ tier: NoticeTier) -> (base: UInt32, deep: UInt32) {
        switch tier {
        case .tip: return (0x12704A, 0x0E5E3E)
        case .warning: return (0x8A4B0F, 0x783F0B)
        case .error: return (0xA5342C, 0x96291F)
        }
    }

    static func darkFill(_ tier: NoticeTier) -> UInt32 {
        switch tier {
        case .tip: return 0x1A7A52
        case .warning: return 0x9E5611
        case .error: return 0xC04239
        }
    }

    /// 内联形态的语义色条与浅底。
    static func inlineAccent(_ tier: NoticeTier, dark: Bool) -> UInt32 {
        dark ? darkFill(tier) : lightFill(tier).base
    }

    static func inlineSurface(_ tier: NoticeTier) -> UInt32 {
        switch tier {
        case .tip: return 0xEAF7F0
        case .warning: return 0xFFFAF0
        case .error: return 0xFFF7F6
        }
    }

    static func inlineBorder(_ tier: NoticeTier) -> UInt32 {
        switch tier {
        case .tip: return 0xCFE8DB
        case .warning: return 0xF0E2C6
        case .error: return 0xF2DBD8
        }
    }

    /// 深色外观下内联条的底色：比窗口背景亮一档，靠色条表达语义。
    static let inlineDarkSurface: UInt32 = 0x2C2C2E
    static let inlineDarkBorder: UInt32 = 0x3A3A3C
}

/// 尾巴：指向锚点元素的方向。
struct NoticeTail: Equatable {
    enum Edge: Equatable {
        /// 尾巴在气泡左侧，气泡位于锚点右边。
        case leading
        /// 尾巴在气泡右侧，气泡位于锚点左边。
        case trailing
        /// 尾巴在气泡顶部，气泡位于锚点下方。
        case top
        /// 尾巴在气泡底部，气泡位于锚点上方。
        case bottom

        var isHorizontal: Bool {
            self == .leading || self == .trailing
        }
    }

    var edge: Edge

    static let leading = NoticeTail(edge: .leading)
    static let trailing = NoticeTail(edge: .trailing)
    static let top = NoticeTail(edge: .top)
    static let bottom = NoticeTail(edge: .bottom)
}

/// 气泡本体。
///
/// 只负责画：颜色、圆角、尾巴、标题 / 说明 / 一个动作 / 关闭。
/// 不持有状态、不决定何时消失——那些在 `NoticeCenter`。
struct NoticeBubble: View {
    let tier: NoticeTier
    let title: String
    var text: String?
    var action: NoticeAction?
    var tail: NoticeTail?
    var onClose: (() -> Void)?
    var accessibilityPrefix: String?

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    private var colors: (base: Color, deep: Color) {
        tier.fill(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            if let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.93))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                actionButton(action)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            LinearGradient(
                colors: [colors.base, colors.deep],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(shape)
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay { darkRim }
        .overlay(alignment: tailAlignment) { tailShape }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isStaticText)
    }

    // MARK: - 内容

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if tier == .error {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.trailing, 22)
    }

    private func actionButton(_ action: NoticeAction) -> some View {
        Button {
            action.perform()
        } label: {
            Text(action.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    .white.opacity(0.17),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(noticeLocalized("notice.accessibility.dismiss")))
        }
    }

    // MARK: - 装饰

    /// 深色外观加 1pt 白 14% 描边：深底上气泡与背景的分离只有 3:1 出头，边界需要补一手。
    @ViewBuilder
    private var darkRim: some View {
        if colorScheme == .dark {
            shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
                .accessibilityHidden(true)
        }
    }

    private var tailAlignment: Alignment {
        switch tail?.edge {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case nil: return .center
        }
    }

    @ViewBuilder
    private var tailShape: some View {
        if let tail {
            let edge = tail.edge
            NoticeTailShape(edge: edge)
                .fill(colors.base)
                .frame(
                    width: edge.isHorizontal ? 18 : 16,
                    height: edge.isHorizontal ? 10 : 9
                )
                // 向气泡外偏移，并压住 1pt 盖掉接缝
                .offset(
                    x: edge == .leading ? -17 : (edge == .trailing ? 17 : 0),
                    y: edge == .top ? -8 : (edge == .bottom ? 8 : 0)
                )
                .accessibilityHidden(true)
        }
    }

    private var accessibilityText: String {
        let prefixKey = tier.accessibilityPrefixKey ?? accessibilityPrefix
        let prefix = prefixKey.map { noticeLocalized($0) } ?? ""
        let body = [title, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "。")
        return prefix + body
    }
}

/// 尾巴三角形。尖端朝气泡外侧。
struct NoticeTailShape: Shape {
    let edge: NoticeTail.Edge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .leading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

extension Color {
    /// 设计稿里的色值都是 sRGB 十六进制，这里保持同一种写法方便对照。
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 提示组件自己的文案，和业务文案分开：这里只放动作名与无障碍标签。
func noticeLocalized(_ key: String) -> String {
    NSLocalizedString(
        key,
        bundle: RemoteMicResourceBundle.mainOrDevelopment,
        comment: ""
    )
}
