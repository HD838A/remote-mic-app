import CoreGraphics
import Foundation

/// event tap 端口的接入与释放。
///
/// 释放必须包含 `CFMachPortInvalidate`：只调用 `CGEvent.tapEnable(enable: false)` 并摘除
/// RunLoop source 不会把端口从 WindowServer 的 tap 列表中注销，端口会一直残留到进程
/// 退出。遥控器每次重连都会重建 HID 监听，因此残留量随重连次数单调累积，最终使每个
/// 输入事件都要流经上千个已禁用 tap，表现为全系统界面卡顿。
///
/// 两处 tap 创建点（`KeyboardEventSuppressor` 与 `ShortcutCaptureMonitor`）共用本类型，
/// 避免同一释放逻辑被分别实现后再次分叉。
enum EventTapPort {
    /// 把已创建的 tap 端口接入主 RunLoop 并启用。
    static func activate(port: CFMachPort, source: CFRunLoopSource) {
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// 释放 tap 端口：先摘除 RunLoop source，再 disable，最后 invalidate。
    ///
    /// `port` 为 nil 时只摘除 source；`source` 为 nil 时只处理端口，用于 tap 创建
    /// 中途失败、端口已登记但尚未接入 RunLoop 的情形。
    static func release(port: CFMachPort?, source: CFRunLoopSource?) {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
    }
}
