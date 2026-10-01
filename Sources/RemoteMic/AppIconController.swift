import AppKit
import Foundation

struct AppIconIdentifier: RawRepresentable, Hashable, Identifiable, Codable {
    static let standard = AppIconIdentifier(rawValue: "standard")
    static let facetedDuck = AppIconIdentifier(rawValue: "faceted-duck")

    let rawValue: String

    var id: String { rawValue }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AppIconOption: Identifiable {
    let id: AppIconIdentifier
    let titleKey: String
    let image: NSImage
}

private struct BundledAppIconDefinition {
    let id: AppIconIdentifier
    let resourceName: String
    let titleKey: String
    let contentScale: CGFloat
}

struct AppIconCatalog {
    // Register future icons here with a stable semantic ID and a matching
    // Resources/AppIcons/<resourceName>.png file.
    private static let bundledDefinitions: [BundledAppIconDefinition] = [
        BundledAppIconDefinition(
            id: .facetedDuck,
            resourceName: "faceted-duck",
            titleKey: "about.preferences.app_icon_faceted_duck",
            contentScale: 0.92
        ),
    ]

    let options: [AppIconOption]

    init(standardImage: NSImage, additionalOptions: [AppIconOption] = []) {
        options = [
            AppIconOption(
                id: .standard,
                titleKey: "about.preferences.app_icon_standard",
                image: standardImage
            ),
        ] + additionalOptions.filter { $0.id != .standard }
    }

    @MainActor
    static func live(
        resourceBundle: Bundle = RemoteMicResourceBundle.mainOrDevelopment
    ) -> AppIconCatalog {
        let standardImage = image(
            named: "AppIcon",
            extension: "icns",
            in: resourceBundle
        ) ?? NSApplication.shared.applicationIconImage ?? NSImage(
            size: NSSize(width: 512, height: 512)
        )
        let additionalOptions = bundledDefinitions.compactMap { definition in
            image(
                named: definition.resourceName,
                extension: "png",
                subdirectory: "AppIcons",
                in: resourceBundle
            ).map { sourceImage in
                AppIconOption(
                    id: definition.id,
                    titleKey: definition.titleKey,
                    image: applicationIconImage(
                        sourceImage,
                        contentScale: definition.contentScale
                    )
                )
            }
        }
        return AppIconCatalog(
            standardImage: standardImage,
            additionalOptions: additionalOptions
        )
    }

    func resolvedIdentifier(for requestedIdentifier: AppIconIdentifier) -> AppIconIdentifier {
        options.contains { $0.id == requestedIdentifier } ? requestedIdentifier : .standard
    }

    func image(for requestedIdentifier: AppIconIdentifier) -> NSImage {
        option(for: requestedIdentifier).image
    }

    private func option(for requestedIdentifier: AppIconIdentifier) -> AppIconOption {
        options.first { $0.id == requestedIdentifier } ?? options[0]
    }

    static func applicationIconImage(
        _ sourceImage: NSImage,
        contentScale: CGFloat
    ) -> NSImage {
        let clampedScale = min(max(contentScale, 0.1), 1)
        guard clampedScale < 1 else { return sourceImage }

        let result = NSImage(size: sourceImage.size, flipped: false) { canvas in
            NSGraphicsContext.current?.imageInterpolation = .high
            let contentSize = NSSize(
                width: canvas.width * clampedScale,
                height: canvas.height * clampedScale
            )
            let contentRect = NSRect(
                x: canvas.midX - contentSize.width / 2,
                y: canvas.midY - contentSize.height / 2,
                width: contentSize.width,
                height: contentSize.height
            )
            sourceImage.draw(
                in: contentRect,
                from: NSRect(origin: .zero, size: sourceImage.size),
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        result.isTemplate = sourceImage.isTemplate
        return result
    }

    private static func image(
        named resourceName: String,
        extension resourceExtension: String,
        subdirectory: String? = nil,
        in bundle: Bundle
    ) -> NSImage? {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: subdirectory
        ) else { return nil }
        return NSImage(contentsOf: url)
    }
}

@MainActor
final class AppIconController {
    let catalog: AppIconCatalog

    private let applyImage: (NSImage) -> Void
    private var operationID: UInt = 0

    init() {
        catalog = .live()
        applyImage = { image in
            NSApplication.shared.applicationIconImage = image
        }
    }

    init(
        catalog: AppIconCatalog,
        applyImage: @escaping (NSImage) -> Void
    ) {
        self.catalog = catalog
        self.applyImage = applyImage
    }

    @discardableResult
    func apply(
        _ requestedIdentifier: AppIconIdentifier,
        source: String
    ) -> AppIconIdentifier {
        operationID &+= 1
        let currentOperationID = operationID
        let appliedIdentifier = catalog.resolvedIdentifier(for: requestedIdentifier)
        let requestedLogIdentifier = appliedIdentifier == requestedIdentifier
            ? appliedIdentifier.rawValue
            : "unavailable"
        AppLogger.shared.write(
            "APP_ICON CHANGE operation_id=\(currentOperationID) phase=requested " +
                "source=\(source) requested=\(requestedLogIdentifier)"
        )

        applyImage(catalog.image(for: appliedIdentifier))
        let result = appliedIdentifier == requestedIdentifier ? "applied" : "fallback"
        let reason = appliedIdentifier == requestedIdentifier
            ? "selection_available"
            : "resource_unavailable"
        AppLogger.shared.write(
            "APP_ICON CHANGE operation_id=\(currentOperationID) phase=completed " +
                "result=\(result) reason=\(reason) applied=\(appliedIdentifier.rawValue)"
        )
        return appliedIdentifier
    }
}
