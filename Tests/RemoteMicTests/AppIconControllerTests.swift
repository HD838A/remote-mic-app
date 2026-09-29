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
    func bundledFacetedDuckSourceAssetsAreFullSizePNGs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for resourceName in ["faceted-duck", "faceted-duck-intel"] {
            let url = root
                .appendingPathComponent("Resources/AppIcons")
                .appendingPathComponent("\(resourceName).png")
            let data = try Data(contentsOf: url)
            let representation = try #require(NSBitmapImageRep(data: data))
            #expect(representation.pixelsWide == 1024)
            #expect(representation.pixelsHigh == 1024)
        }
    }
}
