import Foundation

/// 提前登记会话门禁。
///
/// 生产环境中 `KeyboardEventSuppressor` 由多个监视器共享
/// （`ownsEventSuppressor: false`），因此某个监视器 `stop()` 不会关闭拦截器。
/// 一份在 `stop()` 之前读到、还没来得及写入的路由快照，仍可能把提前登记写进
/// 共享拦截器，留下会吞掉实体键盘音量键的陈旧记录。
///
/// 这里用「会话代数」把快照与它所属的会话绑定：主线程开始或结束会话时推进代数，
/// 报告线程带快照回来时在同一把锁内确认代数仍是当前会话，才允许写入。
/// 校验与写入必须处在同一个临界区内，`stop()` 才会被排在写入之后，
/// 而不是插在校验和写入之间。
final class HIDPrearmSession<Payload> {
    struct Ticket {
        fileprivate let generation: UInt64
        let payload: Payload
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false
    private var payload: Payload?

    /// 主线程开启会话。每次开启都推进代数，旧快照因此自动失效。
    func begin(_ payload: Payload) {
        lock.lock()
        generation &+= 1
        active = true
        self.payload = payload
        lock.unlock()
    }

    /// 主线程刷新会话内的路由快照，不推进代数：同一会话里的设备、位置与权限
    /// 变化必须对在途回调继续有效。
    func update(_ payload: Payload) {
        lock.lock()
        if active { self.payload = payload }
        lock.unlock()
    }

    /// 主线程结束会话。此后任何在途快照都不能再登记，也不会读到陈旧副本。
    func end() {
        lock.lock()
        generation &+= 1
        active = false
        payload = nil
        lock.unlock()
    }

    /// 供报告线程读取当前快照与它所属的代数；会话未开启时返回 `nil`。
    func current() -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard active, let payload else { return nil }
        return Ticket(generation: generation, payload: payload)
    }

    /// 在同一临界区内校验代数并执行写入。
    ///
    /// 返回 `false` 表示快照已经过期（会话已结束或已重启），`body` 不会执行。
    @discardableResult
    func perform(_ ticket: Ticket, _ body: (Payload) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active, ticket.generation == generation else { return false }
        body(ticket.payload)
        return true
    }
}
