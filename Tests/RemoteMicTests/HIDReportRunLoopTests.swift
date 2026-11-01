import Foundation
import Testing
@testable import RemoteMic

@Suite("HID report run loop")
struct HIDReportRunLoopTests {
    @Test func startPublishesARunLoopAndStopReportsTheThreadExited() {
        let reportRunLoop = HIDReportRunLoop()
        #expect(reportRunLoop.start(timeout: 2) != nil)
        // 停止必须能被观察到：线程真正退出才允许返回 `true`，
        // 否则「专用线程是否还在驻留」只能靠日志猜。
        #expect(reportRunLoop.stop(waitTimeout: 2))
    }

    @Test func readyTimeoutCancelsTheWorkerSoRestartStillWorks() {
        let reportRunLoop = HIDReportRunLoop()
        // 0 秒超时必然等不到就绪：此时必须撤销工作线程并返回 nil，
        // 而不是把一条线程留在原地。
        #expect(reportRunLoop.start(timeout: 0) == nil)
        // 撤销之后仍能重新启动，说明超时路径没有留下占住状态的僵尸线程。
        #expect(reportRunLoop.start(timeout: 2) != nil)
        #expect(reportRunLoop.stop(waitTimeout: 2))
    }

    @Test func stoppingAnIdleRunLoopIsSafe() {
        let reportRunLoop = HIDReportRunLoop()
        // 未启动、已停止、重复停止都不应阻塞或崩溃。
        #expect(reportRunLoop.stop(waitTimeout: 0.5))
        #expect(reportRunLoop.start(timeout: 2) != nil)
        #expect(reportRunLoop.stop(waitTimeout: 2))
        #expect(reportRunLoop.stop(waitTimeout: 0.5))
    }
}
