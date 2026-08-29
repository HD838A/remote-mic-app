import Foundation
import Testing
@testable import RemoteMic

struct FeedbackLinkTests {
    @Test func feedbackUsesPublicMacGuestEntryWithRedactedRuntimeContext() throws {
        let diagnostics = AppLinks.FeedbackDiagnostics(
            appVersion: "1.9.18",
            appBuild: "143",
            macOSVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 6,
                patchVersion: 1
            ),
            architecture: .arm64,
            bluetoothPermission: .allowed,
            inputMonitoringPermission: true,
            accessibilityPermission: false,
            physicalRemoteConnected: true,
            phoneRemoteConnected: false,
            watchRemoteConnected: false,
            webRemoteConnected: true,
            audioDeviceSelected: true,
            audioDeviceAvailable: true,
            audioOutputReady: false,
            audioStreaming: false,
            buttonMappingEnabled: true,
            buttonPermissionReady: false,
            buttonObserved: true,
            logAvailable: true
        )
        let components = try #require(URLComponents(
            url: AppLinks.feedback(diagnostics: diagnostics),
            resolvingAgainstBaseURL: false
        ))

        #expect(components.scheme == "https")
        #expect(components.host == "my.sayall.app")
        #expect(components.path == "/api/guest-entry")
        #expect(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        }) == [
            "source": "mac",
            "context_version": "1",
            "app_version": "1.9.18",
            "app_build": "143",
            "macos_version": "15.6.1",
            "architecture": "arm64",
            "permission_bluetooth": "allowed",
            "permission_input_monitoring": "true",
            "permission_accessibility": "false",
            "physical_remote_connected": "true",
            "phone_remote_connected": "false",
            "watch_remote_connected": "false",
            "web_remote_connected": "true",
            "audio_device_selected": "true",
            "audio_device_available": "true",
            "audio_output_ready": "false",
            "audio_streaming": "false",
            "button_mapping_enabled": "true",
            "button_permission_ready": "false",
            "button_observed": "true",
            "log_available": "true",
        ])
    }

    @Test func feedbackContextHasNoFieldForSensitiveUserOrDeviceData() throws {
        let diagnostics = AppLinks.FeedbackDiagnostics(
            appVersion: "1.9.18 beta",
            appBuild: "143\ncandidate",
            macOSVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 6,
                patchVersion: 1
            ),
            architecture: .x86_64,
            bluetoothPermission: .notDetermined,
            inputMonitoringPermission: false,
            accessibilityPermission: false,
            physicalRemoteConnected: false,
            phoneRemoteConnected: false,
            watchRemoteConnected: false,
            webRemoteConnected: false,
            audioDeviceSelected: false,
            audioDeviceAvailable: false,
            audioOutputReady: false,
            audioStreaming: false,
            buttonMappingEnabled: false,
            buttonPermissionReady: false,
            buttonObserved: false,
            logAvailable: false
        )
        let url = AppLinks.feedback(diagnostics: diagnostics)
        let components = try #require(URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ))
        let queryNames = Set(try #require(components.queryItems).map(\.name))

        let forbiddenNames = [
            "account", "token", "code", "device_id", "device_name", "bluetooth_address",
            "ip", "path", "input_text", "transcript", "audio_data", "password", "otp",
        ]
        #expect(queryNames.isDisjoint(with: forbiddenNames))
        #expect(!url.absoluteString.contains("/Users/"))
        #expect(!url.absoluteString.contains("%20"))
        #expect(!url.absoluteString.contains("%0A"))
    }

    @Test func aboutPageOwnsFeedbackWithoutKeepingTheStatusMenuEntry() throws {
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RemoteMic/RemoteMicApp.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RemoteMic/SettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(!appSource.contains("#selector(openFeedback)"))
        #expect(!appSource.contains("@objc private func openFeedback()"))
        #expect(settingsSource.contains("Link(destination: feedbackURL)"))
        #expect(settingsSource.contains("AppLinks.feedback(diagnostics:"))
        #expect(settingsSource.contains("model.openLogFolder()"))
        #expect(settingsSource.contains("about.support.feedback_action"))
        #expect(settingsSource.contains("about.support.feedback_logs"))
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
