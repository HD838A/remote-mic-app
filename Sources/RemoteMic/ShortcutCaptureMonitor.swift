import AppKit
import CoreGraphics
import Foundation

private func shortcutCaptureEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ShortcutCaptureMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return monitor.handle(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

enum ShortcutCaptureStartFailure: Error, Equatable {
    case accessibilityPermissionRequired
    case eventTapUnavailable
}

final class ShortcutCaptureMonitor {
    typealias CallbackDispatcher = (@escaping () -> Void) -> Void

    private let onCapture: (CustomKeyboardShortcut) -> Void
    private let accessibilityTrusted: () -> Bool
    private let dispatchCallback: CallbackDispatcher
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didCapture = false
    private var pendingStandaloneModifier: StandaloneKeyboardModifier?
    private var sawMultipleStandaloneModifiers = false

    init(
        onCapture: @escaping (CustomKeyboardShortcut) -> Void,
        accessibilityTrusted: @escaping () -> Bool = { KeyboardInjector.isAccessibilityTrusted },
        dispatchCallback: @escaping CallbackDispatcher = {
            DispatchQueue.main.async(execute: $0)
        }
    ) {
        self.onCapture = onCapture
        self.accessibilityTrusted = accessibilityTrusted
        self.dispatchCallback = dispatchCallback
    }

    func start() -> Result<Void, ShortcutCaptureStartFailure> {
        if eventTap != nil { return .success(()) }
        guard accessibilityTrusted() else {
            return .failure(.accessibilityPermissionRequired)
        }

        lock.lock()
        didCapture = false
        pendingStandaloneModifier = nil
        sawMultipleStandaloneModifiers = false
        lock.unlock()

        let context = Unmanaged.passUnretained(self).toOpaque()
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: shortcutCaptureEventTapCallback,
            userInfo: context
        ) else {
            return .failure(.eventTapUnavailable)
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            return .failure(.eventTapUnavailable)
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return .success(())
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker else {
            return false
        }

        if type == .flagsChanged {
            return handleModifierFlagsChanged(event)
        }
        guard type == .keyDown else { return false }

        lock.lock()
        if didCapture {
            lock.unlock()
            return true
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            lock.unlock()
            return true
        }
        guard let nsEvent = NSEvent(cgEvent: event) else {
            lock.unlock()
            return false
        }
        didCapture = true
        pendingStandaloneModifier = nil
        lock.unlock()

        let shortcut = CustomKeyboardShortcut(event: nsEvent)
        let capture = onCapture
        dispatchCallback {
            capture(shortcut)
        }
        return true
    }

    private func handleModifierFlagsChanged(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event),
              let modifier = StandaloneKeyboardModifier.allCases.first(where: {
                  $0.keyCode == nsEvent.keyCode
              })
        else { return false }

        lock.lock()
        if didCapture {
            lock.unlock()
            return true
        }
        if nsEvent.modifierFlags.contains(modifier.modifierFlags) {
            if let pendingStandaloneModifier, pendingStandaloneModifier != modifier {
                sawMultipleStandaloneModifiers = true
            } else if pendingStandaloneModifier == nil {
                pendingStandaloneModifier = modifier
            }
            lock.unlock()
            return true
        }

        let shouldCapture = pendingStandaloneModifier == modifier &&
            !sawMultipleStandaloneModifiers
        if shouldCapture {
            didCapture = true
            pendingStandaloneModifier = nil
        } else if nsEvent.modifierFlags.intersection(
            CustomKeyboardShortcut.supportedModifiers
        ).isEmpty {
            pendingStandaloneModifier = nil
            sawMultipleStandaloneModifiers = false
        }
        lock.unlock()

        guard shouldCapture else { return true }
        let shortcut = modifier.shortcut
        let capture = onCapture
        dispatchCallback {
            capture(shortcut)
        }
        return true
    }

    deinit {
        stop()
    }
}
