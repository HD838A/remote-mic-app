import SwiftUI

/// 内联提示条：描述“仍然存在的状态”，不是瞬时事件。
///
/// 形态回到 v3 7.3：`[图标 16] [标题 + 说明] [右侧动作]` 一行排开。
/// 状态不会因为用户点一下 × 就消失，所以没有关闭入口——给 × 反而会误导。
struct NoticeInline: View {
    let tier: NoticeTier
    let title: String
    var text: String?
    var action: NoticeAction?

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private var accent: Color {
        Color(hex: NoticePalette.inlineAccent(tier, dark: isDark))
    }

    private var surface: Color {
        isDark
            ? Color(hex: NoticePalette.inlineDarkSurface)
            : Color(hex: NoticePalette.inlineSurface(tier))
    }

    private var border: Color {
        isDark
            ? Color(hex: NoticePalette.inlineDarkBorder)
            : Color(hex: NoticePalette.inlineBorder(tier))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var iconName: String {
        switch tier {
        case .tip: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(accent)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let action {
                Button {
                    action.perform()
                } label: {
                    Text(action.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accent)
                        .fixedSize()
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: shape)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .accessibilityHidden(true)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(border, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        let prefixKey = tier.accessibilityPrefixKey
        let prefix = prefixKey.map { noticeLocalized($0) } ?? ""
        let body = [title, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "。")
        return prefix + body
    }
}
