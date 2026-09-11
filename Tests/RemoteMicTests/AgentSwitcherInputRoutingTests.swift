import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Agent switcher input routing")
struct AgentSwitcherInputRoutingTests {
    @Test func duplicateOpeningPressIsConsumedAfterDownstreamOpensPicker() {
        let router = AgentSwitcherInputRouter()
        var pressCount = 0
        #expect(!router.consume(button: .menu, phase: .press, owner: "remote", isActive: false) {
            pressCount += 1
            return false
        })
        #expect(router.consume(button: .menu, phase: .press, owner: "remote", isActive: true) {
            pressCount += 1
            return true
        })
        #expect(pressCount == 1)
        #expect(router.consume(button: .menu, phase: .release, owner: "remote", isActive: true) {
            pressCount += 1
            return true
        })
        #expect(pressCount == 1)
        #expect(router.consume(button: .menu, phase: .press, owner: "remote", isActive: true) {
            pressCount += 1
            return true
        })
        #expect(pressCount == 2)
    }

    @Test func duplicatePressAndReleaseAfterClosingRemainConsumed() {
        let router = AgentSwitcherInputRouter()
        var pressCount = 0
        var active = true
        let handlePress = {
            guard active else { return false }
            pressCount += 1
            active = false
            return true
        }
        #expect(router.consume(button: .ok, phase: .press, owner: "remote", handlePress: handlePress))
        #expect(router.consume(button: .ok, phase: .press, owner: "remote", handlePress: handlePress))
        #expect(pressCount == 1)
        #expect(router.consume(button: .ok, phase: .release, owner: "remote", handlePress: handlePress))
        #expect(!router.consume(button: .ok, phase: .release, owner: "remote", handlePress: handlePress))
        #expect(!router.consume(button: .ok, phase: .press, owner: "remote", handlePress: handlePress))
    }

    @Test func ownerResetPreservesAnotherOwnersPendingRelease() {
        let router = AgentSwitcherInputRouter()
        #expect(router.consume(button: .left, phase: .press, owner: "first", handlePress: { true }))
        #expect(router.consume(button: .left, phase: .press, owner: "second", handlePress: { true }))
        router.reset(owner: "first")
        #expect(!router.consume(button: .left, phase: .release, owner: "first", handlePress: { true }))
        #expect(router.consume(button: .left, phase: .release, owner: "second", handlePress: { true }))
        #expect(!router.consume(button: .right, phase: .release, owner: "second", handlePress: { true }))
    }

    @Test(arguments: [RemoteButton.ok, .back, .menu])
    func HIDMenuOpensAndModalControlsNeverExecuteTheirBindings(_ closingButton: RemoteButton) throws {
        let fixture = try AgentRoutingFixture()
        defer { fixture.close() }
        fixture.tap(.menu)
        #expect(fixture.panel.activeOwner == fixture.owner)
        fixture.tap(.left)
        fixture.tap(.right)
        fixture.tap(closingButton)
        fixture.scheduler.advance(toMilliseconds: 2_000)

        #expect(fixture.panel.controls == [.left, .right, closingButton])
        #expect(fixture.panel.activeOwner == nil)
        #expect(fixture.panel.openCount == 1)
        #expect(fixture.actions.isEmpty)
        fixture.tap(.left)
        #expect(fixture.actions == [.arrowLeft])
    }

    @Test func HIDConfirmReleaseCannotTriggerConfiguredSecondaryGesture() throws {
        let fixture = try AgentRoutingFixture()
        defer { fixture.close() }
        fixture.settings.setAction(.volumeUp, for: .ok, trigger: .doubleClick)
        fixture.settings.setAction(.volumeDown, for: .ok, trigger: .longPress)
        fixture.tap(.menu)
        fixture.report([.ok])
        #expect(fixture.panel.activeOwner == nil)
        fixture.report([])
        fixture.scheduler.advance(toMilliseconds: 2_000)

        #expect(fixture.panel.controls == [.ok])
        #expect(fixture.actions.isEmpty)
        #expect(fixture.scheduler.pendingTaskCount == 0)
        fixture.tap(.ok)
        fixture.scheduler.advance(toMilliseconds: 2_400)
        #expect(fixture.actions == [.escape])
    }

    @Test func HIDHeldReportsNavigateOnceAndOpeningCancelsPriorRepeat() throws {
        let fixture = try AgentRoutingFixture()
        defer { fixture.close() }
        fixture.report([.left])
        #expect(fixture.actions == [.arrowLeft])
        #expect(fixture.scheduler.pendingTaskCount > 0)
        fixture.report([.left, .menu])
        fixture.scheduler.advance(toMilliseconds: 1_000)
        fixture.report([.left, .menu])
        #expect(fixture.panel.openCount == 1)
        #expect(fixture.actions == [.arrowLeft])
        fixture.report([])
        fixture.report([.right])
        fixture.report([.right])
        fixture.scheduler.advance(toMilliseconds: 2_000)
        fixture.report([.right])
        fixture.report([])

        #expect(fixture.panel.controls == [.right])
        #expect(fixture.actions == [.arrowLeft])
        #expect(fixture.scheduler.pendingTaskCount == 0)
    }

    @Test(arguments: [false, true])
    func HIDOpeningCancelsPendingDoubleClickAndLongPress(_ holdingOK: Bool) throws {
        let fixture = try AgentRoutingFixture()
        defer { fixture.close() }
        fixture.settings.setAction(.volumeUp, for: .ok, trigger: .doubleClick)
        fixture.settings.setAction(.volumeDown, for: .ok, trigger: .longPress)
        fixture.report([.ok])
        if !holdingOK { fixture.report([]) }
        #expect(fixture.scheduler.pendingTaskCount > 0)
        fixture.report(holdingOK ? [.ok, .menu] : [.menu])
        fixture.report([])
        fixture.scheduler.advance(toMilliseconds: 1_000)
        #expect(fixture.actions.isEmpty)
        #expect(fixture.panel.activeOwner == fixture.owner)
        #expect(fixture.scheduler.pendingTaskCount == 0)
    }

    @Test func HIDDisconnectCancelsOnlyTheOwningPickerAndReconnectStartsCleanly() throws {
        let panel = AgentRoutingPanel()
        let first = try AgentRoutingFixture(panel: panel)
        let second = try AgentRoutingFixture(panel: panel)
        defer { first.close(); second.close() }
        first.tap(.menu)
        first.report([.left])
        second.monitor.disconnectSimulatedDevice()
        #expect(panel.activeOwner == first.owner)
        first.monitor.disconnectSimulatedDevice()
        #expect(panel.activeOwner == nil)
        #expect(first.scheduler.pendingTaskCount == 0)

        first.monitor.connectSimulatedDevice(fingerprint: "reconnected", profileID: first.profileID)
        first.tap(.menu)
        first.tap(.left)
        #expect(panel.openCount == 2)
        #expect(panel.controls == [.left, .left])
        #expect(first.actions.isEmpty)
    }

    @Test func HIDPermissionFailureCancelsPickerAndRejectsFurtherActions() throws {
        let fixture = try AgentRoutingFixture()
        defer { fixture.close() }
        fixture.tap(.menu)
        fixture.permissionsGranted = false
        fixture.report([.left])
        #expect(fixture.panel.activeOwner == nil)
        #expect(fixture.panel.controls.isEmpty)
        #expect(fixture.actions.isEmpty)
        #expect(fixture.scheduler.pendingTaskCount == 0)
        fixture.permissionsGranted = true
        fixture.monitor.connectSimulatedDevice(fingerprint: "permission-restored", profileID: fixture.profileID)
        fixture.tap(.menu)
        fixture.tap(.ok)
        #expect(fixture.panel.openCount == 2)
        #expect(fixture.panel.controls == [.ok])
    }

    @Test func HIDPreparingPickerReleasesAnExistingCommandTabSession() throws {
        let fixture = try AgentRoutingFixture()
        defer { fixture.close() }
        fixture.settings.setAction(.appSwitcher, for: .tv)
        fixture.tap(.tv)
        #expect(fixture.postedKeys.first?.0 == KeyboardInjector.leftCommandKeyCode)
        #expect(fixture.postedKeys.first?.1 == true)
        fixture.tap(.menu)
        #expect(fixture.panel.activeOwner == fixture.owner)
        #expect(fixture.postedKeys.last?.0 == KeyboardInjector.leftCommandKeyCode)
        #expect(fixture.postedKeys.last?.1 == false)
        fixture.scheduler.advance(toMilliseconds: 20_000)
        #expect(fixture.actions.isEmpty)
    }
}

private final class AgentRoutingPanel {
    let router = AgentSwitcherInputRouter()
    var activeOwner: String?
    var openCount = 0
    var controls: [RemoteButton] = []

    func consume(button: RemoteButton, phase: RemoteButtonPhase, owner: String) -> Bool {
        router.consume(button: button, phase: phase, owner: owner, isActive: activeOwner == owner) {
            guard activeOwner == owner else { return false }
            guard [.left, .right, .ok, .back, .menu].contains(button) else { return false }
            controls.append(button)
            if [.ok, .back, .menu].contains(button) { activeOwner = nil }
            return true
        }
    }

    func reset(owner: String) {
        router.reset(owner: owner)
        if activeOwner == owner { activeOwner = nil }
    }
}

private final class AgentRoutingFixture {
    let suiteName: String
    let defaults: UserDefaults
    let settings: AppSettings
    let profileID: UUID
    let panel: AgentRoutingPanel
    let scheduler = AgentRoutingScheduler()
    var monitor: HIDRemoteMonitor!
    var permissionsGranted = true
    var actions: [ButtonAction] = []
    var postedKeys: [(CGKeyCode, Bool)] = []
    var owner: String { profileID.uuidString }

    init(panel: AgentRoutingPanel = AgentRoutingPanel()) throws {
        suiteName = "AgentSwitcherInputRoutingTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.agentSwitcher, for: .menu)
        settings.setAction(.arrowLeft, for: .left)
        settings.setAction(.arrowRight, for: .right)
        settings.setAction(.escape, for: .ok)
        settings.setAction(.deleteBackward, for: .back)
        profileID = try #require(settings.selectedRemoteProfileID)
        self.panel = panel
        monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { [weak self] in self?.permissionsGranted == true },
            actionPerformer: { [weak self] _, _, configured in
                self?.actions.append(configured.action)
                return true
            },
            frontmostBundleIdentifier: { PresetApplication.codex.bundleIdentifier },
            diagnosticLogger: { _ in },
            appSwitcherKeyStatePoster: { [weak self] code, down, _ in
                self?.postedKeys.append((code, down))
                return true
            }
        )
        monitor.onModalButtonEvent = { [weak self] profileID, button, phase in
            guard let self, let profileID else { return false }
            return self.panel.consume(button: button, phase: phase, owner: profileID.uuidString)
        }
        monitor.onInputReset = { [weak self] profileID in
            guard let profileID else { return }
            self?.panel.reset(owner: profileID.uuidString)
        }
        monitor.onInternalAction = { [weak self] profileID, action in
            guard let self, let profileID, action == .agentSwitcher else { return }
            self.monitor.prepareForAgentSwitcher()
            self.panel.activeOwner = profileID.uuidString
            self.panel.openCount += 1
        }
        monitor.connectSimulatedDevice(fingerprint: "routing-test", profileID: profileID)
    }

    func report(_ buttons: [RemoteButton]) {
        var bytes = buttons.flatMap { [UInt8(truncatingIfNeeded: $0.hidUsage), UInt8($0.hidUsage >> 8)] }
        while bytes.count < 6 { bytes.append(0) }
        monitor.handleSimulatedReport(reportID: 1, data: Data(bytes))
    }

    func tap(_ button: RemoteButton) {
        report([button])
        report([])
    }

    func close() {
        monitor.disconnectSimulatedDevice()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class AgentRoutingScheduler: HIDRemoteScheduling {
    private final class Task: HIDRemoteScheduledTask {
        var deadline: UInt64
        let interval: UInt64?
        let order: Int
        let action: () -> Void
        var cancelled = false

        init(deadline: UInt64, interval: UInt64?, order: Int, action: @escaping () -> Void) {
            self.deadline = deadline
            self.interval = interval
            self.order = order
            self.action = action
        }

        func cancel() { cancelled = true }
    }

    private var now: UInt64 = 0
    private var tasks: [Task] = []
    var pendingTaskCount: Int { tasks.filter { !$0.cancelled }.count }

    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask {
        let task = Task(
            deadline: now + afterMilliseconds,
            interval: repeatingEveryMilliseconds,
            order: tasks.count,
            action: action
        )
        tasks.append(task)
        return task
    }

    func advance(toMilliseconds target: UInt64) {
        precondition(target >= now)
        while let task = tasks.filter({ !$0.cancelled && $0.deadline <= target })
            .min(by: { ($0.deadline, $0.order) < ($1.deadline, $1.order) }) {
            now = task.deadline
            if task.interval == nil { task.cancelled = true }
            task.action()
            if !task.cancelled, let interval = task.interval { task.deadline += interval }
        }
        now = target
        tasks.removeAll { $0.cancelled }
    }
}
