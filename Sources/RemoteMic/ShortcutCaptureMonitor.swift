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
    static let captureEventMask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
        CGEventMask(1 << CGEventType.flagsChanged.rawValue)

    private let makeShortcut: (NSEvent) -> CustomKeyboardShortcut
    private let onCapture: (CustomKeyboardShortcut) -> Void
    private let accessibilityTrusted: () -> Bool
    private let dispatchCallback: CallbackDispatcher
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Keeps the callback's `userInfo` object alive for the tap lifetime.
    private var tapOwner: Unmanaged<ShortcutCaptureMonitor>?
    private var didCapture = false
    private var pressedModifierKeyCodes: Set<UInt16> = []
    private var standaloneModifierCandidate: StandaloneKeyboardModifier?
    private var modifierChordDetected = false

    init(
        onCapture: @escaping (CustomKeyboardShortcut) -> Void,
        makeShortcut: @escaping (NSEvent) -> CustomKeyboardShortcut = { CustomKeyboardShortcut(event: $0) },
        accessibilityTrusted: @escaping () -> Bool = { KeyboardInjector.isAccessibilityTrusted },
        dispatchCallback: @escaping CallbackDispatcher = {
            DispatchQueue.main.async(execute: $0)
        },
        logger: @escaping (String) -> Void = AppLogger.shared.write
    ) {
        self.makeShortcut = makeShortcut
        self.onCapture = onCapture
        self.accessibilityTrusted = accessibilityTrusted
        self.dispatchCallback = dispatchCallback
        self.logger = logger
    }

    func start() -> Result<Void, ShortcutCaptureStartFailure> {
        lock.lock()
        let alreadyStarted = eventTap != nil
        lock.unlock()
        if alreadyStarted { return .success(()) }
        guard accessibilityTrusted() else {
            return .failure(.accessibilityPermissionRequired)
        }

        lock.lock()
        didCapture = false
        pressedModifierKeyCodes.removeAll()
        standaloneModifierCandidate = nil
        modifierChordDetected = false
        lock.unlock()

        let owner = Unmanaged.passRetained(self)
        let context = owner.toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.captureEventMask,
            callback: shortcutCaptureEventTapCallback,
            userInfo: context
        ) else {
            owner.release()
            return .failure(.eventTapUnavailable)
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            // tapCreate 成功即已在 WindowServer 侧登记端口；此处失败若不释放端口，
            // 该 tap 会残留到进程退出，必须与 stop() 走同一条清理路径。
            let drained = EventTapPort.release(port: eventTap, source: nil)
            if drained {
                owner.release()
            } else {
                logger("SHORTCUT CAPTURE phase=owner_retained action=start_cleanup result=fallback reason=tap_thread_unresponsive")
            }
            return .failure(.eventTapUnavailable)
        }

        guard EventTapPort.activate(port: eventTap, source: runLoopSource) else {
            // 端口已在 WindowServer 侧登记，但没能接入 tap 线程：按启动失败处理并
            // 走同一条清理路径。绝不能留下一个已 enable 却无人承接的 tap。
            let drained = EventTapPort.release(port: eventTap, source: runLoopSource)
            if drained {
                owner.release()
            } else {
                logger("SHORTCUT CAPTURE phase=owner_retained action=start_cleanup result=fallback reason=tap_thread_unresponsive")
            }
            return .failure(.eventTapUnavailable)
        }
        lock.lock()
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        self.tapOwner = owner
        lock.unlock()
        logger("SHORTCUT CAPTURE phase=started result=listening source=session_tap")
        return .success(())
    }

    func stop() {
        // 回调跑在 tap 专用线程上，端口引用由主线程写入，必须加锁交接。
        lock.lock()
        let wasRunning = eventTap != nil
        let port = eventTap
        let source = runLoopSource
        let owner = tapOwner
        eventTap = nil
        runLoopSource = nil
        tapOwner = nil
        lock.unlock()
        let drained = EventTapPort.release(port: port, source: source)
        if drained {
            owner?.release()
        } else if owner != nil {
            // The tap thread may still be in a callback. Keep the owner alive;
            // the port is invalid, so this is a bounded leak instead of a crash.
            logger("SHORTCUT CAPTURE phase=stop_deferred result=owner_retained reason=tap_thread_unresponsive")
        }
        if wasRunning {
            logger("SHORTCUT CAPTURE phase=stopped result=inactive source=session_tap")
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 本回调在 tap 专用线程上执行，端口引用由主线程写入，必须加锁读取。
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }
        guard type == .keyDown || type == .flagsChanged else { return false }
        guard event.getIntegerValueField(.eventSourceUserData) != KeyboardInjector.syntheticEventMarker else {
            return false
        }

        if type == .flagsChanged {
            return handleModifierFlagsChanged(event)
        }

        lock.lock()
        if didCapture {
            lock.unlock()
            return true
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            lock.unlock()
            return true
        }
        guard let capturedEvent = event.copy() else {
            lock.unlock()
            return false
        }
        didCapture = true
        pressedModifierKeyCodes.removeAll()
        standaloneModifierCandidate = nil
        modifierChordDetected = false
        lock.unlock()

        let makeShortcut = self.makeShortcut
        let capture = onCapture
        let logger = self.logger
        // Character lookup can enter HIToolbox's main-queue-only input-source APIs.
        // Keep the tap nonblocking and resolve the captured snapshot in the UI callback.
        dispatchCallback {
            guard let nsEvent = NSEvent(cgEvent: capturedEvent) else {
                logger("SHORTCUT CAPTURE phase=failed reason=event_conversion_failed")
                return
            }
            let shortcut = makeShortcut(nsEvent)
            let modifierCount = shortcut.modifierFlags
                .intersection(CustomKeyboardShortcut.supportedModifiers)
                .rawValue.nonzeroBitCount
            logger(
                "SHORTCUT CAPTURE phase=resolved result=captured " +
                    "main_thread=\(Thread.isMainThread) " +
                    "has_function=\(shortcut.modifierFlags.contains(.function)) " +
                    "modifier_count=\(modifierCount)"
            )
            capture(shortcut)
        }
        return true
    }

    private func handleModifierFlagsChanged(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let modifier = StandaloneKeyboardModifier.allCases.first(where: {
            $0.keyCode == keyCode
        }) else {
            return false
        }

        lock.lock()
        if didCapture {
            lock.unlock()
            return true
        }

        if pressedModifierKeyCodes.contains(keyCode) {
            pressedModifierKeyCodes.remove(keyCode)
            let shouldCapture = pressedModifierKeyCodes.isEmpty &&
                !modifierChordDetected &&
                standaloneModifierCandidate == modifier
            if pressedModifierKeyCodes.isEmpty {
                standaloneModifierCandidate = nil
                modifierChordDetected = false
            }
            if shouldCapture {
                didCapture = true
            }
            lock.unlock()

            if shouldCapture {
                let capture = onCapture
                let shortcut = modifier.shortcut
                dispatchCallback {
                    capture(shortcut)
                }
            }
            return true
        }

        pressedModifierKeyCodes.insert(keyCode)
        if pressedModifierKeyCodes.count == 1 && !modifierChordDetected {
            standaloneModifierCandidate = modifier
        } else {
            standaloneModifierCandidate = nil
            modifierChordDetected = true
        }
        lock.unlock()
        return true
    }

    deinit {
        stop()
    }
}
