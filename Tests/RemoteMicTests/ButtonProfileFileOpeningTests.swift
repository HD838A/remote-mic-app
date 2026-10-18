import Foundation
import AppKit
import SwiftUI
import Testing
@testable import RemoteMic

@Suite("Button profile file opening", .serialized)
struct ButtonProfileFileOpeningTests {
    @MainActor
    @Test(arguments: [false, true])
    func consumesFinderRequestsBeforeAndAfterMounting(queuedBeforeMount: Bool) throws {
        let suite = "RemoteMic.ButtonProfileFileOpening.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.completeOnboarding()
        let model = BridgeAppModel(settings: settings)
        let requests = ButtonProfileImportRequestStore()
        let marketRoot = ProcessInfo.processInfo.environment["SAYALL_MARKET_CONTRACT_PATH"]
        let url = marketRoot.map {
            URL(fileURLWithPath: $0).appendingPathComponent("examples/profiles/full-keyboard-access-mac.sayall")
        } ?? URL(fileURLWithPath: "/Users/test/profile.sayall")
        if queuedBeforeMount { requests.enqueue(url: url) }
        let controller = NSHostingController(rootView: SettingsView(
            model: model,
            buttonProfileImportRequests: requests,
            updateInformation: UpdateInformationStore(userDefaults: defaults),
            initialSection: .connection
        ).environmentObject(LocalizationStore(settings: settings)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 772),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        if !queuedBeforeMount { requests.enqueue(url: url) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(requests.pendingRequest == nil)
        #expect(!settings.customMappingEnabled)
        if marketRoot != nil, model.macroFeature.isButtonProfilesVisible {
            #expect(model.macroFeature.isEditorActive)
        }

        // A new request for the same file must also be consumed.
        requests.enqueue(url: url)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(requests.pendingRequest == nil)
        #expect(!settings.customMappingEnabled)
        if marketRoot != nil, model.macroFeature.isButtonProfilesVisible {
            #expect(model.macroFeature.isEditorActive)
        }
    }

    @Test func queuesAndClearsFinderButtonProfileRequests() throws {
        let store = ButtonProfileImportRequestStore()
        let url = URL(fileURLWithPath: "/Users/test/keyboard-profile.SAYALL")

        let request = store.enqueue(url: url)

        #expect(request.url == url)
        #expect(request.operationID == 1)
        #expect(store.pendingRequest == request)

        store.clear()

        #expect(store.pendingRequest == nil)
    }

    @MainActor
    @Test func retainsFinderRequestDuringOnboarding() throws {
        let suite = "RemoteMic.ButtonProfileFileOpening.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = BridgeAppModel(settings: settings)
        let requests = ButtonProfileImportRequestStore()
        let request = requests.enqueue(url: URL(fileURLWithPath: "/Users/test/profile.sayall"))
        let controller = NSHostingController(rootView: RemoteMicRootView(
            model: model,
            buttonProfileImportRequests: requests,
            updateInformation: UpdateInformationStore(userDefaults: defaults),
            checkForUpdates: {}, refreshUpdateInformation: {},
            setDockIconVisible: { _ in }, setStatusBarIconVisible: { _ in },
            syncEntryPointVisibility: {}
        ).environmentObject(LocalizationStore(settings: settings)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 772),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(!settings.isOnboardingComplete)
        #expect(requests.pendingRequest == request)
        #expect(!model.macroFeature.isEditorActive)
        #expect(!settings.customMappingEnabled)
    }

    @Test func rejectsDeepLinksAndOtherFileTypes() throws {
        let feature = MacroFeatureIntegration()
        #expect(!feature.requestButtonProfileImport(from: try #require(
            URL(string: "sayall://launch/profile.sayall")
        )))
        #expect(!feature.requestButtonProfileImport(from: URL(fileURLWithPath: "/Users/test/profile.json")))
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
        #expect(sayAllDocument["CFBundleTypeName"] as? String == "SayAll Button Profile")
        #expect(sayAllDocument["CFBundleTypeRole"] as? String == "Viewer")

        let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let sayAllType = try #require(declarations.first {
            $0["UTTypeIdentifier"] as? String == "com.hd838a.RemoteMic.sayall"
        })
        #expect(sayAllType["UTTypeDescription"] as? String == "SayAll Button Profile")
        let tags = try #require(sayAllType["UTTypeTagSpecification"] as? [String: Any])
        #expect((tags["public.filename-extension"] as? [String]) == ["sayall"])
    }
}
