import AppKit
import Testing
@testable import RemoteMic

struct AppIconControllerTests {
    @Test @MainActor
    func catalogOnlyOffersImagesThatAreActuallyAvailable() {
        let standard = NSImage(size: NSSize(width: 64, height: 64))
        let standardOnly = AppIconCatalog(standardImage: standard)

        #expect(standardOnly.options.map(\.id) == [.standard])
        let missingIdentifier = AppIconIdentifier(rawValue: "missing")
        #expect(standardOnly.resolvedIdentifier(for: missingIdentifier) == .standard)
        #expect(standardOnly.image(for: missingIdentifier) === standard)

        let facetedDuck = NSImage(size: NSSize(width: 64, height: 64))
        let complete = AppIconCatalog(
            standardImage: standard,
            additionalOptions: [
                AppIconOption(
                    id: .facetedDuck,
                    titleKey: "about.preferences.app_icon_faceted_duck",
                    image: facetedDuck
                ),
            ]
        )

        #expect(complete.options.map(\.id) == [.standard, .facetedDuck])
        #expect(complete.resolvedIdentifier(for: .facetedDuck) == .facetedDuck)
        #expect(complete.image(for: .facetedDuck) === facetedDuck)
    }

    @Test @MainActor
    func controllerAppliesTheResolvedImageAndFallsBackSafely() {
        let standard = NSImage(size: NSSize(width: 64, height: 64))
        var appliedImage: NSImage?
        let controller = AppIconController(
            catalog: AppIconCatalog(standardImage: standard),
            applyImage: { appliedImage = $0 }
        )

        let missingIdentifier = AppIconIdentifier(rawValue: "missing")
        #expect(controller.apply(missingIdentifier, source: "test") == .standard)
        #expect(appliedImage === standard)
    }

    @Test
    func appSettingsPersistTheSelectedIcon() throws {
        let suiteName = "RemoteMic.AppIconControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.appIconIdentifier == .standard)

        settings.appIconIdentifier = .facetedDuck
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.appIconIdentifier == .facetedDuck)
    }

    @Test
    func appIconIdentifierRoundTripsThroughConfigurationExportAndImport() throws {
        let sourceSuite = "RemoteMic.AppIconControllerTests.Source.\(UUID().uuidString)"
        let destinationSuite = "RemoteMic.AppIconControllerTests.Destination.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        let destinationDefaults = try #require(UserDefaults(suiteName: destinationSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            destinationDefaults.removePersistentDomain(forName: destinationSuite)
        }

        let source = AppSettings(defaults: sourceDefaults)
        source.appIconIdentifier = .facetedDuck
        let data = try source.exportedConfigurationData()

        let destination = AppSettings(defaults: destinationDefaults)
        try destination.importConfiguration(from: data)
        #expect(destination.appIconIdentifier == .facetedDuck)
    }

    @Test
    func bundledFacetedDuckSourceAssetIsAFullSizeRoundedPNG() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Resources/AppIcons")
            .appendingPathComponent("faceted-duck.png")
        let data = try Data(contentsOf: url)
        let representation = try #require(NSBitmapImageRep(data: data))
        #expect(representation.pixelsWide == 1024)
        #expect(representation.pixelsHigh == 1024)
        #expect(representation.hasAlpha)
        let corners = [
            (0, 0),
            (representation.pixelsWide - 1, 0),
            (0, representation.pixelsHigh - 1),
            (representation.pixelsWide - 1, representation.pixelsHigh - 1),
        ]
        for (x, y) in corners {
            let alpha = representation.colorAt(x: x, y: y)?.alphaComponent ?? 1
            #expect(alpha <= (1.0 / 255.0))
        }
    }

    @Test
    func applicationIconImageAddsTransparentSafeAreaWithoutChangingCanvasSize() throws {
        let source = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }

        let result = AppIconCatalog.applicationIconImage(source, contentScale: 0.92)
        let data = try #require(result.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: data))

        #expect(result.size == source.size)
        #expect(representation.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect(representation.colorAt(x: 50, y: 50)?.alphaComponent == 1)
    }
}
