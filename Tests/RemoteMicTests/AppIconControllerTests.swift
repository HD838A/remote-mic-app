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

        let midnightIdentifier = AppIconIdentifier(rawValue: "midnight")
        let midnight = NSImage(size: NSSize(width: 64, height: 64))
        let complete = AppIconCatalog(
            standardImage: standard,
            additionalOptions: [
                AppIconOption(
                    id: midnightIdentifier,
                    titleKey: "about.preferences.app_icon_midnight",
                    image: midnight
                ),
            ]
        )

        #expect(complete.options.map(\.id) == [.standard, midnightIdentifier])
        #expect(complete.resolvedIdentifier(for: midnightIdentifier) == midnightIdentifier)
        #expect(complete.image(for: midnightIdentifier) === midnight)
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

        let midnightIdentifier = AppIconIdentifier(rawValue: "midnight")
        settings.appIconIdentifier = midnightIdentifier
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.appIconIdentifier == midnightIdentifier)
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
        let midnightIdentifier = AppIconIdentifier(rawValue: "midnight")
        source.appIconIdentifier = midnightIdentifier
        let data = try source.exportedConfigurationData()

        let destination = AppSettings(defaults: destinationDefaults)
        try destination.importConfiguration(from: data)
        #expect(destination.appIconIdentifier == midnightIdentifier)
    }
}
