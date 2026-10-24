import AppKit
import Carbon

private func macMicrophoneHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                       _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context, let event else { return OSStatus(eventNotHandledErr) }
    let monitor = Unmanaged<MacMicrophoneShortcut>.fromOpaque(context).takeUnretainedValue()
    return monitor.handle(event)
}

/// Register only an explicitly chosen combination. Bare modifiers are never consumed.
final class MacMicrophoneShortcut {
    var onPress: () -> Void = {}
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var isPressed = false
    private static let signature: OSType = 0x53414D43

    func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
            nil, &identifier) == noErr,
            identifier.signature == Self.signature, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { isPressed = false }
        else if !isPressed { isPressed = true; onPress() }
        return noErr
    }

    static func supports(_ shortcut: CustomKeyboardShortcut) -> Bool {
        shortcut.isMacMicrophoneCombination
    }

    @discardableResult
    func register(_ shortcut: CustomKeyboardShortcut?) -> Bool {
        stop()
        guard let shortcut else { return true }
        guard Self.supports(shortcut) else { return false }
        var specs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        guard InstallEventHandler(GetApplicationEventTarget(), macMicrophoneHotKeyHandler, 2, &specs,
            Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr else { return false }
        var modifiers: UInt32 = 0
        if shortcut.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if shortcut.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, id,
            GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { stop() }
        else { isPressed = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(shortcut.keyCode)) }
        AppLogger.shared.write("MAC MICROPHONE SHORTCUT phase=completed result=\(result == noErr ? "registered" : "unavailable") code=\(result)")
        return result == noErr
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        isPressed = false
    }

    deinit { stop() }
}
