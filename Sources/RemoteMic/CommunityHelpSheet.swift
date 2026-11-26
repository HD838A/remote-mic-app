import AppKit
import SwiftUI

enum CommunityHelpEntrySource: String {
    case onboarding
    case settings
}

enum CommunityHelpLog {
    static func write(_ action: String, source: CommunityHelpEntrySource) {
        AppLogger.shared.write(
            "COMMUNITY_HELP action=\(action) source=\(source.rawValue)"
        )
    }
}

struct CommunityHelpSheet: View {
    let localization: LocalizationStore
    let source: CommunityHelpEntrySource
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCloseFocused: Bool

    private struct Card: Identifiable {
        let id: String
        let titleKey: String
        let hintKey: String
        let accessibilityKey: String
        let imageName: String
        let usesDarkBackground: Bool
    }

    // 当前中英文都展示抖音 + 小红书。英文版后续若改为 X（x.com/getsayall）
    // + 小红书，只替换第一张卡的文案、资源和动作；Sheet 布局不变。
    private static let cards: [Card] = [
        Card(
            id: "douyin",
            titleKey: "community.help.douyin_title",
            hintKey: "community.help.douyin_hint",
            accessibilityKey: "community.help.douyin_accessibility",
            imageName: "community-help-douyin-qr",
            usesDarkBackground: true
        ),
        Card(
            id: "xiaohongshu",
            titleKey: "community.help.xiaohongshu_title",
            hintKey: "community.help.xiaohongshu_hint",
            accessibilityKey: "community.help.xiaohongshu_accessibility",
            imageName: "community-help-xiaohongshu-qr",
            usesDarkBackground: false
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: localization.text("community.help.title"))
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: localization.text("community.help.intro"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 18) {
                ForEach(Self.cards) { card in
                    cardView(card)
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button(localization.text("common.action.close")) {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                .focused($isCloseFocused)
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear {
            CommunityHelpLog.write("presented", source: source)
            DispatchQueue.main.async {
                isCloseFocused = true
            }
        }
        .onDisappear {
            CommunityHelpLog.write("closed", source: source)
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func cardView(_ card: Card) -> some View {
        VStack(spacing: 0) {
            qrImage(named: card.imageName, darkBackground: card.usesDarkBackground)
                .frame(width: 205, height: 205)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .accessibilityLabel(Text(
                    verbatim: localization.text(card.accessibilityKey)
                ))

            Text(verbatim: localization.text(card.titleKey))
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

            Text(verbatim: localization.text(card.hintKey))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity)
    }

    private func qrImage(named name: String, darkBackground: Bool) -> some View {
        ZStack {
            darkBackground ? Color.black : Color.white
            if let image = bundledImage(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bundledImage(named name: String) -> NSImage? {
        guard let url = RemoteMicResourceBundle.mainOrDevelopment.url(
            forResource: name,
            withExtension: "png"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

struct CommunityHelpOverlay: View {
    let localization: LocalizationStore
    let source: CommunityHelpEntrySource
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    onClose()
                }

            CommunityHelpSheet(
                localization: localization,
                source: source,
                onClose: onClose
            )
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
        }
        .onExitCommand {
            onClose()
        }
        .accessibilityElement(children: .contain)
    }
}
