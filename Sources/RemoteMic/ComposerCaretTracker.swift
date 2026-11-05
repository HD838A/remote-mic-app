import ApplicationServices
import AppKit
import Foundation

/// 记住每个目标 App 输入框最近的光标位置。
///
/// 只保存选区偏移（`AXSelectedTextRange`），从不读取或保存输入内容。
/// 键是目标 App 的 Bundle ID：同一 App 的对话输入框共享一份记忆；
/// 无线麦重启后记忆清空，按「默认到文字末尾」处理。
final class ComposerCaretStore: @unchecked Sendable {
    static let shared = ComposerCaretStore()

    private let lock = NSLock()
    private var ranges: [String: CFRange] = [:]

    func remember(_ range: CFRange, forKey key: String) {
        guard key.isEmpty == false, range.location >= 0, range.length >= 0 else { return }
        lock.lock()
        ranges[key] = range
        lock.unlock()
    }

    func rememberedRange(forKey key: String) -> CFRange? {
        lock.lock()
        defer { lock.unlock() }
        return ranges[key]
    }
}

/// 目标输入框聚焦期间跟踪选区变化。
///
/// 通过 `AXObserver` 订阅 `AXSelectedTextRangeChanged` 通知，把每次偏移变化
/// 写进 `ComposerCaretStore`，这样用户手动移动过光标后，下次“打开 / 聚焦
/// 输入框”可以恢复到原位。通知回调挂在 `EventTapRunLoop` 的专用线程上，
/// 回调体只做一次偏移读取和内存写入。
final class ComposerCaretObserver: @unchecked Sendable {
    static let shared = ComposerCaretObserver()
    private static let notification = "AXSelectedTextRangeChanged"

    private let lock = NSLock()
    private var observer: AXObserver?
    private var observedSource: CFRunLoopSource?
    private var processIdentifier: pid_t = 0
    private var observedElement: AXUIElement?
    private var key = ""
    private var retainedRefcon: UnsafeMutableRawPointer?

    private static let callback: AXObserverCallback = { _, element, _, refcon in
        guard let refcon else { return }
        let tracker = Unmanaged<ComposerCaretObserver>.fromOpaque(refcon).takeUnretainedValue()
        tracker.recordSelection(from: element)
    }

    /// 观察器回调的上下文指针。单例与进程同生命周期，只需保留一次。
    private func retainedContext() -> UnsafeMutableRawPointer {
        lock.lock()
        if retainedRefcon == nil {
            retainedRefcon = Unmanaged.passRetained(self).toOpaque()
        }
        let pointer = retainedRefcon!
        lock.unlock()
        return pointer
    }

    /// 读取被观察元素当前的选区偏移并记忆。只在元素聚焦时可靠。
    func recordSelection(from element: AXUIElement) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        lock.lock()
        let currentKey = key
        lock.unlock()
        ComposerCaretStore.shared.remember(range, forKey: currentKey)
    }

    /// 让观察器跟踪给定输入框。同一个 App 同一个元素重复调用是幂等的；
    /// App 或元素变化时先摘除旧通知与旧 RunLoop source 再重新注册。
    func beginObserving(element: AXUIElement, processIdentifier: pid_t, key: String) {
        lock.lock()
        if processIdentifier == self.processIdentifier,
           key == self.key,
           let current = observedElement, CFEqual(current, element) {
            lock.unlock()
            return
        }
        let previousObserver = observer
        let previousElement = observedElement
        let previousSource = observedSource
        observer = nil
        observedElement = nil
        observedSource = nil
        self.key = key
        self.processIdentifier = processIdentifier
        lock.unlock()

        if let previousObserver, let previousElement, let previousSource {
            EventTapRunLoop.shared.performAndWait {
                AXObserverRemoveNotification(previousObserver, previousElement, Self.notification as CFString)
                CFRunLoopSourceInvalidate(previousSource)
                if let runLoop = EventTapRunLoop.shared.runLoop {
                    CFRunLoopRemoveSource(runLoop, previousSource, .commonModes)
                }
            }
        }

        var newObserver: AXObserver?
        guard AXObserverCreate(processIdentifier, Self.callback, &newObserver) == .success,
              let newObserver else {
            AppLogger.shared.write("APP FOCUS caret observer result=create_failed")
            return
        }
        guard AXObserverAddNotification(newObserver, element, Self.notification as CFString, retainedContext()) == .success else {
            AppLogger.shared.write("APP FOCUS caret observer result=add_failed")
            return
        }
        let source = AXObserverGetRunLoopSource(newObserver)
        var scheduled = false
        EventTapRunLoop.shared.performAndWait {
            if let runLoop = EventTapRunLoop.shared.runLoop {
                CFRunLoopAddSource(runLoop, source, .commonModes)
                scheduled = true
            }
        }
        guard scheduled else {
            AppLogger.shared.write("APP FOCUS caret observer result=schedule_failed")
            return
        }
        lock.lock()
        observer = newObserver
        observedElement = element
        observedSource = source
        self.processIdentifier = processIdentifier
        self.key = key
        lock.unlock()
        AppLogger.shared.write("APP FOCUS caret observer result=observing")
    }
}
