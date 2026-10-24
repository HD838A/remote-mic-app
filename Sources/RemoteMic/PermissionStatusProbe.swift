import CoreBluetooth
import Foundation

/// 权限状态的异步探测。
///
/// 三个查询都是**同步 IPC 到 tccd**：`CBManager.authorization`、`IOHIDCheckAccess`
/// （`HIDRemoteMonitor.isInputMonitoringGranted`）与 `AXIsProcessTrusted`
/// （`KeyboardInjector.isAccessibilityTrusted`）。用户在系统设置里改动权限的那一瞬间，
/// tccd 要先结算授权再回复，这个往返可以长达数秒。原先引导页把它们放在每秒一次的
/// 定时器里直接跑在主线程上——2026-10-24 的整机卡死就发生在「打开系统蓝牙 + 关闭本 app
/// 蓝牙权限」的那一刻，见 `Bugs/2026-10-24-event-tap-blocks-system-input.md`。
///
/// 约定：
/// - 查询固定在本类型的串行队列上执行，不占用主线程；
/// - 结果回到主线程再交付，调用方可以安全地写 `@State`；
/// - 同一时刻只允许一次查询在飞，飞行期间到达的请求合并成一次重跑。否则 tccd 卡住时
///   1 Hz 的定时器会堆出无限多个排队查询，权限恢复后还要逐条补跑。
final class PermissionStatusProbe {
    struct Snapshot: Equatable {
        var bluetooth: CBManagerAuthorization
        var inputMonitoring: Bool
        var accessibility: Bool
    }

    typealias Query = () -> Snapshot

    static let shared = PermissionStatusProbe()

    private let queue: DispatchQueue
    private let query: Query
    private let lock = NSLock()
    private var isQuerying = false
    private var waiting: [(Snapshot) -> Void] = []

    init(
        label: String = "sayall.permission-status-probe",
        query: @escaping Query = PermissionStatusProbe.systemQuery
    ) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.query = query
    }

    /// 生产环境的三个查询，全部是同步 IPC，只允许在本类型的队列上调用。
    static func systemQuery() -> Snapshot {
        Snapshot(
            bluetooth: CBManager.authorization,
            inputMonitoring: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibility: KeyboardInjector.isAccessibilityTrusted
        )
    }

    /// 请求一次权限快照，`completion` 一定在主线程回调。
    func fetch(_ completion: @escaping (Snapshot) -> Void) {
        let shouldStart: Bool
        lock.lock()
        waiting.append(completion)
        shouldStart = !isQuerying
        if shouldStart {
            isQuerying = true
        }
        lock.unlock()

        guard shouldStart else { return }
        queue.async { [self] in
            drain()
        }
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = waiting
            waiting.removeAll()
            if batch.isEmpty {
                isQuerying = false
                lock.unlock()
                return
            }
            lock.unlock()

            let snapshot = query()
            DispatchQueue.main.async {
                batch.forEach { $0(snapshot) }
            }
        }
    }
}
