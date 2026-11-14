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
    private enum TapLevel: String {
        case hid = "hid_head"
        case session = "session_head"

        var location: CGEventTapLocation {
            self == .hid ? .cghidEventTap : .cgSessionEventTap
        }
    }

    var onEdge: (Bool, TimeInterval) -> Void = { _, _ in }
    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapLevel: TapLevel?
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

        // A voice tool such as Doubao may consume Fn in an earlier session tap.
        // Try the HID-level listen-only tap first so the physical edge remains
        // observable; fall back to the session-level head tap when unavailable.
        if let installed = installTap(level: .hid, mode: mode) {
            store(installed, level: .hid, mode: mode)
            return true
        }
        AppLogger.shared.write(
            "MAC MICROPHONE KEY_MONITOR phase=fallback result=session_head reason=hid_unavailable"
        )
        if let installed = installTap(level: .session, mode: mode) {
            store(installed, level: .session, mode: mode)
            return true
        }
        AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=failed reason=tap_unavailable")
        return false
    }

    private func installTap(
        level: TapLevel,
        mode: VoiceKeyMode
    ) -> (port: CFMachPort, source: CFRunLoopSource)? {
        guard let port = CGEvent.tapCreate(
            tap: level.location,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: macMicrophoneVoiceKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=failed reason=tap_create_failed tap=\(level.rawValue)"
            )
            return nil
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            EventTapPort.release(port: port, source: nil)
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=failed reason=run_loop_source_failed tap=\(level.rawValue)"
            )
            return nil
        }
        guard EventTapPort.activate(port: port, source: source) else {
            EventTapPort.release(port: port, source: source)
            AppLogger.shared.write(
                "MAC MICROPHONE KEY_MONITOR phase=failed reason=tap_activation_failed tap=\(level.rawValue)"
            )
            return nil
        }
        return (port, source)
    }

    private func store(
        _ installed: (port: CFMachPort, source: CFRunLoopSource),
        level: TapLevel,
        mode: VoiceKeyMode
    ) {
        lock.lock()
        port = installed.port
        source = installed.source
        tapLevel = level
        lock.unlock()
        AppLogger.shared.write(
            "MAC MICROPHONE KEY_MONITOR phase=started result=listening " +
                "voice_key=\(mode.rawValue) event_passthrough=true tap=\(level.rawValue)"
        )
    }

    func stop() {
        lock.lock()
        let port = self.port
        let source = self.source
        let tapLevel = self.tapLevel?.rawValue ?? "unknown"
        self.port = nil
        self.source = nil
        self.tapLevel = nil
        generation &+= 1
        lock.unlock()
        if port != nil || source != nil { EventTapPort.release(port: port, source: source) }
        if port != nil {
            AppLogger.shared.write("MAC MICROPHONE KEY_MONITOR phase=completed result=stopped tap=\(tapLevel)")
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
