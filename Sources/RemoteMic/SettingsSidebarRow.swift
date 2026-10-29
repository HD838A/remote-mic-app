import SwiftUI

/// Shared by navigation and the account entry so multi-line labels keep the same alignment.
struct SettingsSidebarRow: View {
    let title: Text
    let systemImage: String
    var showsUpdateBadge = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .resizable()
                .scaledToFit()
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            title
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsUpdateBadge {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, showsUpdateBadge ? 7 : 5)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }
}
