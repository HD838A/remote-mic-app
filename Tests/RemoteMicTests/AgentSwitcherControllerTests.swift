import AppKit
import Foundation
import Testing
@testable import RemoteMic

@MainActor
@Suite("Agent switcher controller")
struct AgentSwitcherControllerTests {
    @Test func selectedApplicationFocusRunsOnceAfterFrontmostAndPanelDismissal() {
        let scheduler = AgentSwitcherTestScheduler()
        let renderer = AgentSwitcherTestRenderer()
        var frontmost = "other.bundle"
        var completion: ((Error?) -> Void)?
        var focused: [String] = []
        let controller = AgentSwitcherController(
            opener: { _, callback in completion = callback },
            onApplicationActivated: { application, operationID in
                #expect(renderer.dismissCount == 1)
                #expect(operationID == 1)
                focused.append(application.id)
            },
            frontmostBundleIdentifier: { frontmost },
            scheduler: scheduler,
            renderer: renderer
        )
        controller.toggle(applications: testApplications, owner: "hid:one")
        _ = controller.handle(button: .right, owner: "hid:one")
        _ = controller.handle(button: .ok, owner: "hid:one")
        #expect(focused.isEmpty)
        completion?(nil)
        scheduler.advance(byMilliseconds: 500)
        #expect(focused.isEmpty)
        frontmost = "codex.bundle"
        scheduler.advance(byMilliseconds: 250)
        #expect(focused == ["codex.bundle"])
        completion?(nil)
        scheduler.advance(byMilliseconds: 500)
        #expect(focused == ["codex.bundle"])
    }

    @Test func cancelledOpeningNeverFocusesFromLateCallback() {
        let scheduler = AgentSwitcherTestScheduler()
        var completion: ((Error?) -> Void)?
        var focusCount = 0
        let controller = AgentSwitcherController(
            opener: { _, callback in completion = callback },
            onApplicationActivated: { _, _ in focusCount += 1 },
            frontmostBundleIdentifier: { "cursor.bundle" },
            scheduler: scheduler,
            renderer: AgentSwitcherTestRenderer()
        )
        controller.toggle(applications: testApplications, owner: "hid:one")
        _ = controller.handle(button: .ok, owner: "hid:one")
        _ = controller.handle(button: .back, owner: "hid:one")
        completion?(nil)
        scheduler.advance(byMilliseconds: 500)
        #expect(focusCount == 0)
    }

    @Test func leftRightSelectionWrapsAndOKOpensTheSelectedApplication() {
        let scheduler = AgentSwitcherTestScheduler()
        let renderer = AgentSwitcherTestRenderer()
        var frontmost = "cursor.bundle"
        var opened: [AgentSwitcherApplication] = []
        var logs: [String] = []
        let controller = AgentSwitcherController(
            opener: { application, completion in
                opened.append(application)
                completion(nil)
            },
            frontmostBundleIdentifier: { frontmost },
            scheduler: scheduler,
            logger: { logs.append($0) },
            renderer: renderer
        )
        let applications = testApplications

        controller.toggle(applications: applications, owner: "hid:one")
        #expect(renderer.lastState?.selectedApplication?.id == "cursor.bundle")

        #expect(controller.handle(button: .left, owner: "hid:one"))
        #expect(renderer.lastState?.selectedApplication?.id == "codex.bundle")

        #expect(controller.handle(button: .right, owner: "hid:one"))
        #expect(renderer.lastState?.selectedApplication?.id == "cursor.bundle")

        #expect(controller.handle(button: .right, owner: "hid:one"))
        #expect(renderer.lastState?.selectedApplication?.id == "codex.bundle")

        #expect(controller.handle(button: .ok, owner: "hid:one"))
        frontmost = "codex.bundle"
        scheduler.advance(byMilliseconds: AgentSwitcherController.frontmostPollMilliseconds)

        #expect(opened.map(\.id) == ["codex.bundle"])
        #expect(!controller.isActive)
        #expect(renderer.dismissCount == 1)
        #expect(logs.allSatisfy { $0.contains("operation_id=") })
        #expect(!logs.contains { $0.contains("cursor.bundle") || $0.contains("codex.bundle") || $0.contains("hid:one") })
        #expect(logs.filter { $0.contains("phase=completed") }.count == 1)
        #expect(logs.contains { $0.contains("phase=completed result=frontmost selection=1") })
    }

    @Test func unrelatedOwnerCannotDriveOrCancelAnActiveSwitcher() {
        let renderer = AgentSwitcherTestRenderer()
        let controller = AgentSwitcherController(
            opener: { _, completion in completion(nil) },
            scheduler: AgentSwitcherTestScheduler(),
            renderer: renderer
        )

        controller.toggle(applications: testApplications, owner: "hid:one")

        #expect(!controller.handle(button: .right, owner: "hid:two"))
        #expect(controller.isActive)
        #expect(controller.owner == "hid:one")
        #expect(renderer.lastState?.selectedApplication?.id == "cursor.bundle")

        controller.cancel(owner: "hid:two", reason: "wrong_owner")
        #expect(controller.isActive)

        controller.cancel(owner: "hid:one", reason: "right_owner")
        #expect(!controller.isActive)
    }

    @Test func otherButtonsCancelThenReturnFalseForNormalRouting() {
        let renderer = AgentSwitcherTestRenderer()
        let controller = AgentSwitcherController(
            opener: { _, completion in completion(nil) },
            scheduler: AgentSwitcherTestScheduler(),
            renderer: renderer
        )

        controller.toggle(applications: testApplications, owner: "mobile:web")

        #expect(!controller.handle(button: .volumeUp, owner: "mobile:web"))
        #expect(!controller.isActive)
        #expect(renderer.dismissCount == 1)
    }

    @Test func failureKeepsTheSwitcherOpenForRetryOrCancel() {
        let scheduler = AgentSwitcherTestScheduler()
        let renderer = AgentSwitcherTestRenderer()
        var shouldFail = true
        var opened: [String] = []
        let controller = AgentSwitcherController(
            opener: { application, completion in
                opened.append(application.id)
                if shouldFail {
                    completion(AgentSwitcherTestError.openFailed)
                } else {
                    completion(nil)
                }
            },
            frontmostBundleIdentifier: { "cursor.bundle" },
            scheduler: scheduler,
            renderer: renderer
        )

        controller.toggle(applications: testApplications, owner: "apple:one")
        #expect(controller.handle(button: .ok, owner: "apple:one"))

        #expect(controller.isActive)
        #expect(renderer.lastState?.phase == .failed("cursor.bundle"))

        shouldFail = false
        #expect(controller.handle(button: .ok, owner: "apple:one"))
        scheduler.advance(byMilliseconds: AgentSwitcherController.frontmostPollMilliseconds)

        #expect(opened == ["cursor.bundle", "cursor.bundle"])
        #expect(!controller.isActive)
    }

    @Test func timeoutCancelsTheCurrentSessionAndIgnoresLateCallbacks() {
        let scheduler = AgentSwitcherTestScheduler()
        let renderer = AgentSwitcherTestRenderer()
        var completion: ((Error?) -> Void)?
        var logs: [String] = []
        let controller = AgentSwitcherController(
            opener: { _, callback in completion = callback },
            scheduler: scheduler,
            logger: { logs.append($0) },
            renderer: renderer
        )

        controller.toggle(applications: testApplications, owner: "preview")
        #expect(controller.handle(button: .ok, owner: "preview"))
        scheduler.advance(byMilliseconds: AgentSwitcherController.timeoutMilliseconds)

        #expect(!controller.isActive)
        completion?(nil)
        #expect(!controller.isActive)
        #expect(logs.contains { $0.contains("phase=cancelled reason=timeout") })
        #expect(!logs.contains { $0.contains("phase=completed") })
    }

    @Test func emptyStateConsumesNavigationAndCanBeCancelled() {
        let scheduler = AgentSwitcherTestScheduler()
        let renderer = AgentSwitcherTestRenderer()
        var opened = false
        let controller = AgentSwitcherController(
            opener: { _, completion in
                opened = true
                completion(nil)
            },
            scheduler: scheduler,
            renderer: renderer
        )

        controller.toggle(applications: [], owner: "preview")

        #expect(controller.isActive)
        #expect(renderer.lastState?.phase == .empty)
        #expect(controller.handle(button: .right, owner: "preview"))
        #expect(controller.handle(button: .ok, owner: "preview"))
        #expect(!opened)
        #expect(controller.isActive)
        #expect(controller.handle(button: .back, owner: "preview"))
        #expect(!controller.isActive)
    }

    @Test func openingIgnoresRepeatedConfirmationAndWaitsForFrontmost() {
        let scheduler = AgentSwitcherTestScheduler()
        let renderer = AgentSwitcherTestRenderer()
        var completion: ((Error?) -> Void)?
        var opens = 0
        var frontmost = "other.bundle"
        let controller = AgentSwitcherController(
            opener: { _, callback in opens += 1; completion = callback },
            frontmostBundleIdentifier: { frontmost },
            scheduler: scheduler,
            logger: { _ in },
            renderer: renderer
        )
        controller.toggle(applications: testApplications, owner: "preview")
        _ = controller.handle(button: .ok, owner: "preview")
        _ = controller.handle(button: .ok, owner: "preview")
        _ = controller.handle(button: .right, owner: "preview")
        renderer.actions?.confirm()
        #expect(opens == 1)
        #expect(renderer.lastState?.selectedIndex == 0)
        completion?(nil)
        scheduler.advance(byMilliseconds: 500)
        #expect(controller.isActive)
        frontmost = "cursor.bundle"
        scheduler.advance(byMilliseconds: 250)
        #expect(!controller.isActive)
    }

    @Test func oldOpeningCallbackCannotChangeReplacementSession() {
        let renderer = AgentSwitcherTestRenderer()
        var completion: ((Error?) -> Void)?
        let controller = AgentSwitcherController(
            opener: { _, callback in completion = callback },
            scheduler: AgentSwitcherTestScheduler(),
            logger: { _ in },
            renderer: renderer
        )
        controller.toggle(applications: testApplications, owner: "first")
        _ = controller.handle(button: .ok, owner: "first")
        controller.toggle(applications: testApplications, owner: "second")
        completion?(AgentSwitcherTestError.openFailed)
        #expect(controller.owner == "second")
        #expect(renderer.lastState?.phase == .choosing)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(!controller.isActive)
    }

    private var testApplications: [AgentSwitcherApplication] {
        [
            AgentSwitcherApplication(
                id: "cursor.bundle",
                name: "Cursor",
                url: URL(fileURLWithPath: "/Applications/Cursor.app")
            ),
            AgentSwitcherApplication(
                id: "codex.bundle",
                name: "Codex",
                url: URL(fileURLWithPath: "/Applications/Codex.app")
            ),
        ]
    }
}

private enum AgentSwitcherTestError: Error {
    case openFailed
}

private final class AgentSwitcherTestRenderer: AgentSwitcherRendering {
    var states: [AgentSwitcherState] = []
    var dismissCount = 0
    var actions: AgentSwitcherActions?

    var lastState: AgentSwitcherState? { states.last }

    func show(state: AgentSwitcherState, actions: AgentSwitcherActions) {
        self.actions = actions
        states.append(state)
    }

    func update(state: AgentSwitcherState) {
        states.append(state)
    }

    func dismiss() {
        dismissCount += 1
    }
}

private final class AgentSwitcherTestScheduler: HIDRemoteScheduling {
    private final class Task: HIDRemoteScheduledTask {
        var deadline: UInt64
        let interval: UInt64?
        let action: () -> Void
        var cancelled = false

        init(deadline: UInt64, interval: UInt64?, action: @escaping () -> Void) {
            self.deadline = deadline
            self.interval = interval
            self.action = action
        }

        func cancel() {
            cancelled = true
        }
    }

    private var now: UInt64 = 0
    private var tasks: [Task] = []

    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask {
        let task = Task(
            deadline: now + afterMilliseconds,
            interval: repeatingEveryMilliseconds,
            action: action
        )
        tasks.append(task)
        return task
    }

    func advance(byMilliseconds milliseconds: UInt64) {
        let target = now + milliseconds
        while let task = tasks.filter({ !$0.cancelled && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            now = task.deadline
            if task.interval == nil { task.cancelled = true }
            task.action()
            if !task.cancelled, let interval = task.interval { task.deadline += interval }
        }
        now = target
        tasks.removeAll { $0.cancelled }
    }
}
