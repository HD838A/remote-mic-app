import AppKit
import XCTest
@testable import RemoteMic

@MainActor
final class SupplementalSettingsIntegrationTests: XCTestCase {
    func testMissingOrOldProviderDoesNotAddPages() {
        XCTAssertTrue(SupplementalSettingsIntegration(provider: NSObject()).pages(localeIdentifier: "en").isEmpty)
        XCTAssertNil(SupplementalSettingsIntegration(provider: NSObject()).view(pageID: "test-page", localeIdentifier: "en"))
    }
    func testMetadataValidationRejectsDuplicatesAndInvalidIdentifiers() {
        let pages = SupplementalSettingsIntegration.validPages([
            ["id": "test-page", "title": "Test", "systemImage": "star"],
            ["id": "test-page", "title": "Duplicate", "systemImage": "star"],
            ["id": "../account", "title": "Invalid", "systemImage": "star"],
            ["id": "empty", "title": "", "systemImage": "star"]
        ])
        XCTAssertEqual(pages, [SupplementalSettingsPage(id: "test-page", title: "Test", systemImage: "star")])
    }
    func testPrivatePagesAreMountedWithoutMembershipVisibility() {
        let sections = SettingsPageBehavior.sidebarSections(privateFeatureVisible: false, macroFeatureVisible: false, buttonProfilesVisible: false, membershipVisible: false, supplementalPageIDs: ["test-page"])
        XCTAssertTrue(sections.contains(.supplemental("test-page")))
        XCTAssertFalse(sections.contains(.membership))
        XCTAssertEqual(SettingsSection.supplemental("test-page").supplementalID, "test-page")
    }
}
