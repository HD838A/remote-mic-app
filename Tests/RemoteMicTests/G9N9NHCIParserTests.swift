import Foundation
import Testing
@testable import RemoteMic

struct G9N9NHCIParserTests {
    @Test func identityWindowWaitsForRemoteAndRejectsOldReconnectTimers() {
        var window = G9N9NHCIIdentityWindow()
        #expect(!window.accepts(0))
        let first = window.begin()
        #expect(window.accepts(first))
        window.invalidate()
        #expect(!window.accepts(first))
        let second = window.begin()
        #expect(window.accepts(second))
        #expect(!window.accepts(first))
        window.invalidate()
        #expect(!window.accepts(second))
    }
    private let serial = Data("TEST-G9-SERIAL-001".utf8)

    private func acl(_ att: Data, handle: UInt16 = 0x40) -> Data {
        let payload = Data([UInt8(att.count), 0, 4, 0]) + att
        return Data([UInt8(handle & 255), UInt8(handle >> 8) | 0x20,
                     UInt8(payload.count), 0]) + payload
    }
    private func record(_ payload: Data, type: UInt8 = 3) -> Data {
        let length = UInt32(payload.count + 9)
        return Data([UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                     UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)])
            + Data(repeating: 0, count: 8) + Data([type]) + payload
    }
    private func notification(_ key: UInt8, handle: UInt16 = 0x40, attribute: UInt16 = 0x2B) -> Data {
        let usages: [UInt8: UInt16] = [0: 0, 1: 0x19E, 3: 0x42, 4: 0x43, 5: 0x44, 6: 0x45,
            7: 0x41, 8: 0xE2, 10: 0x223, 11: 0x224, 12: 0xE9, 13: 0xEA, 14: 0x77, 15: 0x78, 17: 0x89]
        let usage = usages[key] ?? 0xFFFF
        return record(acl(Data([0x1B, UInt8(attribute & 255), UInt8(attribute >> 8),
                                UInt8(usage & 255), UInt8(usage >> 8)]), handle: handle))
    }
    private func bound() -> G9N9NHCIParser {
        var parser = G9N9NHCIParser()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        parser.identify(serial: serial)
        #expect(feed(record(acl(Data([0x0B]) + serial))).isEmpty)
        #expect(parser.isBound)
        return parser
    }

    @Test func noControlBeforeFreshIdentityRead() {
        var parser = G9N9NHCIParser()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        parser.identify(serial: serial)
        #expect(feed(notification(7)).isEmpty)
        #expect(!parser.isBound)
        #expect(feed(record(acl(Data([0x0B]) + Data("OTHER-SERIAL-001".utf8)))).isEmpty)
        #expect(!parser.isBound)
    }

    @Test func selectReleaseDedupAndOtherConnectionsAreIsolated() {
        var parser = bound()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        #expect(feed(notification(7)) == [.init(control: .select, down: true)])
        #expect(feed(notification(7)).isEmpty)
        #expect(feed(notification(11, handle: 0x41)).isEmpty)
        #expect(feed(notification(0, attribute: 0x30)).isEmpty)
        #expect(feed(notification(0)) == [.init(control: .select, down: false)])
        #expect(feed(notification(0)).isEmpty)
    }

    @Test(arguments: [UInt8(1), 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 17])
    func allOrdinaryControlsHavePairedEdges(_ key: UInt8) throws {
        var parser = bound()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        let control = try #require(G9N9NHCIParser.control(key))
        #expect(feed(notification(key)) == [.init(control: control, down: true)])
        #expect(feed(notification(0)) == [.init(control: control, down: false)])
    }

    @Test func changedKeyClosesPreviousBeforeBeginningNext() {
        var parser = bound()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        _ = feed(notification(7))
        #expect(feed(notification(11)) == [.init(control: .select, down: false), .init(control: .back, down: true)])
    }

    @Test func rawLiveACLAndTimestampWrappedACLCanProveIdentity() {
        for prefix in [Data([3]), Data(repeating: 0, count: 8) + Data([3]), Data([2]), Data()] {
            var parser = G9N9NHCIParser()
            func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
            parser.identify(serial: serial)
            _ = feed(prefix + acl(Data([0x0B]) + serial))
            #expect(parser.isBound)
            #expect(feed(notification(7)) == [.init(control: .select, down: true)])
        }
    }

    @Test func fragmentedACLReassemblesWithinBound() {
        var parser = bound()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        let att = Data([0x1B, 0x2B, 0, 0x41, 0])
        let firstPayload = Data([5, 0, 4, 0]) + att.prefix(2)
        let first = Data([0x40, 0x20, UInt8(firstPayload.count), 0]) + firstPayload
        let secondPayload = Data(att.dropFirst(2))
        let second = Data([0x40, 0x10, UInt8(secondPayload.count), 0]) + secondPayload
        #expect(feed(record(first)).isEmpty)
        #expect(feed(record(second)) == [.init(control: .select, down: true)])
    }

    @Test func disconnectCancelsAndPreventsHandleReuse() {
        var parser = bound()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        _ = feed(notification(7))
        let disconnected = record(Data([5, 4, 0, 0x40, 0, 0x13]), type: 1)
        #expect(feed(disconnected) == [.init(control: .select, down: false, cancelled: true)])
        #expect(!parser.isBound)
        #expect(feed(notification(7)).isEmpty)
    }

    @Test func duplicateIdentityAcrossConnectionsFailsClosed() {
        var parser = bound()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        _ = feed(notification(7))
        #expect(feed(record(acl(Data([0x0B]) + serial, handle: 0x41)))
            == [.init(control: .select, down: false, cancelled: true)])
        #expect(parser.identityConflict)
        #expect(feed(notification(7)).isEmpty)
    }

    @Test func badLengthsAndUnknownKeysNeverCreateAnAction() {
        var parser = bound()
        func feed(_ data: Data) -> [G9N9NHCIParser.Edge] { parser.consume(data) }
        #expect(feed(notification(0xFF)).isEmpty)
        #expect(feed(record(acl(Data([0x1B, 0x2B, 0, 1])))).isEmpty)
        #expect(feed(record(acl(Data([0x1B, 0x2B, 0, 1, 7, 1])))).isEmpty)
        #expect(feed(Data(repeating: 0, count: 70_000)).isEmpty)
        parser.identify(serial: Data([1, 2, 3]))
        #expect(feed(notification(7)).isEmpty)
        #expect(!parser.isBound)
    }

    @Test func learnsUnknownConsumerOnlyAfterReleaseAndNeedsFreshPress() {
        var parser = bound()
        func feed(_ bytes: [UInt8], handle: UInt16 = 0x40) -> [G9N9NHCIParser.Edge] {
            parser.consume(record(acl(Data([0x1B, 0x2B, 0]) + Data(bytes), handle: handle)))
        }
        let accepted = parser.beginLearning(.right)
        #expect(accepted)
        #expect(feed([0x46, 0]).isEmpty)
        let noLearnedKey = parser.takeLearnedKey()
        #expect(noLearnedKey == nil)
        #expect(feed([0, 0]).isEmpty)
        let learned = parser.takeLearnedKey()
        #expect(learned == .init(usage: 0x46, control: .right))
        #expect(feed([0x46, 0]) == [.init(control: .right, down: true)])
        #expect(feed([0, 0]) == [.init(control: .right, down: false)])
        parser.identify(serial: serial)
        #expect(feed([0x46, 0]).isEmpty)
        _ = parser.consume(record(acl(Data([0x0B]) + serial)))
        #expect(feed([0x46, 0]) == [.init(control: .right, down: true)])
    }

    @Test func learningCannotConsumeOtherConnectionsOrAnAmbiguousChord() {
        var parser = bound()
        func feed(_ bytes: [UInt8], handle: UInt16 = 0x40) -> [G9N9NHCIParser.Edge] {
            parser.consume(record(acl(Data([0x1B, 0x2B, 0]) + Data(bytes), handle: handle)))
        }
        let accepted = parser.beginLearning(.input)
        #expect(accepted)
        #expect(feed([0x83, 1], handle: 0x41).isEmpty)
        #expect(parser.learningReports == 0)
        #expect(feed([0x83, 1]).isEmpty)
        #expect(feed([0x41, 0]).isEmpty)
        #expect(feed([0, 0]).isEmpty)
        let noLearnedKey = parser.takeLearnedKey()
        #expect(noLearnedKey == nil)
        parser.cancelLearning()
        #expect(feed([0x41, 0]) == [.init(control: .select, down: true)])
    }
}
