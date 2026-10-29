import Foundation

/// 承载 `IOHIDManager` 回调的专用 run loop。
///
/// HID 报告原先调度在主线程 RunLoop 上。界面渲染、设置窗口或音频工作时，
/// 主线程可能排队 200 ms 以上，而 macOS 会在同一时刻就用这份原始报告生成
/// 系统原生音量/媒体事件。这样拦截器还没登记，原生事件已经生效，表现为
/// 自定义动作和系统音量同时发生（Intel 现场实测差值 200–250 ms）。
///
/// 把报告投递放到独立线程后，登记不再依赖主线程是否空闲。解析、界面和动作
/// 执行仍然回到主线程，只有拦截登记留在本线程上执行。
final class HIDReportRunLoop {
    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var keepAliveSource: CFRunLoopSource?

    /// 启动专用线程并返回它的 run loop；重复调用返回同一个实例。
    func start() -> CFRunLoop? {
        lock.lock()
        if let runLoop {
            lock.unlock()
            return runLoop
        }
        lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            // 报告回调要跑到主线程之外，必须让 run loop 在没有其它 source 时
            // 也能驻留：先挂一个空转 source，等 manager 调度上来。
            var context = CFRunLoopSourceContext(
                version: 0,
                info: nil,
                retain: nil,
                release: nil,
                copyDescription: nil,
                equal: nil,
                hash: nil,
                schedule: nil,
                cancel: nil,
                perform: { _ in }
            )
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            if let keepAlive {
                CFRunLoopAddSource(runLoop, keepAlive, .commonModes)
            }
            self.lock.lock()
            self.runLoop = runLoop
            self.keepAliveSource = keepAlive
            self.lock.unlock()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "sayall.hid.reports"
        thread.qualityOfService = .userInteractive
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()

        // 线程没能就绪时不能让调用方无限等待；此时由调用方退回主线程调度。
        let readyInTime = ready.wait(timeout: .now() + 2) == .success

        lock.lock()
        defer { lock.unlock() }
        guard readyInTime else { return nil }
        return runLoop
    }

    func stop() {
        lock.lock()
        let runLoop = self.runLoop
        let keepAlive = self.keepAliveSource
        self.runLoop = nil
        self.keepAliveSource = nil
        self.thread = nil
        lock.unlock()

        guard let runLoop else { return }
        if let keepAlive {
            CFRunLoopRemoveSource(runLoop, keepAlive, .commonModes)
        }
        CFRunLoopStop(runLoop)
    }

    /// 监视器若因异常路径未显式 `stop()` 就释放，专用线程会在空转 source 上
    /// 永久驻留；这里兜住这一条，避免设置页反复重建监视器时累积失控线程。
    deinit { stop() }
}
