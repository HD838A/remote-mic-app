import Foundation
import Testing
@testable import RemoteMic

struct G9N9NHIDReportTests {
    @Test(arguments: [UInt8(0x52), 0x51, 0x50, 0x4F, 0x28, 0x29])
    func bootKeyboardDecodesDirectionsAndSelect(_ key: UInt8) {
        let data = Data([0, 0, key, 0, 0, 0, 0, 0])
        #expect(G9N9NHIDReport.usages(reportID: 1, data: data) == [.init(page: 7, usage: UInt32(key))])
        #expect(G9N9NHIDReport.usages(reportID: 1, data: Data([1]) + data)
            == [.init(page: 7, usage: UInt32(key))])
    }

    @Test func payloadThatStartsWithReportIDIsNotMistakenForAPrefix() {
        #expect(G9N9NHIDReport.usages(reportID: 1, data: Data([1, 0, 0x28, 0, 0, 0, 0, 0]))
            == [.init(page: 7, usage: 0xE0), .init(page: 7, usage: 0x28)])
    }

    @Test func inBandReportIDsStillKeepKeyboardAndConsumerStateSeparate() throws {
        var state = G9N9NHIDReportState()
        func snapshot(_ id: UInt32, _ data: Data) throws -> G9N9NHIDReportState.Snapshot {
            let value = state.consume(reportID: id, data: data)
            return try #require(value)
        }
        let up = G9N9NHIDUsage(page: 7, usage: 0x52)
        let volume = G9N9NHIDUsage(page: 12, usage: 0xE9)
        #expect(try snapshot(0, Data([1, 0, 0, 0x52, 0, 0, 0, 0, 0])).pressed == [up])
        #expect(try snapshot(0, Data([2, 0xE9, 0, 0])).pressed == [up, volume])
        #expect(try snapshot(0, Data([2, 0, 0, 0])).pressed == [up])
    }

    @Test func consumerAndButtonArraysAreSeparateUsages() {
        #expect(G9N9NHIDReport.usages(reportID: 2, data: Data([0x24, 2, 5]))
            == [.init(page: 12, usage: 0x224), .init(page: 9, usage: 5)])
        #expect(G9N9NHIDReport.usages(reportID: 2, data: Data([2, 0x24, 2, 0]))
            == [.init(page: 12, usage: 0x224)])
        #expect(G9N9NHIDReport.usages(reportID: 2, data: Data([0, 0, 0])) == [])
    }

    @Test func malformedAndRolloverReportsAreRejected() {
        #expect(G9N9NHIDReport.usages(reportID: 1, data: Data([0, 0, 1, 0, 0, 0, 0, 0])) == nil)
        #expect(G9N9NHIDReport.usages(reportID: 1, data: Data(repeating: 0, count: 7)) == nil)
        #expect(G9N9NHIDReport.usages(reportID: 2, data: Data([0xFF, 0xFF, 0])) == nil)
        #expect(G9N9NHIDReport.usages(reportID: 2, data: Data([0, 0, 11])) == nil)
        #expect(G9N9NHIDReport.usages(reportID: 5, data: Data(repeating: 0, count: 20)) == nil)
    }

    @Test func releasesOnlyClearTheirOwnReportAndRepeatsHaveNoNewEdge() throws {
        var state = G9N9NHIDReportState()
        func snapshot(_ id: UInt32, _ data: Data) throws -> G9N9NHIDReportState.Snapshot {
            let value = state.consume(reportID: id, data: data)
            return try #require(value)
        }
        let up = Data([0, 0, 0x52, 0, 0, 0, 0, 0])
        let upUsage = G9N9NHIDUsage(page: 7, usage: 0x52)
        let volume = G9N9NHIDUsage(page: 12, usage: 0xE9)
        #expect(try snapshot(1, up).newlyPressed == [upUsage])
        #expect(try snapshot(1, up).newlyPressed.isEmpty)
        #expect(try snapshot(2, Data([0xE9, 0, 0])).pressed == [upUsage, volume])
        #expect(try snapshot(2, Data([0, 0, 0])).pressed == [upUsage])
        let ignored = state.consume(reportID: 3, data: Data([1, 2, 3, 4]))
        #expect(ignored == nil)
        #expect(try snapshot(1, up).newlyPressed.isEmpty)
        state.reset()
        #expect(try snapshot(1, up).newlyPressed == [upUsage])
    }
    @Test func learningPrefersAnOrdinaryKeyOverItsModifierChord() {
        let modifier = G9N9NHIDUsage(page: 7, usage: 0xE0)
        let ordinary = G9N9NHIDUsage(page: 7, usage: 4)
        #expect(G9N9NHIDReport.learningCandidate(in: [modifier, ordinary]) == ordinary)
        #expect(G9N9NHIDReport.learningCandidate(in: [modifier]) == modifier)
        #expect(G9N9NHIDReport.learningCandidate(in: []) == nil)
    }

}
