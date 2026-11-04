import AppKit
import Foundation

/// 自己进程 / 自己窗口的 AX 目标过滤。
///
/// 同进程 AX 请求不跨进程，直接在调用线程上执行 AppKit 的 AX 应答；应答会向
/// `NSHostingView` 索取 accessibility 子节点，从而进入 SwiftUI 的 view graph。
/// 主线程此时若正持有 `_MovableLock`（视图更新事务内），两边互等就是永久卡死
/// —— 与 #678「AX 查询自身」同一类问题。
///
/// 所有「可能查到无线麦自己」的 AX 入口都要先过这里：聚焦、转录快照、语音目标、
/// 翻页注入、Siri 指针 hover。宿主自己的窗口不需要 AX：这些能力的目标都是**别的**
/// App，对自家窗口做 AX 既没有语义，也只会踩上面的死锁。
enum AXSelfTargetPolicy {
    static func isOwnProcess(
        _ processIdentifier: pid_t,
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        processIdentifier == ownProcessIdentifier
    }

    static func isOwnFrontmostApplication(
        _ application: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) -> Bool {
        guard let application else { return false }
        return isOwnProcess(application.processIdentifier)
    }

    static func isPointInsideOwnWindow(
        _ point: NSPoint,
        windowFrames: [NSRect]
    ) -> Bool {
        windowFrames.contains { $0.contains(point) }
    }
}
