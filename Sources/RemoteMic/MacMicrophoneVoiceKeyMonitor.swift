import CoreGraphics
import Foundation

private func macMicrophoneVoiceKeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let context {
        Unmanaged<MacMicrophoneVoiceKeyMonitor>.fromOpaque(context)
            .takeUnretainedValue().observe(type: type, event: event)
    }
    // A listen-only tap never consumes or replaces the user's key.
    return Unmanaged.passUnretained(event)
}

/// Observes the configured physical voice modifier, including Fn, without registering it as a hotkey.
final class MacMicrophoneVoiceKeyMonitor {
    var onEdge: (Bool, TimeInterval) -> Void = { _, _ in }
    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var generation: UInt64 = 0
    private var mode: VoiceKeyMode = .function

    @discardableResult
    func start(mode: VoiceKeyMode) -> Bool {
        lock.lock()
        let alreadyListening = port != nil && self.mode == mode
        lock.unlock()
        if alreadyListening { return true }
        stop()
        guard CGPreflightListenEventAccess() else {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=failed reason=input_monitoring_permission")
            return false
        }
        lock.lock()
        self.mode = mode
        lock.unlock()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: macMicrophoneVoiceKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=failed reason=tap_unavailable")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            EventTapPort.release(port: port, source: nil)
            return false
        }
        lock.lock()
        self.port = port
        self.source = source
        lock.unlock()
        guard EventTapPort.activate(port: port, source: source) else { stop(); return false }
        AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=started result=listening voice_key=\(mode.rawValue) event_passthrough=true")
        return true
    }

    func stop() {
        lock.lock()
        let port = self.port
        let source = self.source
        self.port = nil
        self.source = nil
        generation &+= 1
        lock.unlock()
        if port != nil || source != nil { EventTapPort.release(port: port, source: source) }
        if port != nil {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=completed result=stopped")
        }
    }

    func observe(type: CGEventType, event: CGEvent) {
        lock.lock()
        let port = self.port
        let generation = self.generation
        let mode = self.mode
        lock.unlock()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard port != nil, let pressed = Self.physicalEdge(type: type, event: event, mode: mode) else { return }
        let observedAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onEdge(pressed, observedAt)
        }
    }

    static func physicalEdge(type: CGEventType, event: CGEvent, mode: VoiceKeyMode) -> Bool? {
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(mode.keyCode),
              event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker else { return nil }
        return event.flags.contains(mode.eventFlags)
    }

    deinit { stop() }
}
