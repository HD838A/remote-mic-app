import SwiftUI

/// 内联提示条：描述“仍然存在的状态”，不是瞬时事件。
///
/// 和 `NoticeBubble` 共用三档语义色，但没有尾巴、没有关闭按钮——
/// 状态不会因为用户点一下 × 就消失，给关闭入口反而会误导。
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if tier == .error {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    Button {
                        action.perform()
                    } label: {
                        Text(action.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
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
