import Foundation
import Testing
@testable import RemoteMic

struct G9N9NVoiceSessionTests {
    private let caps = Data([0x0B, 1, 0, 2, 3, 0, 247])
    private func session() -> G9N9NVoiceSession {
        let session = G9N9NVoiceSession()
        #expect(session.acceptCapabilities(caps))
        return session
    }

    @Test func identityRequiresBothDISFields() {
        #expect(G9N9NVoiceSession.matches(model: "hid_mouse", manufacturer: "zhuhai_jieli"))
        #expect(!G9N9NVoiceSession.matches(model: "hid_mouse", manufacturer: "Google"))
        #expect(!G9N9NVoiceSession.matches(model: nil, manufacturer: "zhuhai_jieli"))
        #expect(!G9N9NVoiceSession.matches(model: "RC003", manufacturer: "zhuhai_jieli"))
    }

    @Test func invalidAndUnsupportedCapabilitiesStayUnavailable() {
        let s = G9N9NVoiceSession()
        #expect(!s.acceptCapabilities(Data([0x0B, 1, 0, 1, 3, 0, 247])))
        #expect(!s.acceptCapabilities(Data([0x0B, 1, 0, 2, 3, 0xFF, 0xFF])))
        #expect(!s.acceptCapabilities(Data([0x0B])))
        #expect(s.capabilities == nil)
    }

    @Test func startIsImmediateAndDuplicateStartDoesNotResetDecoder() {
        let s = session()
        var starts = 0
        var writes: [Data] = []
        var samples = [Int16]()
        s.onStart = { starts += 1 }
        s.onWrite = { writes.append($0) }
        s.onSamples = { pcm, _ in samples += pcm }
        s.control(Data([8]), now: 0)
        #expect(starts == 1)
        #expect(writes == [Data([0x0C, 0])])
        s.audio(Data(repeating: 0x12, count: 247), now: 0.01)
        s.control(Data([4, 0, 2, 9]), now: 0.02)
        s.audio(Data(repeating: 0x34, count: 247), now: 0.03)
        let decoder = IMAADPCMDecoder()
        let expected = PCMPostprocessor.process(decoder.decode(Data(repeating: 0x12, count: 247)), gainDB: 0)
            + PCMPostprocessor.process(decoder.decode(Data(repeating: 0x34, count: 247)), gainDB: 0)
        #expect(starts == 1)
        #expect(samples == expected)
    }

    @Test func fragmented247ByteFramesAndTailAreDeliveredBeforeStop() {
        let s = session()
        var events: [String] = []
        var sampleCount = 0
        s.onSamples = { pcm, _ in sampleCount += pcm.count; events.append("pcm") }
        s.onStop = { reason in #expect(reason.isNormal); events.append("stop") }
        s.control(Data([8]), now: 0)
        s.audio(Data(repeating: 0, count: 100), now: 0.01)
        s.audio(Data(repeating: 0, count: 147), now: 0.02)
        #expect(sampleCount == 494)
        s.control(Data([0]), now: 0.03)
        s.audio(Data(repeating: 0, count: 24), now: 0.04)
        #expect(events == ["pcm"])
        s.drain(now: 0.16)
        #expect(sampleCount == 542)
        #expect(events == ["pcm", "pcm", "stop"])
        s.audio(Data(repeating: 0, count: 247), now: 0.17)
        #expect(sampleCount == 542)
        #expect(!s.active)
    }

    @Test func hostCancellationRejectsLateAudioAndStartUntilFreshRequest() {
        let s = session()
        var starts = 0
        var stops = 0
        var pcmCount = 0
        s.onStart = { starts += 1 }
        s.onStop = { reason in #expect(!reason.isNormal); stops += 1 }
        s.onSamples = { pcm, _ in pcmCount += pcm.count }
        s.control(Data([8]), now: 0)
        s.cancel(reason: "host_stop", now: 0.1)
        s.control(Data([4, 0, 2, 1]), now: 0.11)
        s.audio(Data(repeating: 0, count: 247), now: 0.12)
        #expect(starts == 1 && stops == 1 && pcmCount == 0)
        s.control(Data([8]), now: 0.2)
        s.audio(Data(repeating: 0, count: 247), now: 0.21)
        #expect(starts == 2 && pcmCount == 494)
    }

    @Test func longSessionExtendUsesCurrentSessionID() {
        let s = session()
        var writes: [Data] = []
        s.onWrite = { writes.append($0) }
        s.control(Data([8]), now: 0)
        s.control(Data([4, 0, 2, 7]), now: 0.01)
        s.extend()
        #expect(writes.last == Data([0x0E, 7]))
        s.control(Data([0]), now: 51)
        let count = writes.count
        s.extend()
        #expect(writes.count == count)
    }

    @Test func syncIsAppliedToNextPCMAndInvalidSyncIsIgnored() {
        let s = session()
        var first: Int16?
        s.onSamples = { pcm, _ in first = pcm.first }
        s.control(Data([8]), now: 0)
        s.control(Data([0x0A, 0, 0, 0, 0x03, 0xE8, 0]), now: 0.01)
        s.control(Data([0x0A, 0, 0, 0, 0, 0, 255]), now: 0.02)
        s.audio(Data(repeating: 0, count: 247), now: 0.03)
        #expect(first == 1000)
    }

    @Test func reconnectAndRapidSessionsUseNewGenerations() {
        let s = session()
        var generations: [Int] = []
        s.onSamples = { _, generation in generations.append(generation) }
        s.control(Data([8]), now: 0)
        s.audio(Data(repeating: 0, count: 247), now: 0.01)
        s.control(Data([0]), now: 0.02)
        s.control(Data([8]), now: 0.03)
        s.audio(Data(repeating: 0, count: 247), now: 0.04)
        s.reset(now: 0.05)
        s.audio(Data(repeating: 0, count: 247), now: 0.06)
        #expect(s.acceptCapabilities(caps))
        s.control(Data([8]), now: 0.07)
        s.audio(Data(repeating: 0, count: 247), now: 0.08)
        #expect(generations == [1, 2, 3])
    }

    @Test func defaultKeysDoNotGuessBrandedButtons() {
        #expect(G9N9NHIDMonitor.control(page: 7, usage: 0x28) == .select)
        #expect(G9N9NHIDMonitor.control(page: 7, usage: 0x29) == .back)
        #expect(G9N9NHIDMonitor.control(page: 12, usage: 0x224) == .back)
        #expect(G9N9NHIDMonitor.control(page: 12, usage: 0xFFFF) == nil)
        #expect(G9N9NHIDMonitor.control(page: 1, usage: 0x30) == nil)
    }
    @Test @MainActor func g9ProfilesKeepTheirIdentityAndSavedMappings() throws {
        let name = "G9N9NTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let originalID = settings.registerChromecastRemote()
        let g9ID = settings.registerChromecastRemote(model: .googleTVRemoteG9N9N)
        #expect(originalID != g9ID)
        let profile = try #require(settings.remoteDeviceProfiles.first { $0.id == g9ID })
        #expect(profile.model == .googleTVRemoteG9N9N)
        #expect(profile.mappings.buttonShortcuts[RemoteButton.ok.rawValue]?.keyCode == 36)
        #expect(profile.mappings.buttonShortcuts[RemoteButton.back.rawValue]?.keyCode == 53)
        #expect(settings.registerChromecastRemote(model: .googleTVRemoteG9N9N) == g9ID)
        #expect(!XiaomiRemoteModel.googleTVRemoteG9N9N.supportsToggleVoiceRecording)
    }

    @Test func g9OnboardingIsVisibleAndHoldOnlyWhileGoogleStaysHidden() {
        let visible = OnboardingControlSourceVisibilityPolicy.visibleSources(OnboardingControlSource.allCases)
        #expect(visible.contains(.g9n9nRemote))
        #expect(!visible.contains(.chromecastRemote))
        #expect(OnboardingControlSource.g9n9nRemote.supportedGestureModes == [.hold])
        #expect(OnboardingControlSource.g9n9nRemote.legacyControlMethod == .physicalRemote)
        #expect(OnboardingControlValidationPolicy.suppressConfiguredActions(at: .controls, source: .g9n9nRemote))
        #expect(OnboardingRemotePhotoKind.resolve(source: .g9n9nRemote, selectedModel: .googleTVRemoteG9N9N) == .placeholder)
    }

}
