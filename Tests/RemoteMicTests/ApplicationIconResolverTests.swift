import Foundation
import Testing
@testable import RemoteMic

@Suite("Application icon resolver")
struct ApplicationIconResolverTests {
    private func profile(
        path: String,
        bundleIdentifier: String = "com.example.application"
    ) -> CustomApplicationProfile {
        CustomApplicationProfile(
            displayName: "示例 App",
            bundleIdentifier: bundleIdentifier,
            applicationPath: path
        )
    }

    @Test func emptyPathResolvesTheInstalledApplication() {
        var requestedBundleIdentifiers: [String] = []

        let path = ApplicationIconResolver.iconPath(
            for: profile(path: "", bundleIdentifier: "com.example.installed"),
            fileExists: { _ in false },
            resolveBundle: { bundleIdentifier in
                requestedBundleIdentifiers.append(bundleIdentifier)
                return URL(fileURLWithPath: "/Applications/Resolved.app")
            }
        )

        #expect(path == "/Applications/Resolved.app")
        #expect(requestedBundleIdentifiers == ["com.example.installed"])
    }

    @Test func missingSavedPathResolvesTheInstalledApplication() {
        var requestedBundleIdentifiers: [String] = []

        let path = ApplicationIconResolver.iconPath(
            for: profile(path: "/Applications/Missing.app"),
            fileExists: { _ in false },
            resolveBundle: { bundleIdentifier in
                requestedBundleIdentifiers.append(bundleIdentifier)
                return URL(fileURLWithPath: "/Applications/Resolved.app")
            }
        )

        #expect(path == "/Applications/Resolved.app")
        #expect(requestedBundleIdentifiers == ["com.example.application"])
    }

    @Test func existingSavedPathSkipsBundleIdentifierLookup() {
        var requestedBundleIdentifiers: [String] = []

        let path = ApplicationIconResolver.iconPath(
            for: profile(path: "/Applications/Saved.app"),
            fileExists: { $0 == "/Applications/Saved.app" },
            resolveBundle: { bundleIdentifier in
                requestedBundleIdentifiers.append(bundleIdentifier)
                return URL(fileURLWithPath: "/Applications/Resolved.app")
            }
        )

        #expect(path == "/Applications/Saved.app")
        #expect(requestedBundleIdentifiers.isEmpty)
    }

    @Test func unresolvedBundleKeepsTheSavedPath() {
        let path = ApplicationIconResolver.iconPath(
            for: profile(path: "/Applications/Missing.app"),
            fileExists: { _ in false },
            resolveBundle: { _ in nil }
        )

        #expect(path == "/Applications/Missing.app")
    }
}
