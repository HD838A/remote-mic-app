import Foundation

/// 进程级共享的权限轮询。
///
/// 输入监控与辅助功能权限是**进程级全局状态**（`HIDRemoteMonitor.isInputMonitoringGranted`
/// 与 `KeyboardInjector.isAccessibilityTrusted` 都是静态属性），与 `HIDRemoteMonitor`
/// 实例数无关。但轮询原本位于 monitor 实例内部，而实例是按设备创建的
/// （`BridgeAppModel.hidMonitors` 每个设备一个实例，另有 `discoveryHIDMonitor`），
/// 于是 N 个存活实例会各自创建一个 1 Hz 定时器，使 `IOHIDCheckAccess` 每秒被调用 N 次。
/// 每次 `IOHIDCheckAccess` 都会真实穿透到 `tccd` 并产生一次 TCC IPC，因此这部分
/// 开销随实例数线性增长，而且完全冗余。
///
/// 本类型把轮询收敛为单一来源：无论多少订阅者，每秒只执行一次检查。
/// 检查节奏与权限撤销的检测延迟均与原实现一致。
///
/// 所有方法都必须在主队列调用：`DispatchHIDRemoteScheduler` 默认队列为 `.main`，
/// 且 `HIDRemoteMonitor` 的生命周期也都发生在主线程。
final class HIDPermissionPoll {
    static let shared = HIDPermissionPoll()

    private let scheduler: HIDRemoteScheduling
    private var subscribers: [UUID: () -> Void] = [:]
    private var task: HIDRemoteScheduledTask?

    init(scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler()) {
        self.scheduler = scheduler
    }

    /// 订阅每秒一次的权限检查。
    ///
    /// - Returns: 用于 `unsubscribe(_:)` 的 token。
    @discardableResult
    func subscribe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        if task == nil {
            startPolling()
        }
        return token
    }

    /// 取消订阅。最后一个订阅者离开时停止定时器，避免空转。
    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)
        guard subscribers.isEmpty else { return }
        task?.cancel()
        task = nil
    }

    private func startPolling() {
        task = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.permissionPollMilliseconds,
            repeatingEveryMilliseconds: HIDRemoteTiming.permissionPollMilliseconds
        ) { [weak self] in
            guard let self else { return }
            // 取快照：回调可能在执行过程中订阅或取消订阅。
            let handlers = Array(self.subscribers.values)
            for handler in handlers {
                handler()
            }
        }
    }
}
