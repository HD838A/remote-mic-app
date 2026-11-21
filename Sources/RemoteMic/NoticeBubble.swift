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

    /// 无障碍播报前缀，让 VoiceOver 先说清严重程度。
    var accessibilityPrefixKey: String? {
        switch self {
        case .tip: return nil
        case .warning: return "notice.accessibility.warning_prefix"
        case .error: return "notice.accessibility.error_prefix"
        }
    }
}

/// 气泡的一组完整语义色。柔和浅底方案同时需要底色、描边和多级文字色，
/// 分开取色容易在深浅外观之间漏掉某一项。
struct NoticeBubbleColors: Equatable {
    let fill: UInt32
    let border: UInt32
    let title: UInt32
    let body: UInt32
    let close: UInt32
    let accent: UInt32
}

/// 设计稿色值的唯一来源。
///
/// 用十六进制常量而不是直接写 `Color`，是为了让测试能脱离 SwiftUI 计算对比度，
/// 防止以后调色时悄悄破坏「正文 ≥ 4.5、图标 ≥ 3.0、深色边界 ≥ 3.0」这些硬线。
enum NoticePalette {
    /// 深色界面里气泡与之比较分离度的背景色。
    static let darkSurface: UInt32 = 0x1C1C1E

    /// 内联条和侧条使用与气泡相同的浅色底、描边和语义色；
    /// 深色内联条保持中性底，靠语义图标和动作表达档位。
    static func inlineAccent(_ tier: NoticeTier, dark: Bool) -> UInt32 {
        bubble(tier, dark: dark).accent
    }

    static func inlineSurface(_ tier: NoticeTier) -> UInt32 {
        bubble(tier, dark: false).fill
    }

    static func inlineBorder(_ tier: NoticeTier) -> UInt32 {
        bubble(tier, dark: false).border
    }

    /// 柔和浅底气泡。深色档的描边提高到 3:1，边界不依赖填充色。
    static func bubble(_ tier: NoticeTier, dark: Bool) -> NoticeBubbleColors {
        if dark {
            switch tier {
            case .tip:
                return NoticeBubbleColors(
                    fill: 0x1E2B27, border: 0x5F6F65, title: 0xE8F5EF,
                    body: 0xB9CFC5, close: 0x8FA99D, accent: 0x5FBF97
                )
            case .warning:
                return NoticeBubbleColors(
                    fill: 0x2C251A, border: 0x7A6A48, title: 0xFFF4E3,
                    body: 0xD8C4A6, close: 0xB29B79, accent: 0xD9A24E
                )
            case .error:
                return NoticeBubbleColors(
                    fill: 0x2E1F1E, border: 0x8A625A, title: 0xFFF0EE,
                    body: 0xD9B9B5, close: 0xB98E89, accent: 0xE07A70
                )
            }
        }
        switch tier {
        case .tip:
            return NoticeBubbleColors(
                fill: 0xEAF6F0, border: 0xCBE5D9, title: 0x14553F,
                body: 0x4E6A5F, close: 0x6C8A7E, accent: 0x2B7A5C
            )
        case .warning:
            return NoticeBubbleColors(
                fill: 0xFFF7E8, border: 0xF0DDBA, title: 0x6A4515,
                body: 0x7A5B2E, close: 0x8A6A3A, accent: 0xA26A1E
            )
        case .error:
            return NoticeBubbleColors(
                fill: 0xFFF1EF, border: 0xF2D2CD, title: 0x7A2C26,
                body: 0x8A4E48, close: 0xA76A63, accent: 0xB24C42
            )
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

    private var isDark: Bool { colorScheme == .dark }

    private var palette: NoticeBubbleColors {
        NoticePalette.bubble(tier, dark: isDark)
    }

    private var surface: Color { Color(hex: palette.fill) }
    private var border: Color { Color(hex: palette.border) }
    private var titleColor: Color { Color(hex: palette.title) }
    private var bodyColor: Color { Color(hex: palette.body) }
    private var closeColor: Color { Color(hex: palette.close) }
    private var accentColor: Color { Color(hex: palette.accent) }
    private var actionBackground: Color {
        accentColor.opacity(isDark ? 0.16 : 0.13)
    }

    var body: some View {
        NoticeBubbleWidthLayout(maxWidth: 400) {
            VStack(alignment: .leading, spacing: 5) {
                titleRow
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13.5))
                        .lineSpacing(3)
                        .foregroundStyle(bodyColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    actionButton(action)
                        .padding(.top, 6)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, onClose == nil ? 18 : 31)
            .padding(.vertical, 16)
        }
        .background {
            shape
                .fill(surface)
                .shadow(
                    color: .black.opacity(isDark ? 0.35 : 0.14),
                    radius: isDark ? 16 : 12,
                    x: 0,
                    y: isDark ? 9 : 6
                )
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .overlay { shape.strokeBorder(border, lineWidth: 1) }
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
                    .foregroundStyle(accentColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(titleColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ action: NoticeAction) -> some View {
        Button {
            action.perform()
        } label: {
            Text(action.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(titleColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    actionBackground,
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(closeColor)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 设计稿：图标距上 / 右 13pt。24pt 命中区内再留 7pt，
            // 12pt 图标的上缘与右缘正好落在 13pt。
            .padding(.top, 7)
            .padding(.trailing, 7)
            .accessibilityLabel(Text(noticeLocalized("notice.accessibility.dismiss")))
        }
    }

    // MARK: - 装饰

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
            ZStack {
                NoticeTailShape(edge: edge)
                    .fill(surface)
                NoticeTailOutline(edge: edge)
                    .stroke(border, lineWidth: 1)
            }
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

/// 设计稿的 400pt 是长文案上限，不是固定宽度：短文案按内容收窄，长文案在这里换行。
/// 常规 360pt 留给短提示；400pt 覆盖设计稿的英文长文案，也让中文错误标题
/// 在真实宿主（常用语失败窗 380pt）里不会把最后一个字挤到第二行。
private struct NoticeBubbleWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(maxWidth, proposal.width ?? maxWidth)
        return content.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        content.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
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

/// 尾巴外轮廓：只画两条外侧边，底边留给气泡边框接上。
struct NoticeTailOutline: Shape {
    let edge: NoticeTail.Edge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .leading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
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
