import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Hold execution")
struct HoldExecutionTests {
    private func snapshot(
        mode: RemoteButtonHoldMode,
        single: ButtonAction = .arrowRight,
        long: ButtonAction = .disabled
    ) -> RemoteButtonInteractionSnapshot {
        .init(
            settings: .init(),
            mode: mode,
            single: .init(action: single, shortcut: nil),
            double: .disabled,
            long: .init(action: long, shortcut: nil)
        )
    }

    // MARK: - 配置

    @Test func settingsRoundTripAndLegacyDecoding() throws {
        var settings = RemoteButtonInteractionSettings()
        settings.setHoldExecution(true, for: .up)
        #expect(settings.holdExecution(for: .up))
        #expect(settings.holdExecutions == ["up"])
        let decoded = try JSONDecoder().decode(
            RemoteButtonInteractionSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
        #expect(decoded.holdExecution(for: .up))

        // 旧配置没有该字段：解码为 nil，所有按键保持既有重复行为。
        let legacy = try JSONDecoder().decode(
            RemoteButtonInteractionSettings.self,
            from: Data(#"{"doubleClickMilliseconds":300,"longPressMilliseconds":550}"#.utf8)
        )
        #expect(legacy.holdExecutions == nil)
        #expect(!legacy.holdExecution(for: .up))
    }

    @Test func clearingTheLastEntryRemovesTheField() {
        var settings = RemoteButtonInteractionSettings()
        settings.setHoldExecution(true, for: .up)
        settings.setHoldExecution(false, for: .up)
        #expect(settings.holdExecutions == nil)
        #expect(settings.isWellFormed)
    }

    @Test func settingsRejectUnknownButtons() {
        #expect(RemoteButtonInteractionSettings(holdExecutions: ["up"]).isWellFormed)
        #expect(!RemoteButtonInteractionSettings(holdExecutions: ["nonexistent"]).isWellFormed)
    }

    // MARK: - 可用性

    @Test func onlyArrowActionsCanBeHeld() {
        #expect(ConfiguredButtonAction(action: .arrowRight, shortcut: nil).holdableKey ==
            HoldableKey(keyCode: 124, flags: []))
        #expect(ConfiguredButtonAction(action: .arrowUp, shortcut: nil).holdableKey?.keyCode == 126)
        #expect(ConfiguredButtonAction(action: .arrowDown, shortcut: nil).holdableKey?.keyCode == 125)
        #expect(ConfiguredButtonAction(action: .arrowLeft, shortcut: nil).holdableKey?.keyCode == 123)
        // 录制下来的方向键同样可以按住；删除键和其他动作不进入按下状态。
        #expect(ConfiguredButtonAction(
            action: .customShortcut,
            shortcut: .init(keyCode: 123, modifierFlags: [], keyLabel: "←")
        ).holdableKey != nil)
        #expect(ConfiguredButtonAction(
            action: .customShortcut,
            shortcut: .init(keyCode: 51, modifierFlags: [], keyLabel: "⌫")
        ).holdableKey == nil)
        #expect(ConfiguredButtonAction(action: .deleteBackward, shortcut: nil).holdableKey == nil)
        #expect(ConfiguredButtonAction(action: .commandPaste, shortcut: nil).holdableKey == nil)
        #expect(ConfiguredButtonAction(action: .disabled, shortcut: nil).holdableKey == nil)
    }

    @Test func snapshotOnlyActivatesHoldForArrowTargets() {
        // 与重复方式无关：只要长按动作是方向键，按住执行就可用。
        for mode in [RemoteButtonHoldMode.once, .repeatSingle, .repeatLong] {
            var holdable = snapshot(mode: mode, long: .arrowLeft)
            holdable.holdExecutionAction = holdable.long
            #expect(holdable.canHoldExecution)
            #expect(!holdable.isHoldExecutionActive)
            holdable.holdExecution = true
            #expect(holdable.isHoldExecutionActive)
        }

        // 没有可按住的动作时开关无效。
        var missing = snapshot(mode: .once)
        missing.holdExecution = true
        #expect(!missing.canHoldExecution)
        #expect(!missing.isHoldExecutionActive)

        // 长按动作不是方向键时不进入按住状态，仍按原动作执行。
        var nonArrow = snapshot(mode: .repeatSingle, long: .returnKey)
        nonArrow.holdExecutionAction = nonArrow.long
        nonArrow.holdExecution = true
        #expect(!nonArrow.canHoldExecution)
        #expect(!nonArrow.isHoldExecutionActive)
    }

    // MARK: - 注入

    @Test func sessionPostsPressRepeatsAndRelease() async throws {
        let log = HoldEventLog()
        let session = KeyboardHoldExecution(
            poster: log.post,
            logger: { _ in },
            initialRepeatDelayMilliseconds: 20,
            repeatIntervalMilliseconds: 10
        )
        let key = HoldableKey(keyCode: 124, flags: [])
        #expect(session.begin(.init(key)))
        #expect(session.isHolding)
        try await Task.sleep(nanoseconds: 90_000_000)
        session.end(reason: "released")
        #expect(!session.isHolding)

        let events = log.events
        #expect(events.first == .press(124))
        #expect(events.last == .release(124))
        #expect(events.contains(.repeatPress(124)))
    }

    @Test func failedPressLeavesNoSession() {
        let log = HoldEventLog()
        log.rejectPress = true
        let session = KeyboardHoldExecution(poster: log.post, logger: { _ in })
        #expect(!session.begin(.init(HoldableKey(keyCode: 123, flags: []))))
        #expect(!session.isHolding)
        #expect(log.events.isEmpty)
    }

    @Test func replacingSessionReleasesThePreviousKey() {
        let log = HoldEventLog()
        let session = KeyboardHoldExecution(poster: log.post, logger: { _ in })
        #expect(session.begin(.init(HoldableKey(keyCode: 124, flags: []))))
        #expect(session.begin(.init(HoldableKey(keyCode: 125, flags: []))))
        // 前一次按下必须先被抬起，系统里不能同时留下两个按住的键。
        #expect(log.events == [.press(124), .release(124), .press(125)])
        session.end(reason: "released")
        #expect(log.events.last == .release(125))
    }

    @Test func maximumDurationReleasesTheKey() async throws {
        let log = HoldEventLog()
        let startedAt = Date()
        var current = startedAt
        let session = KeyboardHoldExecution(
            poster: log.post,
            logger: { _ in },
            now: { current },
            initialRepeatDelayMilliseconds: 10,
            repeatIntervalMilliseconds: 10
        )
        #expect(session.begin(.init(HoldableKey(keyCode: 126, flags: []))))
        // 超过最长按住时长后，即使没有松开事件也必须自动抬起。
        current = startedAt.addingTimeInterval(120)
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(!session.isHolding)
        #expect(log.events.last == .release(126))
    }
}

/// 记录按住注入发出的系统事件序列。
private final class HoldEventLog {
    enum Event: Equatable {
        case press(CGKeyCode)
        case repeatPress(CGKeyCode)
        case release(CGKeyCode)
    }

    private let lock = NSLock()
    private var storage: [Event] = []
    var rejectPress = false

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func post(
        _ keyCode: CGKeyCode,
        _ isDown: Bool,
        _ flags: CGEventFlags,
        _ autorepeat: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isDown, !autorepeat, rejectPress { return false }
        if isDown {
            storage.append(autorepeat ? .repeatPress(keyCode) : .press(keyCode))
        } else {
            storage.append(.release(keyCode))
        }
        return true
    }
}
