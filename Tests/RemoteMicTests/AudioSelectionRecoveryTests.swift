import Foundation
import Testing
@testable import RemoteMic

@Suite("Audio selection recovery")
struct AudioSelectionRecoveryTests {
    private let miRemote = AudioDeviceInfo(id: 1, uid: "MiRemoteV2ch_UID", name: "MiRemoteV 2ch")
    private let blackHole = AudioDeviceInfo(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")

    @Test func currentSelectionAlwaysWins() {
        let decision = VirtualAudioSelectionRecoveryPolicy.resolve(
            selectedUID: "custom-device",
            rememberedUID: miRemote.uid,
            availableDevices: [miRemote],
            hasHistoricalConfiguration: true
        )

        #expect(decision.uid == "custom-device")
        #expect(decision.source == .currentSelection)
        #expect(decision.kind == .unavailable)
    }

    @Test func rememberedMiRemoteSelectionIsRestoredWhenAvailable() {
        let decision = VirtualAudioSelectionRecoveryPolicy.resolve(
            selectedUID: "",
            rememberedUID: miRemote.uid,
            availableDevices: [miRemote],
            hasHistoricalConfiguration: true
        )

        #expect(decision.uid == miRemote.uid)
        #expect(decision.source == .rememberedSelection)
        #expect(decision.kind == .miRemoteV2ch)
    }

    @Test func uniqueSupportedDeviceIsRestoredAfterHistoricalConfiguration() {
        let decision = VirtualAudioSelectionRecoveryPolicy.resolve(
            selectedUID: "",
            rememberedUID: "",
            availableDevices: [miRemote],
            hasHistoricalConfiguration: true
        )

        #expect(decision.uid == miRemote.uid)
        #expect(decision.source == .uniqueHistoricalCandidate)
        #expect(decision.supportedCandidateCount == 1)
    }

    @Test func multipleSupportedDevicesAreNeverGuessed() {
        let decision = VirtualAudioSelectionRecoveryPolicy.resolve(
            selectedUID: "",
            rememberedUID: "",
            availableDevices: [miRemote, blackHole],
            hasHistoricalConfiguration: true
        )

        #expect(decision.uid == nil)
        #expect(decision.source == .none)
        #expect(decision.reason == .multipleSupportedCandidates)
    }

    @Test func noHistoricalConfigurationDoesNotAutoSelect() {
        let decision = VirtualAudioSelectionRecoveryPolicy.resolve(
            selectedUID: "",
            rememberedUID: "",
            availableDevices: [miRemote],
            hasHistoricalConfiguration: false
        )

        #expect(decision.uid == nil)
        #expect(decision.reason == .noHistory)
    }

    @Test func unavailableRememberedDeviceDoesNotSwitchToAnotherCandidate() {
        let decision = VirtualAudioSelectionRecoveryPolicy.resolve(
            selectedUID: "",
            rememberedUID: "missing-device",
            availableDevices: [miRemote],
            hasHistoricalConfiguration: true
        )

        #expect(decision.uid == nil)
        #expect(decision.reason == .rememberedDeviceUnavailable)
    }

    @Test func rememberedAudioSelectionSurvivesRestartAndEmptyCurrentSelection() throws {
        let suiteName = "RemoteMicTests.AudioSelectionRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = AppSettings(defaults: defaults)
        firstLaunch.selectedAudioDeviceUID = miRemote.uid
        #expect(firstLaunch.lastKnownAudioDeviceUID == miRemote.uid)

        let restarted = AppSettings(defaults: defaults)
        #expect(restarted.selectedAudioDeviceUID == miRemote.uid)
        #expect(restarted.lastKnownAudioDeviceUID == miRemote.uid)

        restarted.selectedAudioDeviceUID = ""
        #expect(restarted.lastKnownAudioDeviceUID == miRemote.uid)

        let afterImport = AppSettings(defaults: defaults)
        #expect(afterImport.selectedAudioDeviceUID.isEmpty)
        #expect(afterImport.lastKnownAudioDeviceUID == miRemote.uid)
    }

    @Test func startupPathInvokesRecoveryAndLogsFailureBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("VirtualAudioSelectionRecoveryPolicy.resolve("))
        #expect(source.contains("AUDIO SELECTION RECOVERY phase=\\(phase)"))
        #expect(source.contains("AUDIO SELECTION RECOVERY phase=completed result=restored"))
        #expect(source.contains("AUDIO SELECTION RECOVERY phase=failed result=not_restored"))
    }
}
