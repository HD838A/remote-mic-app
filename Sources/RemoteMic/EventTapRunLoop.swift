import CoreGraphics
import Foundation

/// 承载 event tap 回调的专用 RunLoop。
///
/// ## 为什么不能挂在主线程
///
/// active tap（`.defaultTap`）的回调**必须返回**，系统才会把这个输入事件继续派发给其它
/// 进程。回调在哪个 RunLoop 上派发，就在哪条线程上执行。挂在主线程上的后果是：主线程只要
/// 出现一次长阻塞（同步 TCC 查询、磁盘 IO、任何同步等待），整条系统输入队列都会停在我们
/// 尚未返回的回调里——光标还能动（由 WindowServer 独立绘制），但所有 app 都收不到输入，
/// 整机表现为「死机」。2026-10-24 在开机引导页关闭本 app 的蓝牙权限时实际发生，
/// 见 `Bugs/2026-10-24-event-tap-blocks-system-input.md`。
///
/// 把两条 tap 都挂到本类型的专用线程后，主线程再慢也只影响本 app 自己的界面刷新，
/// 系统输入派发不再受牵连。
///
/// 线程安全：`storedRunLoop` 由 `lock` 保护，跨线程操作一律经 `performAndWait` 投递到
/// 那条 RunLoop 上执行，因此对外可以安全地被任意线程共享。
final class EventTapRunLoop: @unchecked Sendable {
    static let shared = EventTapRunLoop()

    /// 保活定时器的间隔。RunLoop 只有在至少持有一个 source 或 timer 时才会停在
    /// `CFRunLoopRun()` 里，否则会立刻返回。取一个远到不会真的触发的值即可。
    private static let keepAliveInterval: CFTimeInterval = 60 * 60 * 24 * 365 * 100

    /// 调用方等待 tap 线程的默认预算。
    ///
    /// 正常路径是微秒级（一次 RunLoop 唤醒）；超时只可能来自 tap 线程自身异常。
    /// 此时宁可放弃本次操作并留日志，也不要把调用方一起拖住——那正是本类型要避免的事。
    static let defaultTimeout: DispatchTimeInterval = .milliseconds(500)

    private let lock = NSLock()
    private var storedRunLoop: CFRunLoop?

    /// 供测试断言：tap 线程持有的 RunLoop 与主 RunLoop 不是同一个。
    var runLoop: CFRunLoop? {
        lock.lock()
        defer { lock.unlock() }
        return storedRunLoop
    }

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let current = CFRunLoopGetCurrent()
            let keepAlive = CFRunLoopTimerCreate(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + Self.keepAliveInterval,
                Self.keepAliveInterval,
                0,
                0,
                { _, _ in },
                nil
            )
            CFRunLoopAddTimer(current, keepAlive, .commonModes)

            lock.lock()
            storedRunLoop = current
            lock.unlock()
            ready.signal()

            CFRunLoopRun()
        }
        thread.name = "SayAll.EventTap"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        thread.start()
        // 首次使用必须拿到已就绪的 RunLoop，否则 `activate` 会静默失败。
        _ = ready.wait(timeout: .now() + 5)
    }

    /// 在 tap 线程上同步执行一段操作。
    ///
    /// 回调只在这条线程上跑，所以把「摘除 source + invalidate 端口」放进这里执行，
    /// 就与正在执行的回调天然串行——避免端口在回调仍在栈上时被另一条线程作废。
    ///
    /// 已经在 tap 线程上时直接就地执行，不经过 RunLoop 唤醒，否则会自锁。
    @discardableResult
    func performAndWait(
        timeout: DispatchTimeInterval = EventTapRunLoop.defaultTimeout,
        _ body: @escaping () -> Void
    ) -> Bool {
        guard let target = runLoop else { return false }
        if CFRunLoopGetCurrent() === target {
            body()
            return true
        }

        let finished = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(target, CFRunLoopMode.commonModes.rawValue) {
            body()
            finished.signal()
        }
        CFRunLoopWakeUp(target)
        return finished.wait(timeout: .now() + timeout) == .success
    }
}
