import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Mouse pointer motion")
struct MousePointerMotionControllerTests {
    private final class Harness {
        var time: TimeInterval = 100
        var cursor = CGPoint(x: 200, y: 200)
        var bounds = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        var moves: [CGPoint] = []
        var failMove = false
        var trusted = true
        var logs: [String] = []

        lazy var engine = MousePointerMotionEngine(dependencies: .init(
            now: { [unowned self] in self.time },
            cursorLocation: { [unowned self] in self.cursor },
            screenBounds: { [unowned self] in self.bounds },
            moveCursor: { [unowned self] point in
                if self.failMove { return false }
                self.moves.append(point)
                self.cursor = point
                return true
            },
            accessibilityTrusted: { [unowned self] in self.trusted },
            logger: { [unowned self] in self.logs.append($0) }
        ))
    }


    private final class ClickHarness {
        var now: TimeInterval = 100
        var lastMove: TimeInterval? = 99
        var enabled = true
        var postResult = true
        var clicks = 0
        var logs: [String] = []

        lazy var controller = MouseClickOnOKController(
            isEnabled: { [unowned self] in self.enabled },
            lastSuccessfulMoveAt: { [unowned self] in self.lastMove },
            now: { [unowned self] in self.now },
            postClick: { [unowned self] in
                self.clicks += 1
                return self.postResult
            },
            logger: { [unowned self] in self.logs.append($0) }
        )
    }

    @Test func clickOnOKOnlyConsumesAPressWithinTheRecentMoveWindow() {
        #expect(MouseClickOnOKPolicy.shouldClick(
            button: .ok,
            phase: .press,
            enabled: true,
            lastSuccessfulMoveAt: 98,
            now: 100
        ))
        #expect(!MouseClickOnOKPolicy.shouldClick(
            button: .ok,
            phase: .release,
            enabled: true,
            lastSuccessfulMoveAt: 99,
            now: 100
        ))
        #expect(!MouseClickOnOKPolicy.shouldClick(
            button: .back,
            phase: .press,
            enabled: true,
            lastSuccessfulMoveAt: 99,
            now: 100
        ))
        #expect(!MouseClickOnOKPolicy.shouldClick(
            button: .ok,
            phase: .press,
            enabled: false,
            lastSuccessfulMoveAt: 99,
            now: 100
        ))
        #expect(!MouseClickOnOKPolicy.shouldClick(
            button: .ok,
            phase: .press,
            enabled: true,
            lastSuccessfulMoveAt: nil,
            now: 100
        ))
        #expect(!MouseClickOnOKPolicy.shouldClick(
            button: .ok,
            phase: .press,
            enabled: true,
            lastSuccessfulMoveAt: 97.99,
            now: 100
        ))
    }

    @Test func clickControllerConsumesThePressAndFallsBackOnInjectionFailure() {
        let harness = ClickHarness()
        #expect(harness.controller.handle(button: .ok, phase: .press))
        #expect(harness.clicks == 1)
        #expect(harness.logs.last?.contains("result=submitted") == true)
        #expect(harness.logs.last?.contains("reason=ok_after_move") == true)

        harness.clicks = 0
        harness.now = 102.01
        #expect(!harness.controller.handle(button: .ok, phase: .press))
        #expect(harness.clicks == 0)

        harness.now = 100
        harness.lastMove = 99
        harness.postResult = false
        #expect(!harness.controller.handle(button: .ok, phase: .press))
        #expect(harness.clicks == 1)
        #expect(harness.logs.last?.contains("result=failed") == true)
    }

    @Test func speedCurveHoldsFineWindowThenAcceleratesAndCaps() {
        #expect(abs(MousePointerMotionEngine.speed(distance: 20, elapsed: 0) - 200) < 0.001)
        #expect(abs(MousePointerMotionEngine.speed(distance: 20, elapsed: 0.5) - 200) < 0.001)
        let mid = MousePointerMotionEngine.speed(distance: 20, elapsed: 0.85)
        #expect(mid > 200 && mid < 1_000)
        #expect(abs(MousePointerMotionEngine.speed(distance: 20, elapsed: 1.2) - 1_000) < 0.001)
        #expect(abs(MousePointerMotionEngine.speed(distance: 20, elapsed: 2) - 1_000) < 0.001)
        #expect(abs(MousePointerMotionEngine.speed(distance: 100, elapsed: 2) - 2_000) < 0.001)
    }

    @Test func shortPressMovesAboutBaseSpeedTimesDuration() throws {
        let harness = Harness()
        let token = try #require(harness.engine.begin(button: .right, direction: .right, distance: 20))
        for _ in 0..<12 {
            harness.time += 0.008
            _ = harness.engine.tick(now: harness.time)
        }
        harness.time += 0.004
        let end = try #require(harness.engine.end(token, reason: "released"))
        #expect(end.reason == "released")
        #expect(end.moved)
        #expect(abs(end.requestedPoints - 20) < 1.5)
        #expect(abs(harness.cursor.x - 220) < 1.5)
    }

    @Test func tickIntegratesAndReleaseFlushesTail() throws {
        let harness = Harness()
        let token = try #require(harness.engine.begin(button: .right, direction: .right, distance: 20))
        for _ in 0..<12 {
            harness.time += 0.008
            _ = harness.engine.tick(now: harness.time)
        }
        #expect(abs(harness.cursor.x - 219.2) < 1.5)
        harness.time += 0.004
        let end = try #require(harness.engine.end(token, reason: "released"))
        #expect(abs(end.requestedPoints - 20) < 1.5)
        #expect(abs(harness.cursor.x - 220) < 1.5)
    }

    @Test func subpixelRemainderEventuallyMovesOnePoint() throws {
        let harness = Harness()
        _ = try #require(harness.engine.begin(button: .right, direction: .right, distance: 1))
        var ticks = 0
        while harness.cursor.x < 201, ticks < 20 {
            harness.time += 0.008
            _ = harness.engine.tick(now: harness.time)
            ticks += 1
        }
        #expect(ticks > 0)
        #expect(harness.cursor.x >= 201)
    }

    @Test func stalledTickIsCappedAndReportsDroppedTime() throws {
        let harness = Harness()
        let token = try #require(harness.engine.begin(button: .right, direction: .right, distance: 20))
        harness.time += 0.1
        _ = harness.engine.tick(now: harness.time)
        harness.time += 0.2
        _ = harness.engine.tick(now: harness.time)
        let end = try #require(harness.engine.end(token, reason: "released"))
        #expect(end.droppedMilliseconds >= 160)
        #expect(end.requestedPoints < 100)
    }

    @Test func maximumSessionEndsWithoutExtraFlush() throws {
        let harness = Harness()
        _ = try #require(harness.engine.begin(button: .right, direction: .right, distance: 20))
        harness.time += 15.1
        let ends = harness.engine.tick(now: harness.time)
        #expect(ends.count == 1)
        #expect(ends.first?.reason == "timeout")
        #expect(harness.engine.hasActiveSessions == false)
    }

    @Test func injectionFailureEndsSession() throws {
        let harness = Harness()
        harness.failMove = true
        _ = try #require(harness.engine.begin(button: .right, direction: .right, distance: 20))
        harness.time += 0.1
        let ends = harness.engine.tick(now: harness.time)
        #expect(ends.count == 1)
        #expect(ends.first?.reason == "event_create_failed")
        #expect(ends.first?.errors == 1)
    }

    @Test func unavailableCursorEndsSession() throws {
        let harness = Harness()
        let missing = MousePointerMotionEngine(dependencies: .init(
            now: { harness.time },
            cursorLocation: { nil },
            screenBounds: { harness.bounds },
            moveCursor: { _ in true },
            accessibilityTrusted: { true },
            logger: { _ in }
        ))
        _ = try #require(missing.begin(button: .right, direction: .right, distance: 20))
        harness.time += 0.1
        let ends = missing.tick(now: harness.time)
        #expect(ends.count == 1)
        #expect(ends.first?.reason == "cursor_unavailable")
    }

    @Test func oneShotMoveRecordsTheOKClickWindow() {
        let harness = Harness()
        #expect(harness.engine.lastSuccessfulMoveAt == nil)
        harness.time = 123
        harness.engine.recordSuccessfulMove()
        #expect(harness.engine.lastSuccessfulMoveAt == 123)
        harness.engine.clearRecentMoveWindow()
        #expect(harness.engine.lastSuccessfulMoveAt == nil)
    }

    @Test func screenEdgeClampsAndDoesNotRefreshRecentMove() throws {
        let harness = Harness()
        harness.cursor = CGPoint(x: 999, y: 400)
        _ = try #require(harness.engine.begin(button: .right, direction: .right, distance: 20))
        harness.time += 0.1
        _ = harness.engine.tick(now: harness.time)
        #expect(harness.cursor.x == 999)
        #expect(harness.engine.lastSuccessfulMoveAt == nil)
    }

    @Test func accessibilityDeniedRejectsStart() {
        let harness = Harness()
        harness.trusted = false
        #expect(harness.engine.begin(button: .right, direction: .right, distance: 20) == nil)
        #expect(!harness.engine.hasActiveSessions)
    }

    @Test func stopAllEndsEverySessionWithoutFlush() throws {
        let harness = Harness()
        _ = try #require(harness.engine.begin(button: .right, direction: .right, distance: 20))
        _ = try #require(harness.engine.begin(button: .up, direction: .up, distance: 20))
        harness.time += 0.1
        let ends = harness.engine.stopAll(reason: "disconnected")
        #expect(ends.count == 2)
        #expect(ends.allSatisfy { $0.reason == "disconnected" })
        #expect(harness.engine.hasActiveSessions == false)
        #expect(harness.moves.isEmpty)
    }
}
