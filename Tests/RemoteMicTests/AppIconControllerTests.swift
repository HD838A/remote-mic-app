import AppKit
import Testing
@testable import RemoteMic

struct AppIconControllerTests {
    @Test @MainActor
    func catalogOnlyOffersImagesThatAreActuallyAvailable() {
        let primary = NSImage(size: NSSize(width: 64, height: 64))
        let primaryOnly = AppIconCatalog(primaryImage: primary, alternateImage: nil)

        #expect(primaryOnly.availableChoices == [.primary])
        #expect(primaryOnly.resolvedChoice(for: .alternate) == .primary)
        #expect(primaryOnly.image(for: .alternate) === primary)

        let alternate = NSImage(size: NSSize(width: 64, height: 64))
        let complete = AppIconCatalog(primaryImage: primary, alternateImage: alternate)

        #expect(complete.availableChoices == [.primary, .alternate])
        #expect(complete.resolvedChoice(for: .alternate) == .alternate)
        #expect(complete.image(for: .alternate) === alternate)
    }

    @Test @MainActor
    func controllerAppliesTheResolvedImageAndFallsBackSafely() {
        let primary = NSImage(size: NSSize(width: 64, height: 64))
        var appliedImage: NSImage?
        let controller = AppIconController(
            catalog: AppIconCatalog(primaryImage: primary, alternateImage: nil),
            applyImage: { appliedImage = $0 }
        )

        #expect(controller.apply(.alternate, source: "test") == .primary)
        #expect(appliedImage === primary)
    }

    @Test
    func appSettingsPersistTheSelectedIcon() throws {
        let suiteName = "RemoteMic.AppIconControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.appIconChoice == .primary)

        settings.appIconChoice = .alternate
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.appIconChoice == .alternate)
    }

    @Test
    func appIconChoiceRoundTripsThroughConfigurationExportAndImport() throws {
        let sourceSuite = "RemoteMic.AppIconControllerTests.Source.\(UUID().uuidString)"
        let destinationSuite = "RemoteMic.AppIconControllerTests.Destination.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        let destinationDefaults = try #require(UserDefaults(suiteName: destinationSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            destinationDefaults.removePersistentDomain(forName: destinationSuite)
        }

        let source = AppSettings(defaults: sourceDefaults)
        source.appIconChoice = .alternate
        let data = try source.exportedConfigurationData()

        let destination = AppSettings(defaults: destinationDefaults)
        try destination.importConfiguration(from: data)
        #expect(destination.appIconChoice == .alternate)
    }
}
