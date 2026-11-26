import CoreGraphics
import Foundation

/// 一次鼠标移动会话的唯一标识。控制器按 token 结束会话，不能用按键当键，
/// 否则两个输入来源或两次会话会互相停止。
struct MouseMotionToken: Hashable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }

    var logValue: String { id.uuidString.prefix(8).lowercased() }
}

struct MouseMotionEnd {
    let token: MouseMotionToken
    let button: RemoteButton
    let direction: MouseMoveDirection
    let distance: Int
    let reason: String
    let duration: TimeInterval
    let ticks: UInt64
    let requestedPoints: Double
    let observedPoints: Double
    let peakSpeed: Double
    let droppedMilliseconds: UInt64
    let errors: UInt64
    let moved: Bool
}

/// 纯状态机：不建定时器，不持锁，不做事件注入。
///
/// 时间、光标位置、屏幕边界和注入都由调用方提供，因此单元测试可以逐帧推进。
/// 线上由 `MousePointerMotionController` 在专用串行队列上驱动。
final class MousePointerMotionEngine {
    static let tick: TimeInterval = 0.008
    static let baseSpeedPerUnit: Double = 10
    static let maxSpeedMultiplier: Double = 5
    static let maxSpeed: Double = 2_000
    static let fineWindow: TimeInterval = 0.5
    static let acceleration: TimeInterval = 0.7
    static let maximumStep: TimeInterval = 0.032
    static let maximumSession: TimeInterval = 15
    static let progressInterval: TimeInterval = 1

    struct Dependencies {
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var cursorLocation: () -> CGPoint? = { CGEvent(source: nil)?.location }
        var screenBounds: () -> CGRect = { MousePointerMotionEngine.activeDisplayBounds() }
        var moveCursor: (CGPoint) -> Bool = { KeyboardInjector.postMouseMoved(to: $0) }
        var accessibilityTrusted: () -> Bool = { KeyboardInjector.isAccessibilityTrusted }
        var logger: (String) -> Void = { AppLogger.shared.write($0) }
    }

    private struct Session {
        let token: MouseMotionToken
        let button: RemoteButton
        let direction: MouseMoveDirection
        let distance: Int
        let baseSpeed: Double
        let maxSpeed: Double
        let startedAt: TimeInterval
        var lastTickAt: TimeInterval
        var lastProgressAt: TimeInterval
        var pendingX: Double = 0
        var pendingY: Double = 0
        var requestedPoints: Double = 0
        var observedPoints: Double = 0
        var ticks: UInt64 = 0
        var peakSpeed: Double
        var droppedMilliseconds: UInt64 = 0
        var errors: UInt64 = 0
        var moved = false
    }

    private let dependencies: Dependencies
    private var sessions: [MouseMotionToken: Session] = [:]
    private let recentMoveLock = NSLock()
    private var storedLastSuccessfulMoveAt: TimeInterval?

    init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        dependencies.logger(
            "MOUSE MOTION phase=config result=ready tick_ms=\(Int(Self.tick * 1_000)) " +
                "base_pt_s_per_unit=\(Self.baseSpeedPerUnit) max_multiplier=\(Self.maxSpeedMultiplier) " +
                "max_pt_s=\(Self.maxSpeed) fine_ms=\(Int(Self.fineWindow * 1_000)) " +
                "accel_ms=\(Int(Self.acceleration * 1_000)) max_session_ms=\(Int(Self.maximumSession * 1_000))"
        )
    }

    var hasActiveSessions: Bool {
        !sessions.isEmpty
    }

    var lastSuccessfulMoveAt: TimeInterval? {
        recentMoveLock.lock()
        defer { recentMoveLock.unlock() }
        return storedLastSuccessfulMoveAt
    }

    func clearRecentMoveWindow() {
        recentMoveLock.lock()
        storedLastSuccessfulMoveAt = nil
        recentMoveLock.unlock()
    }

    func begin(
        button: RemoteButton,
        direction: MouseMoveDirection,
        distance: Int
    ) -> MouseMotionToken? {
        guard dependencies.accessibilityTrusted() else {
            dependencies.logger(
                "MOUSE MOTION phase=start result=rejected reason=accessibility_denied button=\(button.rawValue)"
            )
            return nil
        }
        let clampedDistance = min(
            max(distance, ConfiguredButtonAction.mouseMoveDistanceRange.lowerBound),
            ConfiguredButtonAction.mouseMoveDistanceRange.upperBound
        )
        let now = dependencies.now()
        let baseSpeed = Double(clampedDistance) * Self.baseSpeedPerUnit
        let maxSpeed = min(baseSpeed * Self.maxSpeedMultiplier, Self.maxSpeed)
        let token = MouseMotionToken()
        let session = Session(
            token: token,
            button: button,
            direction: direction,
            distance: clampedDistance,
            baseSpeed: baseSpeed,
            maxSpeed: maxSpeed,
            startedAt: now,
            lastTickAt: now,
            lastProgressAt: now,
            peakSpeed: baseSpeed
        )
        sessions[token] = session
        dependencies.logger(
            "MOUSE MOTION operation_id=\(token.logValue) phase=start result=started " +
                "button=\(button.rawValue) direction=\(direction.rawValue) distance=\(clampedDistance) " +
                "base_pt_s=\(format(baseSpeed)) max_pt_s=\(format(maxSpeed)) " +
                "fine_ms=\(Int(Self.fineWindow * 1_000)) accel_ms=\(Int(Self.acceleration * 1_000)) " +
                "tick_ms=\(Int(Self.tick * 1_000))"
        )
        return token
    }

    /// 推进所有到期会话。返回本轮因超时或注入失败而结束的会话。
    @discardableResult
    func tick(now: TimeInterval) -> [MouseMotionEnd] {
        var ends: [MouseMotionEnd] = []
        for token in Array(sessions.keys) {
            guard let session = sessions[token] else { continue }
            if now - session.startedAt >= Self.maximumSession {
                if let end = finish(token: token, now: now, reason: "timeout", flush: false) {
                    ends.append(end)
                }
                continue
            }
            if let end = advance(token: token, now: now) {
                ends.append(end)
            }
        }
        return ends
    }

    /// 结束一个会话：先补最后一个 tick 到松手之间的位移，再停止。
    @discardableResult
    func end(_ token: MouseMotionToken, reason: String) -> MouseMotionEnd? {
        finish(token: token, now: dependencies.now(), reason: reason, flush: true)
    }

    @discardableResult
    func stopAll(reason: String) -> [MouseMotionEnd] {
        var ends: [MouseMotionEnd] = []
        for token in Array(sessions.keys) {
            if let end = finish(token: token, now: dependencies.now(), reason: reason, flush: false) {
                ends.append(end)
            }
        }
        return ends
    }

    static func speed(distance: Int, elapsed: TimeInterval) -> Double {
        let base = Double(distance) * baseSpeedPerUnit
        let maximum = min(base * maxSpeedMultiplier, maxSpeed).nonNegative
        guard elapsed > fineWindow else { return base }
        guard elapsed < fineWindow + acceleration else { return maximum }
        let progress = min(max((elapsed - fineWindow) / acceleration, 0), 1)
        return base + (maximum - base) * progress * progress
    }

    static func activeDisplayBounds() -> CGRect {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0
        else { return .null }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        var actualCount = displayCount
        let result = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &actualCount)
        }
        guard result == .success else { return .null }
        return displays.prefix(Int(actualCount)).reduce(CGRect.null) { bounds, display in
            bounds.union(CGDisplayBounds(display))
        }
    }

    static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        guard !bounds.isNull, !bounds.isEmpty else { return point }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private func finish(
        token: MouseMotionToken,
        now: TimeInterval,
        reason: String,
        flush: Bool
    ) -> MouseMotionEnd? {
        guard sessions[token] != nil else { return nil }
        if flush {
            // 补最后一帧；短按也有位移，长按松手不会丢尾段。
            _ = advance(token: token, now: now)
        }
        guard let session = sessions.removeValue(forKey: token) else { return nil }
        let resolvedReason = session.errors > 0 ? "event_create_failed" : reason
        let duration = max(0, now - session.startedAt)
        let end = MouseMotionEnd(
            token: token,
            button: session.button,
            direction: session.direction,
            distance: session.distance,
            reason: resolvedReason,
            duration: duration,
            ticks: session.ticks,
            requestedPoints: session.requestedPoints,
            observedPoints: session.observedPoints,
            peakSpeed: session.peakSpeed,
            droppedMilliseconds: session.droppedMilliseconds,
            errors: session.errors,
            moved: session.moved
        )
        dependencies.logger(
            "MOUSE MOTION operation_id=\(token.logValue) phase=completed result=\(end.reason) " +
                "button=\(end.button.rawValue) direction=\(end.direction.rawValue) " +
                "duration_ms=\(Int(duration * 1_000)) ticks=\(end.ticks) " +
                "requested_pt=\(format(end.requestedPoints)) observed_pt=\(format(end.observedPoints)) " +
                "peak_pt_s=\(format(end.peakSpeed)) dropped_ms=\(end.droppedMilliseconds) " +
                "errors=\(end.errors) moved=\(end.moved)"
        )
        return end
    }

    /// 返回非 nil 表示会话因注入失败而结束。
    private func advance(
        token: MouseMotionToken,
        now: TimeInterval
    ) -> MouseMotionEnd? {
        guard var session = sessions[token] else { return nil }
        guard now > session.lastTickAt else { return nil }
        let elapsedSinceLast = now - session.lastTickAt
        let stepTime: TimeInterval
        if elapsedSinceLast > Self.maximumStep {
            session.droppedMilliseconds &+= UInt64((elapsedSinceLast - Self.maximumStep) * 1_000)
            stepTime = Self.maximumStep
        } else {
            stepTime = elapsedSinceLast
        }
        guard stepTime > 0 else { return nil }

        let midpoint = session.lastTickAt - session.startedAt + stepTime / 2
        let speed = Self.speed(distance: session.distance, elapsed: midpoint)
        let vector = Self.unitVector(session.direction)
        session.pendingX += vector.x * speed * stepTime
        session.pendingY += vector.y * speed * stepTime
        let stepX = Int(session.pendingX)
        let stepY = Int(session.pendingY)
        session.pendingX -= Double(stepX)
        session.pendingY -= Double(stepY)
        session.lastTickAt = now
        session.ticks &+= 1
        session.peakSpeed = max(session.peakSpeed, speed)

        if stepX != 0 || stepY != 0 {
            let requested = hypot(Double(stepX), Double(stepY))
            session.requestedPoints += requested
            guard let origin = dependencies.cursorLocation() else {
                sessions[token] = session
                return finish(token: token, now: now, reason: "cursor_unavailable", flush: false)
            }
            let target = Self.clamped(
                CGPoint(x: origin.x + Double(stepX), y: origin.y + Double(stepY)),
                to: dependencies.screenBounds()
            )
            let requestedAfterClamp = hypot(target.x - origin.x, target.y - origin.y)
            guard dependencies.moveCursor(target) else {
                session.errors &+= 1
                sessions[token] = session
                return finish(token: token, now: now, reason: "event_create_failed", flush: false)
            }
            let observed = dependencies.cursorLocation().map {
                hypot($0.x - origin.x, $0.y - origin.y)
            } ?? requestedAfterClamp
            session.observedPoints += observed
            session.moved = true
            if requestedAfterClamp > 0 {
                let movedAt = now
                recentMoveLock.lock()
                storedLastSuccessfulMoveAt = movedAt
                recentMoveLock.unlock()
            }
        }

        if now - session.lastProgressAt >= Self.progressInterval {
            session.lastProgressAt = now
            dependencies.logger(
                "MOUSE MOTION operation_id=\(token.logValue) phase=progress " +
                    "button=\(session.button.rawValue) direction=\(session.direction.rawValue) " +
                    "duration_ms=\(Int((now - session.startedAt) * 1_000)) ticks=\(session.ticks) " +
                    "speed_pt_s=\(format(speed)) requested_pt=\(format(session.requestedPoints)) " +
                    "observed_pt=\(format(session.observedPoints))"
            )
        }
        sessions[token] = session
        return nil
    }

    private static func unitVector(_ direction: MouseMoveDirection) -> (x: Double, y: Double) {
        switch direction {
        case .up: return (0, -1)
        case .down: return (0, 1)
        case .left: return (-1, 0)
        case .right: return (1, 0)
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private extension Double {
    var nonNegative: Double { max(0, self) }
}

/// 线上驱动：专用串行队列 + 8ms 定时器。所有会话状态只在该队列上修改。
final class MousePointerMotionController {
    private let queue: DispatchQueue
    private let engine: MousePointerMotionEngine
    private var timer: DispatchSourceTimer?
    private var timerGeneration: UInt64 = 0

    init(
        engine: MousePointerMotionEngine = MousePointerMotionEngine(),
        queue: DispatchQueue = DispatchQueue(label: "SayAll.MousePointerMotion")
    ) {
        self.engine = engine
        self.queue = queue
    }

    deinit {
        timer?.cancel()
    }

    @discardableResult
    func begin(
        button: RemoteButton,
        direction: MouseMoveDirection,
        distance: Int
    ) -> MouseMotionToken? {
        var token: MouseMotionToken?
        queue.sync {
            token = engine.begin(button: button, direction: direction, distance: distance)
            if token != nil {
                startTimerIfNeeded()
            }
        }
        return token
    }

    func end(_ token: MouseMotionToken, reason: String) {
        queue.sync {
            _ = engine.end(token, reason: reason)
            stopTimerIfIdle()
        }
    }

    func stopAll(reason: String) {
        queue.sync {
            _ = engine.stopAll(reason: reason)
            stopTimerIfIdle()
        }
    }

    var lastSuccessfulMoveAt: TimeInterval? {
        engine.lastSuccessfulMoveAt
    }

    func clearRecentMoveWindow() {
        queue.sync {
            engine.clearRecentMoveWindow()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timerGeneration &+= 1
        let generation = timerGeneration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(Int(MousePointerMotionEngine.tick * 1_000)),
            repeating: .milliseconds(Int(MousePointerMotionEngine.tick * 1_000)),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self, self.timerGeneration == generation else { return }
            _ = self.engine.tick(now: ProcessInfo.processInfo.systemUptime)
            self.stopTimerIfIdle()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimerIfIdle() {
        guard !engine.hasActiveSessions else { return }
        timer?.cancel()
        timer = nil
    }
}
