import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A drop on the settings window accepts the same file families as the import panel.
/// Content routing decides whether the file belongs to settings or button profiles.
enum ConfigurationFileDropPolicy {
    static let acceptedExtensions: Set<String> = ["sayall", "json"]

    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && acceptedExtensions.contains(url.pathExtension.lowercased())
    }
}

enum ConfigurationFileDropLoader {
    static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let fileURL = item as? URL {
                    url = fileURL
                } else if let fileURL = item as? NSURL {
                    url = fileURL as URL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }
}

struct ConfigurationFileDropOverlay: View {
    let localization: LocalizationStore

    private var title: String {
        localization.text("configuration.import.drop_title")
    }

    private var detail: String {
        localization.text("configuration.import.drop_detail")
    }

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.10)
                .ignoresSafeArea()
            VStack(spacing: 9) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: title)
                    .font(.system(size: 16, weight: .semibold))
                Text(verbatim: detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title) \(detail)"))
    }
}
