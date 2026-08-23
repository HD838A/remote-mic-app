import CoreAudio
import Foundation
import Testing
@testable import RemoteMic

@Suite("Local karaoke mode")
struct KaraokeModeTests {
    @Test func karaokeActionIsUnboundByDefaultAndPersistsOnAnyGesture() throws {
        #expect(!AppSettings.defaultBindings.values.contains(.toggleLocalKaraoke))

        let suiteName = "KaraokeModeTests.bindings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        for button in RemoteButton.allCases {
            for trigger in ButtonTrigger.allCases {
                #expect(settings.configuredAction(for: button, trigger: trigger).action != .toggleLocalKaraoke)
            }
        }

        settings.setAction(.toggleLocalKaraoke, for: .menu, trigger: .doubleClick)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.configuredAction(for: .menu, trigger: .doubleClick).action == .toggleLocalKaraoke)
        #expect(restored.configuredAction(for: .menu, trigger: .singleClick).action == .contextMenu)
    }

    @Test func karaokeActionUsesTheStandardInternalActionPipeline() {
        #expect(ButtonAction.toggleLocalKaraoke.isAppInternal)
        #expect(!ButtonAction.toggleLocalKaraoke.allowsRepeat)
        #expect(ButtonAction.pickerActions(
            installedBundleIdentifiers: [],
            current: .escape,
            experimentalContinuousRecordingEnabled: false
        ).contains(.toggleLocalKaraoke))
    }

    @Test func localPlaybackPrefersThePhysicalSystemDefault() throws {
        let builtIn = AudioDeviceInfo(id: 1, uid: "built-in", name: "Mac Speakers")
        let headphones = AudioDeviceInfo(id: 2, uid: "headphones", name: "USB Headphones")
        let virtual = AudioDeviceInfo(id: 3, uid: "virtual", name: "MiRemoteV 2ch")

        let selected = LocalPlaybackOutputPolicy.preferredOutput(
            in: [builtIn, headphones, virtual],
            defaultOutputID: headphones.id,
            excludingUID: virtual.uid,
            builtInDeviceIDs: [builtIn.id],
            virtualDeviceIDs: [virtual.id]
        )
        #expect(selected == headphones)

        let fallback = LocalPlaybackOutputPolicy.preferredOutput(
            in: [builtIn, headphones, virtual],
            defaultOutputID: virtual.id,
            excludingUID: virtual.uid,
            builtInDeviceIDs: [builtIn.id],
            virtualDeviceIDs: [virtual.id]
        )
        #expect(fallback == builtIn)
    }

    @Test func localPlaybackNeverFallsBackToAVirtualDevice() {
        let selectedVirtual = AudioDeviceInfo(id: 1, uid: "selected", name: "MiRemoteV 2ch")
        let otherVirtual = AudioDeviceInfo(id: 2, uid: "other", name: "BlackHole 2ch")

        #expect(LocalPlaybackOutputPolicy.preferredOutput(
            in: [selectedVirtual, otherVirtual],
            defaultOutputID: otherVirtual.id,
            excludingUID: selectedVirtual.uid,
            builtInDeviceIDs: [],
            virtualDeviceIDs: [selectedVirtual.id, otherVirtual.id]
        ) == nil)
    }

    @Test func missingOffOnAndUsedThenOffStatesKeepRoutingIsolated() {
        let target = UUID()
        let other = UUID()

        #expect(!KaraokeRoutingPolicy.usesLocalPlayback(
            modeEnabled: false,
            targetDeviceIdentifier: nil,
            streamDeviceIdentifier: target
        ))
        #expect(!KaraokeRoutingPolicy.usesLocalPlayback(
            modeEnabled: false,
            targetDeviceIdentifier: target,
            streamDeviceIdentifier: target
        ))
        #expect(KaraokeRoutingPolicy.usesLocalPlayback(
            modeEnabled: true,
            targetDeviceIdentifier: target,
            streamDeviceIdentifier: target
        ))
        #expect(!KaraokeRoutingPolicy.usesLocalPlayback(
            modeEnabled: true,
            targetDeviceIdentifier: target,
            streamDeviceIdentifier: other
        ))
        #expect(!KaraokeRoutingPolicy.usesLocalPlayback(
            modeEnabled: false,
            targetDeviceIdentifier: target,
            streamDeviceIdentifier: target
        ))
    }

    @Test func productionRoutingKeepsTheFeatureOffByDefaultAndIsolatesVirtualAudio() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("var isKaraokeModeEnabled = false"))
        #expect(source.contains("karaokeAudioOutput.enqueue(samples: samples)"))
        #expect(source.contains("handledByFnTapMode = voiceFnTapSession.receive(samples)"))
        #expect(source.contains("enqueued = handledByFnTapMode || audioOutput.enqueue(samples: samples)"))
        #expect(source.contains("case .toggleLocalKaraoke:"))
        #expect(source.contains("trigger: \"button_mapping\""))
        #expect(!source.contains("voice_double_click"))
        #expect(!source.contains("KaraokeVoiceDoubleClickRecognizer"))
        #expect(source.contains("if event.isSuspending, isKaraokeModeEnabled"))
        #expect(source.contains("karaokeHostAudioCapability = .manualOnly"))
        #expect(!source.contains("settings.isKaraokeModeEnabled"))
    }
}
