import CoreBluetooth
import Foundation
import Testing
@testable import RemoteMic

@Suite("ATVV command transmission")
struct ATVVCommandTransmissionTests {
    // `.withResponse` 由系统排队并在 didWriteValueFor 回调里报告结果，不需要预判队列。
    @Test func withResponseSubmitsEvenWhenQueueIsBusy() {
        #expect(
            ATVVCommandTransmissionPolicy.canSubmit(
                writeType: .withResponse,
                canSendWithoutResponse: false
            )
        )
    }

    @Test func withoutResponseSubmitsWhenQueueIsAvailable() {
        #expect(
            ATVVCommandTransmissionPolicy.canSubmit(
                writeType: .withoutResponse,
                canSendWithoutResponse: true
            )
        )
    }

    // RC003 的 ATVV 发送特征只支持无响应写：队列满时系统会丢弃，必须先拦住。
    @Test func withoutResponseIsRejectedWhenQueueIsFull() {
        #expect(
            !ATVVCommandTransmissionPolicy.canSubmit(
                writeType: .withoutResponse,
                canSendWithoutResponse: false
            )
        )
    }

    @Test func onlyWrittenCountsAsWritten() {
        #expect(ATVVCommandSubmission.written.isWritten)
        #expect(!ATVVCommandSubmission.transmitQueueFull.isWritten)
        #expect(!ATVVCommandSubmission.channelUnavailable.isWritten)
    }

    // 日志检索依赖这三个稳定标记，改名等于让现场排查失去锚点。
    @Test func logTokensAreStable() {
        #expect(ATVVCommandSubmission.written.logToken == "written")
        #expect(ATVVCommandSubmission.transmitQueueFull.logToken == "transmit_queue_full")
        #expect(ATVVCommandSubmission.channelUnavailable.logToken == "channel_unavailable")
    }
}
