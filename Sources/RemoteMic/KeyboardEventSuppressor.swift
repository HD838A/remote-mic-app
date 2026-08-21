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

    private struct PendingEvent {
        let event: RemoteNativeEvent
        let edge: RemoteEventEdge
        let expiresAt: TimeInterval
    }

    private let lock = NSLock()
    private var pendingEvents: [PendingEvent] = []
    private var heldEventCounts: [RemoteNativeEvent: Int] = [:]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private(set) var isRunning = false

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue) |
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
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        lock.lock()
        pendingEvents.removeAll()
        heldEventCounts.removeAll()
        lock.unlock()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    func arm(button: RemoteButton, edge: RemoteEventEdge) {
        guard let nativeEvent = button.nativeEvent else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        pendingEvents.removeAll { $0.expiresAt <= now }
        switch edge {
        case .down:
            heldEventCounts[nativeEvent, default: 0] += 1
            pendingEvents.append(PendingEvent(
                event: nativeEvent,
                edge: edge,
                expiresAt: now + 0.18
            ))
        case .up:
            if let pendingDownIndex = pendingEvents.firstIndex(where: {
                $0.event == nativeEvent && $0.edge == .down
            }) {
                pendingEvents.remove(at: pendingDownIndex)
            }
            let remaining = (heldEventCounts[nativeEvent] ?? 0) - 1
            if remaining > 0 {
                heldEventCounts[nativeEvent] = remaining
            } else {
                heldEventCounts.removeValue(forKey: nativeEvent)
            }
            pendingEvents.append(PendingEvent(
                event: nativeEvent,
                edge: edge,
                expiresAt: now + 0.18
            ))
        }
        if pendingEvents.count > 32 {
            pendingEvents.removeFirst(pendingEvents.count - 32)
        }
        lock.unlock()
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardInjector.syntheticEventMarker {
            return false
        }
        guard let descriptor = descriptor(type: type, event: event) else { return false }

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        pendingEvents.removeAll { $0.expiresAt <= now }
        if let matchIndex = pendingEvents.firstIndex(where: {
            $0.event == descriptor.event && $0.edge == descriptor.edge
        }) {
            pendingEvents.remove(at: matchIndex)
            lock.unlock()
            return true
        }
        if descriptor.edge == .down, (heldEventCounts[descriptor.event] ?? 0) > 0 {
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                heldEventCounts.removeValue(forKey: descriptor.event)
                lock.unlock()
                return false
            }
            lock.unlock()
            return true
        }
        lock.unlock()
        return false
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
