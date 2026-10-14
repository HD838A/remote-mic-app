import Foundation
import Testing

@testable import RemoteMic

struct VoiceTargetActivityMonitorTests {
    private func snapshot(
        focus: String = "1:10",
        text: String = "原文",
        selection: NSRange = NSRange(location: 2, length: 0)
    ) -> TranscriptCaptureSnapshot {
        TranscriptCaptureSnapshot(
            focusIdentity: focus,
            applicationName: "编辑器",
            bundleIdentifier: "com.example.editor",
            text: text,
            selection: selection,
            isSafeEditableDestination: true
        )
    }

    @Test
    func selectedTextDeletionIsDetected() {
        let before = snapshot(
            text: "你好世界",
            selection: NSRange(location: 2, length: 2)
        )
        let after = snapshot(
            text: "你好",
            selection: NSRange(location: 2, length: 0)
        )

        #expect(VoiceTargetActivityMonitor.isSelectedTextDeletion(from: before, to: after))
    }

    @Test
    func speechTextInsertionDoesNotInterruptTheSession() {
        let before = snapshot(text: "原文", selection: NSRange(location: 2, length: 0))
        let after = snapshot(text: "原文新增", selection: NSRange(location: 4, length: 0))

        #expect(!VoiceTargetActivityMonitor.isSelectedTextDeletion(from: before, to: after))
    }

    @Test
    func monitorReportsFocusChangeOnce() {
        var current = snapshot()
        var scheduled: (() -> Void)?
        var interruptions: [VoiceTargetActivityInterruption] = []
        let monitor = VoiceTargetActivityMonitor(
            schedule: { _, operation in
                scheduled = operation
                return VoiceFnTapScheduledTask {}
            },
            snapshot: { current },
            onInterruption: { interruptions.append($0) },
            log: { _ in }
        )

        monitor.start()
        current = snapshot(focus: "1:11")
        scheduled?()
        scheduled?()

        #expect(interruptions == [.targetChanged])
    }
}
