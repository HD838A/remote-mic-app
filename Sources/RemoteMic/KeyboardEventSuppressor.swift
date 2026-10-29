import AppKit
import CoreGraphics
import Foundation

private func keyboardEventSuppressorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<KeyboardEventSuppressor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return suppressor.handle(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

final class KeyboardEventSuppressor {
    private static let systemDefinedEventTypeRawValue: UInt32 = 14
    // Native HID delivery can trail the raw report by over 300 ms, including
    // arriving after release. Keep a bounded allowance for each expected edge.
    private static let nativeDeliveryWindow: TimeInterval = 0.5

    private struct PendingEvent {
        let event: RemoteNativeEvent
        let edge: RemoteEventEdge
        let armedAt: TimeInterval
        let expiresAt: TimeInterval
    }

    private let hardwareModifierState: ShortcutHardwareModifierState
    private let lock = NSLock()
    private let uptime: () -> TimeInterval
    private let logger: (String) -> Void
    private var pendingEvents: [PendingEvent] = []
    private var heldEventCounts: [RemoteNativeEvent: Int] = [:]
    // Only a native down actually consumed by this tap owns an early native up.
    private var nativeDownsAwaitingUp: [RemoteNativeEvent: Int] = [:]
    private var earlyNativeUps: [RemoteNativeEvent: Int] = [:]
    // Diagnostic-only: bounded to the remote's known native descriptors.
    private var recentUnclaimedDowns: [RemoteNativeEvent: TimeInterval] = [:]
    // An escaped volume down belongs to the system through its final release.
    // Dropping only its up can leave the system repeating volume indefinitely.
    private var passedVolumeDowns = Set<RemoteNativeEvent>()
    private var passedVolumeRawReleases: [RemoteNativeEvent: Int] = [:]
    private static let volumeEvents: Set<RemoteNativeEvent> = [.systemKey(type: 0), .systemKey(type: 1)]
    private static let knownNativeEvents = Set(RemoteButton.allCases.flatMap { $0.nativeEvents })
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 最近 arm 过的事件（带过期时刻），仅用于诊断日志：只有与这些事件相关的
    /// 未命中才值得记录，避免被无关键盘输入淹没。
    private var recentArmed: [(event: RemoteNativeEvent, until: TimeInterval)] = []

    private(set) var isRunning = false

    init(
        hardwareModifierState: ShortcutHardwareModifierState = ShortcutEventSequence.hardwareModifierState,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.hardwareModifierState = hardwareModifierState
        self.uptime = uptime
        self.logger = logger
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << Self.systemDefinedEventTypeRawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: keyboardEventSuppressorCallback,
            userInfo: context
        ) else {
            logger("HID FILTER phase=start_failed reason=tap_create_failed tap=session")
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            // tapCreate 成功即已在 WindowServer 侧登记端口；此处失败若不释放端口，
            // 该 tap 会残留到进程退出，必须与 stop() 走同一条清理路径。
            EventTapPort.release(port: eventTap, source: nil)
            logger("HID FILTER phase=start_failed reason=run_loop_source_failed tap=session")
            return false
        }

        hardwareModifierState.reset()
        guard EventTapPort.activate(port: eventTap, source: runLoopSource) else {
            // 端口已在 WindowServer 侧登记，但没能接入 tap 线程：按启动失败处理并
            // 走同一条清理路径。绝不能留下一个已 enable 却无人承接的 tap。
            EventTapPort.release(port: eventTap, source: runLoopSource)
            logger("HID FILTER phase=start_failed reason=tap_activation_failed tap=session")
            return false
        }
        lock.lock()
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        lock.unlock()
        isRunning = true
        logger("HID FILTER phase=started result=active tap=session")
        return true
    }

    func stop() {
        let wasRunning = isRunning
        hardwareModifierState.reset()
        // 回调跑在 tap 专用线程上，端口引用由主线程写入，必须加锁交接。
        lock.lock()
        let port = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        pendingEvents.removeAll()
        heldEventCounts.removeAll()
        nativeDownsAwaitingUp.removeAll()
        earlyNativeUps.removeAll()
        recentUnclaimedDowns.removeAll()
        passedVolumeDowns.removeAll()
        passedVolumeRawReleases.removeAll()
        recentArmed.removeAll()
        lock.unlock()
        EventTapPort.release(port: port, source: source)
        isRunning = false
        if wasRunning { logger("HID FILTER phase=stopped result=inactive tap=session") }
    }

    func arm(button: RemoteButton, edge: RemoteEventEdge) {
        arm(nativeEvents: button.nativeEvents, edge: edge)
    }

    func arm(nativeEvents: Set<RemoteNativeEvent>, edge: RemoteEventEdge) {
        guard !nativeEvents.isEmpty else { return }
        let now = uptime()
        lock.lock()
        recentArmed.removeAll { $0.until <= now }
        recentUnclaimedDowns = recentUnclaimedDowns.filter { now - $0.value < Self.nativeDeliveryWindow }
        var precedingDownAges: [(RemoteNativeEvent, Int)] = []
        var passedRawEvents: [RemoteNativeEvent] = []
        for nativeEvent in nativeEvents {
            recentArmed.append((event: nativeEvent, until: now + 1.0))
        }
        pendingEvents.removeAll { $0.expiresAt <= now }
        for nativeEvent in nativeEvents {
            switch edge {
            case .down:
                let unclaimed = recentUnclaimedDowns.removeValue(forKey: nativeEvent)
                if let unclaimed {
                    precedingDownAges.append((nativeEvent, Int((now - unclaimed) * 1_000)))
                }
                if passedVolumeDowns.contains(nativeEvent) {
                    // Consume the raw pair without creating stale native credits.
                    passedVolumeRawReleases[nativeEvent, default: 0] += 1
                    passedRawEvents.append(nativeEvent)
                    continue
                }
                heldEventCounts[nativeEvent, default: 0] += 1
                if heldEventCounts[nativeEvent] != 1 { nativeDownsAwaitingUp.removeValue(forKey: nativeEvent) }
                pendingEvents.append(PendingEvent(
                    event: nativeEvent,
                    edge: edge,
                    armedAt: now,
                    expiresAt: now + Self.nativeDeliveryWindow
                ))
            case .up:
                if let passed = passedVolumeRawReleases[nativeEvent], passed > 0 {
                    passedVolumeRawReleases[nativeEvent] = passed > 1 ? passed - 1 : nil
                    passedRawEvents.append(nativeEvent)
                    continue
                }
                nativeDownsAwaitingUp.removeValue(forKey: nativeEvent)
                // The native down may still be in flight. Release held-repeat
                // ownership without discarding that unconsumed expected edge.
                let remaining = (heldEventCounts[nativeEvent] ?? 0) - 1
                if remaining > 0 {
                    heldEventCounts[nativeEvent] = remaining
                } else {
                    heldEventCounts.removeValue(forKey: nativeEvent)
                }
                if (earlyNativeUps[nativeEvent] ?? 0) > 0 {
                    let remainingEarly = earlyNativeUps[nativeEvent, default: 0] - 1
                    earlyNativeUps[nativeEvent] = remainingEarly > 0 ? remainingEarly : nil
                    // Its native up already closed the pair. Do not arm a spare up
                    // that could consume a later physical keyboard release.
                    continue
                }
                pendingEvents.append(PendingEvent(
                    event: nativeEvent,
                    edge: edge,
                    armedAt: now,
                    expiresAt: now + Self.nativeDeliveryWindow
                ))
            }
        }
        if pendingEvents.count > 32 {
            pendingEvents.removeFirst(pendingEvents.count - 32)
        }
        lock.unlock()
        // Log after registration so logging cannot delay ownership of native input.
        logger(
            "HID FILTER arm events=\(nativeEvents.map(Self.logToken).sorted().joined(separator: "+")) "
                + "edge=\(edge == .down ? "down" : "up")"
        )
        for native in passedRawEvents {
            logger("HID FILTER phase=arm result=passthrough event=\(Self.logToken(native)) " +
                "edge=\(edge == .down ? "down" : "up") reason=escaped_native_pair source_correlation=timing_only")
        }
        for (native, age) in precedingDownAges {
            logger("HID FILTER phase=arm_order event=\(Self.logToken(native)) edge=down preceding_unclaimed_ms=\(age) " +
                "source_correlation=timing_only result=already_passed_through")
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger("HID FILTER phase=disabled reason=\(type == .tapDisabledByTimeout ? "timeout" : "user_input") tap=session")
            // 禁用窗口里的事件不会送到这里，松开的 Fn 边沿可能就此丢失。若保留旧的
            // pressed，之后每个快捷键都会被强行加上 Fn，直到下一次真实按下 Fn。
            // 复位成 unobserved 后，只有新的真实边沿才能让快照的 Fn 重新被信任。
            hardwareModifierState.reset()
            // 本回调在 tap 专用线程上执行，端口引用由主线程写入，必须加锁读取。
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                logger("HID FILTER phase=reenable_requested result=submitted tap=session")
            } else {
                logger("HID FILTER phase=reenable_requested result=unavailable tap=session")
            }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardInjector.syntheticEventMarker {
            ShortcutSessionObservation.shared.observe(event, logger: logger)
            return false
        }
        hardwareModifierState.observe(type: type, event: event)
        guard let descriptor = descriptor(type: type, event: event) else { return false }

        let now = uptime()
        lock.lock()
        pendingEvents.removeAll { $0.expiresAt <= now }
        if passedVolumeDowns.contains(descriptor.event) {
            if descriptor.edge == .up {
                passedVolumeDowns.remove(descriptor.event)
            }
            lock.unlock()
            logger("HID FILTER passed_through event=\(Self.logToken(descriptor.event)) " +
                "edge=\(descriptor.edge == .down ? "down" : "up") reason=escaped_native_pair")
            return false
        }
        if let matchIndex = pendingEvents.firstIndex(where: {
            $0.event == descriptor.event && $0.edge == descriptor.edge
        }) {
            let matched = pendingEvents.remove(at: matchIndex)
            if descriptor.edge == .down, heldEventCounts[descriptor.event] == 1,
               !pendingEvents.contains(where: { $0.event == descriptor.event && $0.edge == .up }),
               (earlyNativeUps[descriptor.event] ?? 0) == 0 {
                nativeDownsAwaitingUp[descriptor.event] = 1
            }
            lock.unlock()
            // 诊断：命中并吞掉——与 miss 日志对照即可判定「系统是否产生了该事件」。
            logger(
                "HID FILTER suppressed event=\(Self.logToken(descriptor.event)) "
                    + "edge=\(descriptor.edge == .down ? "down" : "up") type=\(type.rawValue) "
                    + "latency_ms=\(Int((now - matched.armedAt) * 1_000))"
            )
            return true
        }
        if descriptor.edge == .up,
           heldEventCounts[descriptor.event] == 1,
           (nativeDownsAwaitingUp[descriptor.event] ?? 0) > 0 {
            let remaining = nativeDownsAwaitingUp[descriptor.event, default: 0] - 1
            nativeDownsAwaitingUp[descriptor.event] = remaining > 0 ? remaining : nil
            earlyNativeUps[descriptor.event, default: 0] += 1
            lock.unlock()
            logger("HID FILTER suppressed event=\(Self.logToken(descriptor.event)) edge=up " +
                "type=\(type.rawValue) via=owned_native_pair raw_release=pending")
            return true
        }
        if descriptor.edge == .down, (heldEventCounts[descriptor.event] ?? 0) > 0 {
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                heldEventCounts.removeValue(forKey: descriptor.event)
                nativeDownsAwaitingUp.removeValue(forKey: descriptor.event)
                lock.unlock()
                logger(
                    "HID FILTER passed_through event=\(Self.logToken(descriptor.event)) "
                        + "edge=down type=\(type.rawValue) reason=new_keyboard_press"
                )
                return false
            }
            lock.unlock()
            return true
        }
        if descriptor.edge == .down, Self.knownNativeEvents.contains(descriptor.event) {
            recentUnclaimedDowns[descriptor.event] = now
            if Self.volumeEvents.contains(descriptor.event) {
                passedVolumeDowns.insert(descriptor.event)
            }
        }
        let pendingCount = pendingEvents.count
        // 诊断范围（187 的教训：条件太窄会漏掉「系统事件与预定键码不同」的情况）：
        //   1) 与预定键码一致但没被吞（窗口过期）；
        //   2) 任意 systemDefined（媒体/音量类，我们关心的正是这些）；
        //   3) 最近 1 秒内曾 arm 过（覆盖「系统产生的键码与我们预定的不同」）。
        let armedExactly = recentArmed.contains { $0.event == descriptor.event && $0.until > now }
        let isSystemDefined = type.rawValue == Self.systemDefinedEventTypeRawValue
        let withinArmedWindow = Self.hasActiveArmedWindow(recentArmed, now: now)
        lock.unlock()
        if armedExactly || isSystemDefined || withinArmedWindow {
            logger(
                "HID FILTER miss type=\(type.rawValue) event=\(Self.logToken(descriptor.event)) "
                    + "edge=\(descriptor.edge == .down ? "down" : "up") "
                    + "armed=\(armedExactly) pending=\(pendingCount)"
            )
        }
        return false
    }

    static func hasActiveArmedWindow(
        _ recentArmed: [(event: RemoteNativeEvent, until: TimeInterval)],
        now: TimeInterval
    ) -> Bool {
        recentArmed.contains { $0.until > now }
    }

    private static func logToken(_ event: RemoteNativeEvent) -> String {
        switch event {
        case .keyboard(let keyCode): return "key\(keyCode)"
        case .systemKey(let type): return "sys\(type)"
        }
    }

    private func descriptor(
        type: CGEventType,
        event: CGEvent
    ) -> (event: RemoteNativeEvent, edge: RemoteEventEdge)? {
        if type.rawValue == Self.systemDefinedEventTypeRawValue {
            guard let nsEvent = NSEvent(cgEvent: event) else { return nil }
            let systemKeyType = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
            let keyState = (nsEvent.data1 & 0x0000_FF00) >> 8
            let edge: RemoteEventEdge
            switch keyState {
            case 0xA: edge = .down
            case 0xB: edge = .up
            default: return nil
            }
            return (.systemKey(type: systemKeyType), edge)
        }

        switch type {
        case .keyDown, .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            return (.keyboard(keyCode: keyCode), type == .keyDown ? .down : .up)
        default:
            return nil
        }
    }
}
