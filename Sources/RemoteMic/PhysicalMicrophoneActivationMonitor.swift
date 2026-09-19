import AppKit
import CoreGraphics

private func physicalMicrophoneActivationEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<PhysicalMicrophoneActivationMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    monitor.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

struct RightCommandToggleDetector {
    private(set) var isPressed = false

    mutating func handle(keyCode: UInt16, commandPressed: Bool) -> Bool {
        guard keyCode == UInt16(KeyboardInjector.rightCommandKeyCode) else { return false }
        if !commandPressed {
            isPressed = false
            return false
        }
        guard !isPressed else { return false }
        isPressed = true
        return true
    }
}

final class PhysicalMicrophoneActivationMonitor {
    private let onToggle: () -> Void
    private var detector = RightCommandToggleDetector()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func start() {
        guard eventTap == nil, KeyboardInjector.isAccessibilityTrusted else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: physicalMicrophoneActivationEventTapCallback,
            userInfo: context
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        else {
            AppLogger.shared.write("MIC PASSTHROUGH MONITOR phase=failed result=event_tap_unavailable")
            return
        }
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        AppLogger.shared.write("MIC PASSTHROUGH MONITOR phase=completed result=started")
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        runLoopSource = nil
        eventTap = nil
    }

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker
        else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let commandPressed = event.flags.contains(.maskCommand)
        if detector.handle(keyCode: keyCode, commandPressed: commandPressed) {
            AppLogger.shared.write("MIC PASSTHROUGH MONITOR event=right_command_toggle")
            DispatchQueue.main.async { [weak self] in self?.onToggle() }
        }
    }
}
