import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Voice input destination readiness")
struct VoiceInputDestinationCoordinatorTests {
    @Test(arguments: [0.0, 0.2, 1.0, 3.0])
    func waitsForApplicationReadinessWithoutUsingAFixedDelay(_ latency: TimeInterval) {
        let harness = DestinationHarness()
        harness.coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )
        if latency == 0 {
            harness.snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.target")
        }

        var result: VoiceInputDestinationWaitResult?
        let disposition = harness.coordinator.waitUntilReady { result = $0 }
        if latency == 0 {
            guard case .immediate = disposition else {
                Issue.record("An already-ready destination must remain on the immediate path")
                return
            }
            #expect(result == nil)
        } else {
            guard case .waiting = disposition else {
                Issue.record("A delayed destination must wait")
                return
            }
            harness.scheduler.advance(by: latency)
            #expect(result == nil)
            harness.snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.target")
            harness.scheduler.advance(by: 0.05)
            #expect(result == .ready)
        }
        #expect(harness.states.contains(.ready))
    }

    @Test func timesOutWithoutDeclaringTheWrongDestinationReady() {
        let harness = DestinationHarness(maximumWait: 1)
        harness.coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )
        var result: VoiceInputDestinationWaitResult?
        _ = harness.coordinator.waitUntilReady { result = $0 }

        harness.scheduler.advance(by: 1)

        #expect(result == .cancelled(.timedOut))
        #expect(harness.states == [.waiting, .cancelled(.timedOut)])
    }

    @Test func aNewRequestSupersedesTheOldWaitingDestination() {
        let harness = DestinationHarness()
        harness.coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.first")
        )
        var firstResult: VoiceInputDestinationWaitResult?
        _ = harness.coordinator.waitUntilReady { firstResult = $0 }

        harness.coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.second")
        )

        #expect(firstResult == .cancelled(.superseded))
        #expect(harness.states == [.waiting, .cancelled(.superseded)])
    }

    @Test func switchingAwayAfterTheExpectedAppAppearsCancelsTheRequest() {
        let harness = DestinationHarness()
        harness.coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )
        var result: VoiceInputDestinationWaitResult?
        _ = harness.coordinator.waitUntilReady { result = $0 }
        harness.snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.target",
            role: "AXButton",
            editable: false
        )
        harness.scheduler.advance(by: 0.05)

        harness.snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.other")
        harness.scheduler.advance(by: 0.05)

        #expect(result == .cancelled(.targetChanged))
    }

    @Test func targetApplicationExitCancelsInsteadOfSendingToThePreviousApp() {
        let harness = DestinationHarness()
        harness.coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )
        var result: VoiceInputDestinationWaitResult?
        _ = harness.coordinator.waitUntilReady { result = $0 }
        harness.snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.target",
            role: "AXWindow",
            editable: false
        )
        harness.scheduler.advance(by: 0.05)

        harness.snapshot = voiceInputTestSnapshot(
            bundleIdentifier: nil,
            role: "",
            editable: false
        )
        harness.scheduler.advance(by: 0.05)

        #expect(result == .cancelled(.targetChanged))
    }

    @Test func anUnknownShortcutCanAdoptAChangedAppThenRequiresItToRemainFrontmost() {
        let harness = DestinationHarness()
        harness.coordinator.beginTargetSwitch(intent: .shortcut)
        harness.snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.shortcut-target",
            role: "AXWindow",
            editable: false
        )
        var result: VoiceInputDestinationWaitResult?
        _ = harness.coordinator.waitUntilReady { result = $0 }

        harness.snapshot = voiceInputTestSnapshot(bundleIdentifier: "com.example.shortcut-target")
        harness.scheduler.advance(by: 0.05)

        #expect(result == .ready)
    }

    @Test func anUnknownShortcutNeverReusesTheOldEditableFocus() {
        let harness = DestinationHarness()
        harness.snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.previous",
            focusIdentity: "old-field"
        )
        harness.coordinator.beginTargetSwitch(intent: .shortcut)
        var result: VoiceInputDestinationWaitResult?
        _ = harness.coordinator.waitUntilReady { result = $0 }
        harness.scheduler.advance(by: 0.5)
        #expect(result == nil)

        harness.snapshot = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.previous",
            focusIdentity: "new-field"
        )
        harness.scheduler.advance(by: 0.05)
        #expect(result == .ready)
    }

    @Test func safeEditableClassificationAllowsSearchAndCustomEditorsButRejectsSecrets() {
        #expect(voiceInputTestSnapshot().isSafeEditableDestination)
        #expect(!voiceInputTestSnapshot(role: "AXButton", editable: false).isSafeEditableDestination)
        #expect(voiceInputTestSnapshot(
            role: "AXGroup",
            editable: true,
            semanticText: "Sublime editor"
        ).isSafeEditableDestination)
        #expect(voiceInputTestSnapshot(semanticText: "Search").isSafeEditableDestination)
        #expect(voiceInputTestSnapshot(semanticText: "搜索").isSafeEditableDestination)
        #expect(!voiceInputTestSnapshot(subrole: "AXSecureTextField").isSafeEditableDestination)
        #expect(!voiceInputTestSnapshot(protectedContent: true).isSafeEditableDestination)
        #expect(!voiceInputTestSnapshot(semanticText: "Password").isSafeEditableDestination)
        #expect(!voiceInputTestSnapshot(semanticText: "API Token").isSafeEditableDestination)
        #expect(!voiceInputTestSnapshot(enabled: false).isSafeEditableDestination)
    }

    @Test func intentResolutionCoversPresetCustomRecordedAndShortcutPaths() {
        let shortcut = CustomKeyboardShortcut(
            keyCode: 49,
            modifierFlags: .command,
            keyLabel: "Space"
        )
        let profile = CustomApplicationProfile(
            displayName: "Example",
            bundleIdentifier: "com.example.custom",
            applicationPath: "/Applications/Example.app",
            focusStrategy: .recordedAccessibility
        )

        #expect(VoiceInputDestinationIntent.resolve(
            configured: ConfiguredButtonAction(action: .openCodex, shortcut: nil),
            applicationProfile: nil
        ) == .application(bundleIdentifier: PresetApplication.codex.bundleIdentifier))
        #expect(VoiceInputDestinationIntent.resolve(
            configured: ConfiguredButtonAction(
                action: .openCustomApplication,
                shortcut: nil,
                applicationProfileID: profile.id
            ),
            applicationProfile: profile
        ) == .application(bundleIdentifier: profile.bundleIdentifier))
        #expect(VoiceInputDestinationIntent.resolve(
            configured: ConfiguredButtonAction(action: .customShortcut, shortcut: shortcut),
            applicationProfile: nil
        ) == .shortcut)
        #expect(VoiceInputDestinationIntent.resolve(
            configured: ConfiguredButtonAction(action: .escape, shortcut: nil),
            applicationProfile: nil
        ) == nil)
    }

    @Test func noPendingTargetKeepsTheImmediateVoicePath() {
        let harness = DestinationHarness()
        var completionCalled = false
        let disposition = harness.coordinator.waitUntilReady { _ in completionCalled = true }

        guard case .immediate = disposition else {
            Issue.record("No pending target must not delay Fn")
            return
        }
        #expect(!completionCalled)
        #expect(harness.scheduler.pendingTaskCount == 0)
    }
}

private final class DestinationHarness {
    let scheduler = VoiceInputManualScheduler()
    var snapshot = voiceInputTestSnapshot(
        bundleIdentifier: "com.example.previous",
        role: "AXWindow",
        editable: false
    )
    var states: [VoiceInputDestinationState] = []
    lazy var coordinator = VoiceInputDestinationCoordinator(
        pollInterval: 0.05,
        maximumWait: maximumWait,
        schedule: scheduler.schedule,
        snapshot: { [unowned self] in snapshot },
        onStateChange: { [unowned self] in states.append($0) }
    )
    private let maximumWait: TimeInterval

    init(maximumWait: TimeInterval = 5) {
        self.maximumWait = maximumWait
    }
}

func voiceInputTestSnapshot(
    bundleIdentifier: String? = "com.example.target",
    role: String = "AXTextArea",
    subrole: String = "",
    enabled: Bool = true,
    editable: Bool = true,
    protectedContent: Bool = false,
    semanticText: String = "Message input",
    focusIdentity: String = "focused-element"
) -> VoiceInputDestinationSnapshot {
    VoiceInputDestinationSnapshot(
        bundleIdentifier: bundleIdentifier,
        role: role,
        subrole: subrole,
        enabled: enabled,
        editable: editable,
        protectedContent: protectedContent,
        semanticText: semanticText,
        focusIdentity: focusIdentity
    )
}

final class VoiceInputManualScheduler {
    private struct Entry {
        let id: Int
        let order: Int
        let deadline: TimeInterval
        let operation: () -> Void
    }

    private var currentTime: TimeInterval = 0
    private var nextID = 0
    private var entries: [Entry] = []
    private var cancelledIDs = Set<Int>()

    var pendingTaskCount: Int {
        entries.lazy.filter { !self.cancelledIDs.contains($0.id) }.count
    }

    lazy var schedule: VoiceFnTapSessionController.Scheduler = { [unowned self] delay, operation in
        nextID += 1
        let id = nextID
        entries.append(Entry(
            id: id,
            order: id,
            deadline: currentTime + delay,
            operation: operation
        ))
        return VoiceFnTapScheduledTask { [weak self] in
            self?.cancelledIDs.insert(id)
        }
    }

    func advance(by interval: TimeInterval) {
        let target = currentTime + interval
        while let next = entries
            .filter({ !cancelledIDs.contains($0.id) && $0.deadline <= target })
            .min(by: {
                $0.deadline == $1.deadline ? $0.order < $1.order : $0.deadline < $1.deadline
            })
        {
            entries.removeAll { $0.id == next.id }
            currentTime = next.deadline
            next.operation()
        }
        currentTime = target
    }
}
