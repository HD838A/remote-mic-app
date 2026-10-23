import CoreGraphics
import Foundation

/// event tap 端口的接入与释放。
///
/// 释放必须包含 `CFMachPortInvalidate`：只调用 `CGEvent.tapEnable(enable: false)` 并摘除
/// RunLoop source 不会把端口从 WindowServer 的 tap 列表中注销，端口会一直残留到进程
/// 退出。遥控器每次重连都会重建 HID 监听，因此残留量随重连次数单调累积，最终使每个
/// 输入事件都要流经上千个已禁用 tap，表现为全系统界面卡顿。
///
/// 接入点不是主 RunLoop，而是 `EventTapRunLoop.shared` 的专用线程：active tap 的回调
/// 未返回时系统输入会整体排队，挂在主线程等于把「本 app 主线程偶尔卡一下」放大成
/// 「整机所有 app 都收不到输入」。
///
/// 两处 tap 创建点（`KeyboardEventSuppressor` 与 `ShortcutCaptureMonitor`）共用本类型，
/// 避免同一释放逻辑被分别实现后再次分叉。
enum EventTapPort {
    /// 把已创建的 tap 端口接入 tap 专用 RunLoop 并启用。
    ///
    /// 返回 `false` 表示 tap 线程未在预算内接住这个 source。此时**不会**启用端口：
    /// 一个已 enable 但没有任何 RunLoop 承接的 tap 只会让事件堆在端口里，把系统输入
    /// 彻底堵死，比不使用 tap 严重得多。调用方应当把这次启动当成失败处理。
    @discardableResult
    static func activate(port: CFMachPort, source: CFRunLoopSource) -> Bool {
        // tapCreate 默认启用端口。等待 source 接入前先停投递。
        CGEvent.tapEnable(tap: port, enable: false)
        let attached = EventTapRunLoop.shared.performAndWait {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        guard attached else {
            AppLogger.shared.write(
                "EVENT TAP phase=failed action=activate result=failed reason=run_loop_timeout"
            )
            return false
        }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// 释放 tap 端口：先停投递，再摘除 RunLoop source，最后 disable 并 invalidate。
    ///
    /// `port` 为 nil 时只摘除 source；`source` 为 nil 时只处理端口，用于 tap 创建
    /// 中途失败、端口已登记但尚未接入 RunLoop 的情形。
    static func release(port: CFMachPort?, source: CFRunLoopSource?) {
        // 这一步在任何线程上都安全，且立刻生效，先把投递停掉。
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }

        let detached = EventTapRunLoop.shared.performAndWait {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            if let port {
                CFMachPortInvalidate(port)
            }
        }
        guard !detached else { return }

        // 兜底：tap 线程没有在预算内响应。端口必须 invalidate，否则会永久残留在
        // WindowServer 的 tap 列表里（本类型开头描述的那条泄漏路径）。宁可承担一次
        // 与回调并发的作废，也不要留下一个永不回收的端口。
        AppLogger.shared.write(
            "EVENT TAP phase=timed_out action=release result=fallback reason=run_loop_timeout"
        )
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
    }
}
