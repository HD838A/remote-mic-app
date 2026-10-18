import Foundation
import Testing
@testable import RemoteMic

@Suite("Configuration file opening")
struct ConfigurationFileOpeningTests {
    @Test func queuesAndClearsFinderConfigurationRequests() throws {
        let store = ConfigurationImportRequestStore()
        let url = URL(fileURLWithPath: "/Users/test/keyboard-profile.SAYALL")

        let request = store.enqueue(url: url)

        #expect(request.url == url)
        #expect(request.operationID == 1)
        #expect(store.pendingRequest == request)

        store.clear()

        #expect(store.pendingRequest == nil)
    }

    @Test func appInfoRegistersTheSayAllDocumentType() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoURL = root.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let sayAllDocument = try #require(documentTypes.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("com.hd838a.RemoteMic.sayall") == true
        })
        #expect(sayAllDocument["CFBundleTypeRole"] as? String == "Viewer")

        let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let sayAllType = try #require(declarations.first {
            $0["UTTypeIdentifier"] as? String == "com.hd838a.RemoteMic.sayall"
        })
        let tags = try #require(sayAllType["UTTypeTagSpecification"] as? [String: Any])
        #expect((tags["public.filename-extension"] as? [String]) == ["sayall"])
    }
}
