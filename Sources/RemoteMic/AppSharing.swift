import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum AppShareLink {
    static let sourceName = "mac_share"

    static func url(for locale: Locale) -> URL {
        url(byAddingSourceTo: AppLinks.website(for: locale))
    }

    static func url(byAddingSourceTo baseURL: URL) -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return baseURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("from") == .orderedSame }
        queryItems.append(URLQueryItem(name: "from", value: sourceName))
        components.queryItems = queryItems
        return components.url ?? baseURL
    }
}

enum AppShareClipboard {
    static func string(for url: URL) -> String {
        url.absoluteString
    }

    static func copy(
        _ url: URL,
        using writer: (String) -> Bool
    ) -> Bool {
        writer(string(for: url))
    }

    static func copyToGeneralPasteboard(_ url: URL) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return copy(url) { pasteboard.setString($0, forType: .string) }
    }
}

enum AppShareQRCode {
    static func payload(for url: URL) -> Data {
        Data(AppShareClipboard.string(for: url).utf8)
    }

    static func image(for url: URL, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = payload(for: url)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let transformedImage = outputImage.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let representation = NSCIImageRep(ciImage: transformedImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
