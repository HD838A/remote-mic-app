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
    /// 启动代数：每次 `start()` 递增。迟到的旧线程凭自己的代数认领状态，
    /// 不能清掉新会话登记中的 run loop。
    private var generation: UInt64 = 0
    /// 取消标志。未启动时视为已取消：只有 `start()` 成功才会把它放下，
    /// 这样「就绪超时」与「已停止」走同一条撤销路径，都不会留下驻留线程。
    private var cancelled = true
    /// 当前工作线程的退出信号，供 `stop(waitTimeout:)` 有界等待。
    private var exitSignal: DispatchSemaphore?

    /// 启动专用线程并返回它的 run loop；重复调用返回同一个实例。
    ///
    /// 线程在超时内没能就绪时必须把这条线程撤销掉再返回 `nil`，否则调用方
    /// 退回主线程之后，那条线程仍会在空转 source 上驻留到进程退出。
    func start(timeout: TimeInterval = 2) -> CFRunLoop? {
        lock.lock()
        if let runLoop, !cancelled {
            lock.unlock()
            return runLoop
        }
        generation &+= 1
        let startGeneration = generation
        cancelled = false
        let exitSignal = DispatchSemaphore(value: 0)
        self.exitSignal = exitSignal
        lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        // 工作线程只在校验和发布阶段访问 `self`，进入 `CFRunLoopRun()` 之后不再
        // 强持有：否则监视器释放后 `deinit { stop() }` 永远轮不到，线程会驻留。
        // 退出信号按线程捕获，迟到的旧线程不会误报新线程已退出。
        let thread = Thread { [weak self] in
            guard let runLoop = CFRunLoopGetCurrent() else {
                ready.signal()
                exitSignal.signal()
                return
            }
            let keepAlive = Self.makeKeepAliveSource()
            guard self?.publish(runLoop: runLoop, keepAlive: keepAlive, generation: startGeneration) == true else {
                if let keepAlive { CFRunLoopRemoveSource(runLoop, keepAlive, .commonModes) }
                ready.signal()
                exitSignal.signal()
                return
            }
            ready.signal()
            CFRunLoopRun()
            self?.clearAfterExit(generation: startGeneration)
            exitSignal.signal()
        }
        thread.name = "sayall.hid.reports"
        thread.qualityOfService = QualityOfService.userInteractive
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()

        // 线程没能就绪时不能让调用方无限等待，也不能把这条线程留在原地：
        // 先撤销工作线程，再让调用方退回主线程调度。
        guard ready.wait(timeout: .now() + timeout) == .success else {
            _ = stop(waitTimeout: 0.5)
            return nil
        }
        lock.lock()
        let publishedRunLoop = cancelled ? nil : runLoop
        lock.unlock()
        if publishedRunLoop == nil {
            _ = stop(waitTimeout: 0.5)
        }
        return publishedRunLoop
    }

    /// 停止专用线程，并在超时内等待它真正退出。
    ///
    /// 返回 `true` 表示线程已退出。停止结果必须能被观察到，否则「线程是否还在
    /// 驻留」只能靠日志猜测。
    @discardableResult
    func stop(waitTimeout: TimeInterval = 1) -> Bool {
        lock.lock()
        cancelled = true
        generation &+= 1
        let runLoop = self.runLoop
        let keepAlive = self.keepAliveSource
        self.runLoop = nil
        self.keepAliveSource = nil
        let exitSignal = self.exitSignal
        self.exitSignal = nil
        self.thread = nil
        lock.unlock()

        guard let runLoop else {
            // 线程还没发布 run loop：它的发布检查会看到 cancelled 后自行退出。
            return exitSignal.map { $0.wait(timeout: .now() + waitTimeout) == .success } ?? true
        }
        if let keepAlive {
            CFRunLoopRemoveSource(runLoop, keepAlive, .commonModes)
        }
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        // 线程可能刚好停在 `CFRunLoopRun()` 之前，此时 `CFRunLoopStop` 会丢失；
        // 补一次 perform 让它在进入循环后立刻停下，避免停止后仍然驻留。
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        return exitSignal.map { $0.wait(timeout: .now() + waitTimeout) == .success } ?? true
    }

    /// 监视器若因异常路径未显式 `stop()` 就释放，专用线程会驻留；
    /// 这里兜住这一条，避免设置页反复重建监视器时累积失控线程。
    deinit { _ = stop(waitTimeout: 0.5) }

    private func publish(
        runLoop: CFRunLoop,
        keepAlive: CFRunLoopSource?,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, generation == self.generation else { return false }
        self.runLoop = runLoop
        self.keepAliveSource = keepAlive
        if let keepAlive {
            CFRunLoopAddSource(runLoop, keepAlive, .commonModes)
        }
        return true
    }

    private func clearAfterExit(generation: UInt64) {
        lock.lock()
        if generation == self.generation {
            runLoop = nil
            keepAliveSource = nil
            thread = nil
        }
        lock.unlock()
    }

    /// 报告回调要跑到主线程之外，必须让 run loop 在没有其它 source 时也能驻留：
    /// 先挂一个空转 source，等 manager 调度上来。
    private static func makeKeepAliveSource() -> CFRunLoopSource? {
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
        return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
    }
}
