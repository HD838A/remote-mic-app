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
    typealias LocalMonitorInstaller = (@escaping (NSEvent) -> NSEvent?) -> Any?
    typealias EventTapCreator = (CGEventMask, UnsafeMutableRawPointer) -> CFMachPort?

    private let onCapture: (CustomKeyboardShortcut) -> Void
    private let accessibilityTrusted: () -> Bool
    private let dispatchCallback: CallbackDispatcher
    private let createEventTap: EventTapCreator
    private let installLocalMonitor: LocalMonitorInstaller
    private let removeLocalMonitor: (Any) -> Void
    private let operationID = String(UUID().uuidString.prefix(8))
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didCapture = false
    private var didDeliver = false
    private var localMonitor: Any?
    private var isStopped = false
    private var captureMode = "none"

    init(
        onCapture: @escaping (CustomKeyboardShortcut) -> Void,
        accessibilityTrusted: @escaping () -> Bool = { KeyboardInjector.isAccessibilityTrusted },
        dispatchCallback: @escaping CallbackDispatcher = {
            DispatchQueue.main.async(execute: $0)
        },
        createEventTap: @escaping EventTapCreator = { mask, context in
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: shortcutCaptureEventTapCallback,
                userInfo: context
            )
        },
        installLocalMonitor: @escaping LocalMonitorInstaller = {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: $0)
        },
        removeLocalMonitor: @escaping (Any) -> Void = NSEvent.removeMonitor
    ) {
        self.onCapture = onCapture
        self.accessibilityTrusted = accessibilityTrusted
        self.dispatchCallback = dispatchCallback
        self.createEventTap = createEventTap
        self.installLocalMonitor = installLocalMonitor
        self.removeLocalMonitor = removeLocalMonitor
    }

    func start() -> Result<Void, ShortcutCaptureStartFailure> {
        if eventTap != nil || localMonitor != nil { return .success(()) }
        log("phase=requested")

        lock.lock()
        didCapture = false
        didDeliver = false
        isStopped = false
        lock.unlock()

        guard accessibilityTrusted() else {
            return startLocalMonitor(reason: .accessibilityPermissionRequired)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let eventTap = createEventTap(eventMask, context) else {
            return startLocalMonitor(reason: .eventTapUnavailable)
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            CFMachPortInvalidate(eventTap)
            return startLocalMonitor(reason: .eventTapUnavailable)
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        captureMode = "global"
        log("phase=started mode=global")
        return .success(())
    }

    private func startLocalMonitor(reason: ShortcutCaptureStartFailure) -> Result<Void, ShortcutCaptureStartFailure> {
        let reasonCode = reason == .accessibilityPermissionRequired
            ? "accessibility_permission_required" : "event_tap_unavailable"
        // Local events belong to this app's foreground window and do not need
        // global monitoring permission. Reserved system shortcuts still use the
        // event tap when available, or the page's standard keyboard picker.
        guard let token = installLocalMonitor({ [weak self] event in
            guard let self, let cgEvent = event.cgEvent else { return event }
            return self.handle(type: .keyDown, event: cgEvent) ? nil : event
        }) else {
            log("phase=failed result=unavailable reason=\(reasonCode)")
            return .failure(reason)
        }
        localMonitor = token
        captureMode = "foreground"
        log("phase=started mode=foreground reason=\(reasonCode) system_shortcuts=unavailable")
        return .success(())
    }

    func stop() {
        lock.lock()
        isStopped = true
        let wasCaptured = didDeliver
        lock.unlock()
        if let localMonitor {
            removeLocalMonitor(localMonitor)
        }
        localMonitor = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        if captureMode != "none", !wasCaptured {
            log("phase=cancelled result=cancelled mode=\(captureMode)")
        }
        captureMode = "none"
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }
        guard type == .keyDown else { return false }
        guard event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker else {
            return false
        }

        lock.lock()
        if isStopped {
            lock.unlock()
            return false
        }
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
        lock.unlock()

        let shortcut = CustomKeyboardShortcut(event: nsEvent)
        dispatchCallback { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cancelled = self.isStopped
            if !cancelled { self.didDeliver = true }
            self.lock.unlock()
            guard !cancelled else { return }
            self.log("phase=completed result=captured mode=\(self.captureMode)")
            self.onCapture(shortcut)
        }
        return true
    }

    deinit {
        stop()
    }

    private func log(_ fields: String) {
        AppLogger.shared.write("SHORTCUT CAPTURE operation_id=\(operationID) \(fields)")
    }
}
