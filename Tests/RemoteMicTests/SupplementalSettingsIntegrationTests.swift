import AppKit
import SwiftUI
import XCTest
@testable import RemoteMic

@MainActor
final class SupplementalSettingsIntegrationTests: XCTestCase {
    func testMountedPageExtendsThroughTheTitlebarSafeArea() throws {
        let provider = PageGeometryProvider()
        let page = try XCTUnwrap(SupplementalSettingsIntegration(provider: provider).view(pageID: "test-page", localeIdentifier: "en"))
        let controller = NSHostingController(rootView: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 772),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1020, height: 772))
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let view = try XCTUnwrap(provider.mountedView)
        let rect = view.convert(view.bounds, to: window.contentView)
        XCTAssertEqual(rect.maxY, 772, accuracy: 1)
        XCTAssertEqual(rect.height, 772, accuracy: 1)
    }

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

@MainActor
private final class PageGeometryProvider: NSObject {
    var mountedView: NSView?
    @objc func view(forPageID pageID: String, localeIdentifier: String) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemBlue.cgColor
        mountedView = view
        return view
    }
}
