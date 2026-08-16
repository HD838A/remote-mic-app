import Foundation
import Testing
@testable import RemoteMic

@Suite("Startup environment snapshot")
struct AppEnvironmentSnapshotTests {
    @Test func recordsOnlyNonPersonalEnvironmentAndSettings() {
        let snapshot = AppEnvironmentSnapshot(
            operatingSystemVersion: "macOS 26.0 (25A123)",
            macModel: "Mac16,7",
            appVersion: "1.8.30",
            appBuild: "1830",
            systemLanguage: "zh-Hans-CN",
            appLanguage: "system",
            microphoneGainDB: 10,
            microphoneOutputConfigured: true,
            microphoneOutputKind: "sayall_virtual",
            customMappingEnabled: true,
            voiceFnTapModeEnabled: false,
            showDockIcon: true,
            openMainWindowAtLaunch: false,
            checksForPreReleaseUpdates: true,
            continuousRecordingEnabled: false,
            onboardingComplete: true,
            onboardingVoiceTool: "typeless"
        )

        let message = snapshot.logMessage
        #expect(message.contains("os=\"macOS 26.0 (25A123)\""))
        #expect(message.contains("mac_model=\"Mac16,7\""))
        #expect(message.contains("app_version=\"1.8.30\""))
        #expect(message.contains("microphone_gain_db=10.0"))
        #expect(message.contains("microphone_output_configured=true"))
        #expect(message.contains("microphone_output_kind=\"sayall_virtual\""))
        #expect(message.contains("custom_mapping_enabled=true"))
        #expect(!message.contains("selectedAudioDeviceUID"))
        #expect(!message.contains("buttonBindings"))
        #expect(!message.contains("customApplicationProfiles"))
    }

    @Test func appLaunchWritesEnvironmentSnapshotOnceBeforeRuntimeGate() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"))
        let launch = try #require(source.range(of: "func applicationDidFinishLaunching"))
        let terminate = try #require(source.range(
            of: "func applicationWillTerminate",
            range: launch.upperBound..<source.endIndex
        ))
        let body = String(source[launch.lowerBound..<terminate.lowerBound])
        let snapshot = try #require(body.range(
            of: "AppEnvironmentSnapshot.current(settings: model.settings).logMessage"
        ))
        let runtimeGate = try #require(body.range(of: "if OnboardingLaunchPolicy.shouldStartRuntime"))

        #expect(snapshot.lowerBound < runtimeGate.lowerBound)
        #expect(source.components(
            separatedBy: "AppEnvironmentSnapshot.current(settings: model.settings).logMessage"
        ).count == 2)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
