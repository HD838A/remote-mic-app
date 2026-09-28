import AppKit
import Foundation

enum AppIconChoice: String, CaseIterable, Codable, Identifiable {
    case primary
    case alternate

    var id: String { rawValue }
}

struct AppIconCatalog {
    static let alternateResourceName = "AppIconAlternate"

    let primaryImage: NSImage
    let alternateImage: NSImage?

    var availableChoices: [AppIconChoice] {
        alternateImage == nil ? [.primary] : [.primary, .alternate]
    }

    init(primaryImage: NSImage, alternateImage: NSImage?) {
        self.primaryImage = primaryImage
        self.alternateImage = alternateImage
    }

    @MainActor
    static func live(
        resourceBundle: Bundle = RemoteMicResourceBundle.mainOrDevelopment
    ) -> AppIconCatalog {
        let primaryImage = image(
            named: "AppIcon",
            extension: "icns",
            in: resourceBundle
        ) ?? NSApplication.shared.applicationIconImage ?? NSImage(
            size: NSSize(width: 512, height: 512)
        )
        let alternateImage = image(
            named: alternateResourceName,
            extension: "png",
            in: resourceBundle
        )
        return AppIconCatalog(
            primaryImage: primaryImage,
            alternateImage: alternateImage
        )
    }

    func resolvedChoice(for requestedChoice: AppIconChoice) -> AppIconChoice {
        requestedChoice == .alternate && alternateImage == nil ? .primary : requestedChoice
    }

    func image(for requestedChoice: AppIconChoice) -> NSImage {
        switch resolvedChoice(for: requestedChoice) {
        case .primary:
            return primaryImage
        case .alternate:
            return alternateImage ?? primaryImage
        }
    }

    private static func image(
        named resourceName: String,
        extension resourceExtension: String,
        in bundle: Bundle
    ) -> NSImage? {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension
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
    func apply(_ requestedChoice: AppIconChoice, source: String) -> AppIconChoice {
        operationID &+= 1
        let currentOperationID = operationID
        AppLogger.shared.write(
            "APP_ICON CHANGE operation_id=\(currentOperationID) phase=requested " +
                "source=\(source) requested=\(requestedChoice.rawValue)"
        )

        let appliedChoice = catalog.resolvedChoice(for: requestedChoice)
        applyImage(catalog.image(for: appliedChoice))
        let result = appliedChoice == requestedChoice ? "applied" : "fallback"
        let reason = appliedChoice == requestedChoice
            ? "selection_available"
            : "resource_unavailable"
        AppLogger.shared.write(
            "APP_ICON CHANGE operation_id=\(currentOperationID) phase=completed " +
                "result=\(result) reason=\(reason) applied=\(appliedChoice.rawValue)"
        )
        return appliedChoice
    }
}
