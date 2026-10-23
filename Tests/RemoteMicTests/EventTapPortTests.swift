import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

/// event tap 端口的释放契约。
///
/// 这里断言的不变量是：一个 tap 端口被释放后必须真正从 WindowServer 的 tap 列表中注销。
/// 只 disable 并摘除 RunLoop source 而不 `CFMachPortInvalidate` 时，端口会残留到进程退出；
/// 遥控器每次重连都会重建 HID 监听，残留量因此随重连次数单调累积。
///
/// 循环用例使用 listen-only tap 与生产代码共用的 `EventTapPort`，因此不需要辅助功能权限，
/// 在 CI 中同样会执行；直接驱动生产监听器的两个用例需要能创建 active tap，缺少权限时跳过。
@Suite("Event tap port lifecycle", .serialized)
struct EventTapPortTests {
    private static let leakCycles = 100

    /// 记录 mach port source 的回调线程（跨线程读写，自带锁）。
    final class MachPortProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks = 0
        private var ranOnMainThread: Bool?

        func record() {
            lock.lock()
            callbacks += 1
            if ranOnMainThread == nil {
                ranOnMainThread = Thread.isMainThread
            }
            lock.unlock()
        }

        var callbackCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return callbacks
        }

        var firstCallbackRanOnMainThread: Bool? {
            lock.lock()
            defer { lock.unlock() }
            return ranOnMainThread
        }

        func waitForCallback(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if callbackCount > 0 { return true }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return callbackCount > 0
        }
    }

    private static func makeTap(options: CGEventTapOptions) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
    }

    /// 探针本身也走生产释放路径，避免为探测能力而泄漏一个端口。
    private static func canCreateTap(options: CGEventTapOptions) -> Bool {
        guard let port = makeTap(options: options) else { return false }
        EventTapPort.release(port: port, source: nil)
        return true
    }

    private static let canCreateListenOnlyTap = canCreateTap(options: .listenOnly)
    private static let canCreateActiveTap = canCreateTap(options: .defaultTap)

    /// 只统计本进程创建的 tap，返回 nil 表示当前环境无法枚举 tap 列表。
    private static func ownTapCount() -> Int? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return 0 }
        var list = [CGEventTapInformation](
            repeating: CGEventTapInformation(),
            count: Int(count)
        )
        var actual: UInt32 = 0
        guard CGGetEventTapList(count, &list, &actual) == .success else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.prefix(Int(actual)).filter { $0.tappingProcess == pid }.count
    }

    @Test(.enabled(if: EventTapPortTests.canCreateListenOnlyTap))
    func releaseInvalidatesThePort() throws {
        let port = try #require(Self.makeTap(options: .listenOnly))

        #expect(CFMachPortIsValid(port))
        EventTapPort.release(port: port, source: nil)
        #expect(!CFMachPortIsValid(port))
    }

    /// 回归点：tap 的 RunLoop source 一旦挂在主 RunLoop 上，主线程任何一次长阻塞都会让
    /// 尚未返回的回调堵住整条系统输入队列（2026-10-24 整机卡死）。
    @Test(.enabled(if: EventTapPortTests.canCreateListenOnlyTap))
    func tapSourceLandsOnTheDedicatedRunLoopInsteadOfMain() throws {
        let port = try #require(Self.makeTap(options: .listenOnly))
        let source = try #require(
            CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        )
        #expect(EventTapPort.activate(port: port, source: source))
        defer { EventTapPort.release(port: port, source: source) }

        let tapRunLoop = try #require(EventTapRunLoop.shared.runLoop)
        #expect(CFRunLoopContainsSource(tapRunLoop, source, .commonModes))
        #expect(!CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
        #expect(!CFEqual(tapRunLoop, CFRunLoopGetMain()))
    }

    /// tap 线程必须真的在跑，否则 `performAndWait` 会退化成超时，而回调永远不会被派发。
    @Test
    func tapRunLoopExecutesBlocksOffTheMainThread() throws {
        let tapRunLoop = try #require(EventTapRunLoop.shared.runLoop)
        #expect(!CFEqual(tapRunLoop, CFRunLoopGetMain()))

        var observedOnMainThread: Bool?
        let executed = EventTapRunLoop.shared.performAndWait {
            observedOnMainThread = Thread.isMainThread
        }
        #expect(executed)
        #expect(observedOnMainThread == false)
    }

    /// event tap 的投递本质上是「mach port source 被 RunLoop 服务」。
    ///
    /// 这里用 `CFMessagePort`（同为 mach port source）搭一条安全的替代链路：只在本进程内
    /// 发一条消息，不注入任何真实输入。若这条 RunLoop 不服务 mach port source，说明把 tap
    /// 挂上去也只是「端口在、回调不来」，属于表面修复。
    @Test
    func tapRunLoopServicesMachPortSourcesOffTheMainThread() throws {
        let tapRunLoop = try #require(EventTapRunLoop.shared.runLoop)
        let probe = MachPortProbe()
        let portName = "SayAll.EventTapRunLoopTest.\(UUID().uuidString)" as CFString

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(probe).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let localPort = try #require(CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            portName,
            { _, _, _, info in
                guard let info else { return nil }
                Unmanaged<MachPortProbe>.fromOpaque(info).takeUnretainedValue().record()
                return nil
            },
            &context,
            nil
        ))
        let source = try #require(
            CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0)
        )
        CFRunLoopAddSource(tapRunLoop, source, .commonModes)
        CFRunLoopWakeUp(tapRunLoop)
        defer {
            CFRunLoopRemoveSource(tapRunLoop, source, .commonModes)
            CFMessagePortInvalidate(localPort)
        }

        let remotePort = try #require(CFMessagePortCreateRemote(kCFAllocatorDefault, portName))
        defer { CFMessagePortInvalidate(remotePort) }

        #expect(CFMessagePortSendRequest(remotePort, 1, nil, 1, 1, nil, nil) == kCFMessagePortSuccess)
        #expect(probe.waitForCallback(timeout: 3))
        #expect(probe.firstCallbackRanOnMainThread == false)
    }

    @Test(.enabled(if: EventTapPortTests.canCreateListenOnlyTap))
    func repeatedActivateReleaseCyclesDoNotAccumulateTaps() throws {
        let before = try #require(Self.ownTapCount())

        for _ in 0..<Self.leakCycles {
            let port = try #require(Self.makeTap(options: .listenOnly))
            let source = try #require(
                CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            )
            EventTapPort.activate(port: port, source: source)
            EventTapPort.release(port: port, source: source)
        }

        #expect(Self.ownTapCount() == before)
    }

    @Test(.enabled(if: EventTapPortTests.canCreateActiveTap))
    func keyboardEventSuppressorDoesNotAccumulateTaps() throws {
        let suppressor = KeyboardEventSuppressor()
        let before = try #require(Self.ownTapCount())

        for _ in 0..<Self.leakCycles {
            guard suppressor.start() else {
                Issue.record("Expected the suppressor to create an event tap")
                return
            }
            suppressor.stop()
        }

        #expect(Self.ownTapCount() == before)
    }

    @Test(.enabled(if: EventTapPortTests.canCreateActiveTap))
    func shortcutCaptureMonitorDoesNotAccumulateTaps() throws {
        let monitor = ShortcutCaptureMonitor(
            onCapture: { _ in },
            dispatchCallback: { $0() }
        )
        let before = try #require(Self.ownTapCount())

        for _ in 0..<Self.leakCycles {
            guard case .success = monitor.start() else {
                Issue.record("Expected the capture monitor to create an event tap")
                return
            }
            monitor.stop()
        }

        #expect(Self.ownTapCount() == before)
    }
}
