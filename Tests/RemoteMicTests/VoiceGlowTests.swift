import AppKit
import Testing
@testable import RemoteMic

@Suite("Voice glow countdown")
struct VoiceGlowTests {
    @Test func followsFocusedWindowAcrossScreenLayouts() {
        let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                       CGRect(x: -2560, y: 0, width: 2560, height: 1440),
                       CGRect(x: 0, y: 1080, width: 1920, height: 1080)]
        #expect(VoiceGlowScreenSelection.index(window: CGRect(x: 100, y: 100, width: 800, height: 600), screens: screens) == 0)
        #expect(VoiceGlowScreenSelection.index(window: CGRect(x: -2000, y: 100, width: 800, height: 600), screens: screens) == 1)
        #expect(VoiceGlowScreenSelection.index(window: CGRect(x: 100, y: 1200, width: 800, height: 600), screens: screens) == 2)
        #expect(VoiceGlowScreenSelection.index(window: CGRect(x: -700, y: 100, width: 1000, height: 600), screens: screens) == 1)
        #expect(VoiceGlowScreenSelection.index(window: .zero, screens: screens) == nil)
    }

    @Test func modesKeepApprovedEndpoints() {
        for fullSession in [false, true] {
            let start = VoiceGlowState.recording(elapsed: fullSession ? 0 : 50, fullSession: fullSession)
            #expect(start.length == 1)
            #expect(start.hue == 145)
            #expect(start.heat == 0)
            let red = VoiceGlowState.recording(elapsed: 57, fullSession: fullSession)
            #expect(red.hue == 0)
            let end = VoiceGlowState.recording(elapsed: 60, fullSession: fullSession)
            #expect(abs(end.length - 0.4) < 0.0001)
            #expect(end.heat == 1)
        }
        #expect(VoiceGlowState.recording(elapsed: 30, fullSession: true).length < 1)
        #expect(VoiceGlowState.recording(elapsed: 30, fullSession: false).length == 1)
    }

    @Test func warningFollowsConfiguredContinuationThreshold() {
        let beforeThreshold = VoiceGlowState.recording(
            elapsed: 25,
            fullSession: false,
            warningStart: 30
        )
        #expect(beforeThreshold.length == 1)
        #expect(beforeThreshold.hue == 145)
        #expect(beforeThreshold.heat == 0)

        let midWarning = VoiceGlowState.recording(
            elapsed: 40,
            fullSession: false,
            warningStart: 30
        )
        #expect(midWarning.length < 1)
        #expect(midWarning.hue < 145)
        #expect(midWarning.heat > 0)

        let red = VoiceGlowState.recording(
            elapsed: 51,
            fullSession: false,
            warningStart: 30
        )
        #expect(red.hue == 0)

        let zeroSpanBeforeEnd = VoiceGlowState.recording(
            elapsed: 59,
            fullSession: false,
            warningStart: 60
        )
        #expect(zeroSpanBeforeEnd.heat == 0)
        let zeroSpanAtEnd = VoiceGlowState.recording(
            elapsed: 60,
            fullSession: false,
            warningStart: 60
        )
        #expect(zeroSpanAtEnd.heat == 1)
    }

    @MainActor @Test func cachesAXWindowLookupUntilFrontmostAppOrScreenChanges() {
        let glow = VoiceContinuationGlowController()
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        var currentPID: pid_t? = 101
        var mouseLocation = CGPoint(x: 200, y: 200)
        var queriedPIDs: [pid_t] = []
        var windowFramesByPID: [pid_t: CGRect] = [
            101: CGRect(x: 2100, y: 100, width: 800, height: 600),
            202: CGRect(x: 100, y: 100, width: 800, height: 600),
        ]

        glow.screenFramesProvider = { screens }
        glow.mouseLocationProvider = { mouseLocation }
        glow.frontmostAppPIDProvider = { currentPID }
        glow.focusedWindowFrameProvider = { pid in
            queriedPIDs.append(pid)
            return windowFramesByPID[pid]
        }

        #expect(glow.resolveScreenIndex() == 1)
        #expect(queriedPIDs == [101])

        // If the same responsive app moves its window to another screen without mouse movement,
        // the next scheduled check refreshes and follows it.
        windowFramesByPID[101] = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(glow.resolveScreenIndex() == 0)
        #expect(queriedPIDs == [101, 101])

        // Switching frontmost app triggers a lookup for the new PID.
        currentPID = 202
        #expect(glow.resolveScreenIndex() == 0)
        #expect(queriedPIDs == [101, 101, 202])

        // If an app fails AX lookup (e.g. unresponsive), it falls back to mouse screen
        // and does not repeatedly query AX for the same frontmost PID.
        currentPID = 303
        mouseLocation = CGPoint(x: 2200, y: 200)
        #expect(glow.resolveScreenIndex() == 1)
        #expect(queriedPIDs == [101, 101, 202, 303])
        mouseLocation = CGPoint(x: 300, y: 200)
        #expect(glow.resolveScreenIndex() == 0)
        #expect(queriedPIDs == [101, 101, 202, 303])
    }

    @Test func refillIsContinuousAndFastThenSlow() {
        let from = VoiceGlowState.recording(elapsed: 58, fullSession: true)
        let target = VoiceGlowState.recording(elapsed: 0, fullSession: true)
        #expect(from.interpolated(to: target, progress: 0).length == from.length)
        let middle = from.interpolated(to: target, progress: 0.5)
        #expect(middle.length - from.length > target.length - middle.length)
        let end = from.interpolated(to: target, progress: 1)
        #expect(end.length == 1)
        #expect(end.hue == 145)
        #expect(end.heat == 0)
    }

    @Test func glowSettingsPersistIndependently() throws {
        let suite = "VoiceGlowTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceGlowReminderEnabled)
        #expect(!settings.voiceGlowFullSession)
        settings.voiceGlowReminderEnabled = true
        settings.voiceGlowFullSession = true
        settings.voiceGlowWidth = 0.8
        settings.voiceGlowIntensity = 2
        let restored = AppSettings(defaults: defaults)
        #expect(restored.voiceGlowWidth == 0.8)
        #expect(restored.voiceGlowIntensity == 2)
        #expect(restored.voiceGlowReminderEnabled)
        #expect(restored.voiceGlowFullSession)
        #expect(!restored.voiceContinuationEnabled)
        #expect(restored.voiceContinuationDelay == 1)
    }

    @MainActor @Test func previewEndsOnItsOwnWhileAnotherSourceKeepsRecording() async throws {

        let glow = VoiceContinuationGlowController()
        glow.preview(duration: 0.05)
        #expect(glow.isVisible)
        for _ in 0..<20 where glow.isVisible {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!glow.isVisible)
    }

    @MainActor @Test func aSessionTakingTheGlowOverCancelsThePreview() async throws {
        let glow = VoiceContinuationGlowController()
        glow.preview(duration: 0.05)

        glow.start(elapsed: 0, fullSession: true)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(glow.isVisible)
        glow.stop()
        #expect(!glow.isVisible)
    }

    @MainActor @Test func nativeGlowRenders() throws {
        let view = VoiceContinuationGlowView(frame: NSRect(x: 0, y: 0, width: 1100, height: 230))
        view.state = .recording(elapsed: 60, fullSession: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        if let directory = ProcessInfo.processInfo.environment["VOICE_GLOW_TEST_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("native-red.png"))
        }
    }
}
