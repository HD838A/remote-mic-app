import AppKit
import Foundation
import Testing
@testable import RemoteMic

@Suite("Common phrases", .serialized)
struct CommonPhraseTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func generate(_ source: String) throws -> (Int32, Data) {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/generate-common-phrases.py").path, "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private func builtIns() throws -> Data {
        let source = try String(contentsOf: root.appendingPathComponent("Resources/CommonPhrases/built-in.md"), encoding: .utf8)
        let (code, data) = try generate(source)
        #expect(code == 0)
        return data
    }

    @Test func sourceGeneratesExplicitBindingsAndRejectsFourInvalidInputs() throws {
        let source = try String(contentsOf: root.appendingPathComponent("Resources/CommonPhrases/built-in.md"), encoding: .utf8)
        let archive = try JSONDecoder().decode(CommonPhraseArchive.self, from: builtIns())
        #expect(archive.entries.count == 12)
        #expect(archive.bindings == ["ok": "builtin-1", "left": "builtin-2", "up": "builtin-3", "right": "builtin-4", "down": "builtin-5"])
        for invalid in [
            source.replacingOccurrences(of: "| 1 | 好的 | 好的 | OK | OK |", with: "| 1 | 好的 | 好的 | OK |"),
            source.replacingOccurrences(of: "| 1 | 好的 | 好的 | OK | OK |", with: "| 1 | 好的 |  | OK | OK |"),
            source.replacingOccurrences(of: "| 2 | 继续 |", with: "| 20 | 继续 |"),
            source.replacingOccurrences(of: "| 左 | 2 | 继续 |", with: "| 左 | 1 | 好的 |"),
        ] {
            #expect(try generate(invalid).0 != 0)
        }
    }

    @Test func editingBuiltInMakesLocalCopyAndSurvivesReloadWithoutChangingMappings() throws {
        let suite = "CommonPhraseTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try builtIns()
        let store = CommonPhraseStore(defaults: defaults, builtInData: data)
        let settings = AppSettings(defaults: defaults)
        let prior = settings.action(for: .left)
        var phrase = try #require(store.phrase(for: .ok))
        phrase.chineseText = "仅本机测试内容"
        let id = try store.save(phrase, replacing: phrase.id)
        #expect(id.hasPrefix("user-"))
        #expect(store.phrase(for: .ok)?.chineseText == phrase.chineseText)
        #expect(settings.action(for: .left) == prior)
        let reloaded = CommonPhraseStore(defaults: defaults, builtInData: data)
        #expect(reloaded.phrase(for: .ok)?.id == id)
        try reloaded.assign(.left, to: id)
        try reloaded.move(id, by: 1)
        #expect(reloaded.phrase(for: .left)?.id == id)
        try reloaded.delete(id)
        #expect(reloaded.phrase(for: .ok) == nil)
        #expect(reloaded.phrase(for: .left) == nil)
        #expect(settings.action(for: .left) == prior)
    }

    @Test func reorderAcrossSeveralRowsPreservesOtherEntriesAndBindings() throws {
        let suite = "CommonPhraseTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try builtIns()
        let store = CommonPhraseStore(defaults: defaults, builtInData: data)
        let before = store.archive
        let movedID = before.entries[0].id
        try store.move(movedID, by: 4)
        #expect(store.archive.entries[4].id == movedID)
        #expect(store.archive.entries.filter { $0.id != movedID } == before.entries.filter { $0.id != movedID })
        #expect(store.archive.bindings == before.bindings)
        let reloaded = CommonPhraseStore(defaults: defaults, builtInData: data)
        #expect(reloaded.archive == store.archive)
        try reloaded.move(movedID, by: -4)
        #expect(reloaded.archive == before)
    }

    @Test func unmodifiedBuiltInsRefreshFromResourceAndMalformedImportDoesNotOverwrite() throws {
        let suite = "CommonPhraseTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try builtIns()
        let store = CommonPhraseStore(defaults: defaults, builtInData: data)
        try store.assign(.left, to: "builtin-1")
        let before = store.archive
        #expect(throws: (any Error).self) { try store.importData(Data("{}".utf8)) }
        #expect(store.archive == before)
        var changed = try JSONDecoder().decode(CommonPhraseArchive.self, from: data)
        changed.entries[0].chineseText = "更新后的内置内容"
        let reloaded = CommonPhraseStore(defaults: defaults, builtInData: try JSONEncoder().encode(changed))
        #expect(reloaded.phrase(for: .ok)?.chineseText == "更新后的内置内容")
        let exported = try reloaded.exportData()
        try store.importData(exported)
        #expect(store.phrase(for: .left)?.chineseText == "更新后的内置内容")
        #expect(store.phrase(for: .left)?.id.hasPrefix("user-") == true)
        let importedReload = CommonPhraseStore(defaults: defaults, builtInData: data)
        #expect(importedReload.phrase(for: .left)?.chineseText == "更新后的内置内容")
    }

    @Test func routingIsImmediateNonRepeatingIsolatedAndConsumesBackRelease() {
        var routing = CommonPhraseRouting()
        #expect(routing.handle(.up, phase: .press, source: "phone") == .unhandled)
        routing.open(source: "phone")
        #expect(routing.handle(.up, phase: .press, source: "web") == .unhandled)
        #expect(routing.handle(.up, phase: .press, source: "watch") == .unhandled)
        #expect(routing.handle(.up, phase: .press, source: "phone") == .insert(.up))
        #expect(routing.handle(.up, phase: .press, source: "phone") == .consumed)
        #expect(routing.handle(.up, phase: .release, source: "phone") == .consumed)
        #expect(routing.handle(.up, phase: .press, source: "phone") == .insert(.up))
        #expect(routing.handle(.back, phase: .press, source: "phone") == .close)
        routing.close()
        #expect(routing.handle(.back, phase: .release, source: "phone") == .consumed)
        #expect(routing.handle(.up, phase: .release, source: "phone") == .consumed)
        #expect(routing.handle(.up, phase: .press, source: "phone") == .unhandled)
        routing.open(source: "web")
        routing.reset(source: "web")
        #expect(routing.handle(.left, phase: .press, source: "web") == .unhandled)
        #expect(!ButtonAction.openCommonPhrases.allowsRepeat)
        #expect(ButtonAction.openCommonPhrases.isAppInternal)
    }

    @MainActor @Test func clipboardRestoresAllTypesPreservesNewUserCopyAndSerializes() throws {
        let pasteboard = NSPasteboard(name: .init("CommonPhraseTests." + UUID().uuidString))
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("test.binary")
        item.setData(Data([1, 2, 3]), forType: type)
        item.setString("original clipboard fixture", forType: .string)
        pasteboard.writeObjects([item])
        var pending: [() -> Void] = []
        var posted: [String] = []
        var logs: [String] = []
        let inserter = CommonPhraseInserter(pasteboard: pasteboard, validateTarget: { _ in nil },
            postPaste: { posted.append(pasteboard.string(forType: .string) ?? ""); return true },
            schedule: { pending.append($0) }, logger: { logs.append($0) })
        var results: [String] = []
        inserter.insert("first fixture", into: 1) { results.append($0) }
        inserter.insert("second fixture", into: 1) { results.append($0) }
        #expect(posted == ["first fixture"])
        pending.removeFirst()()
        #expect(posted == ["first fixture", "second fixture"])
        pending.removeFirst()()
        #expect(pasteboard.string(forType: .string) == "original clipboard fixture")
        #expect(pasteboard.data(forType: type) == Data([1, 2, 3]))
        inserter.insert("third fixture", into: 1) { results.append($0) }
        pasteboard.clearContents()
        pasteboard.setString("new user copy fixture", forType: .string)
        pending.removeFirst()()
        #expect(pasteboard.string(forType: .string) == "new user copy fixture")
        #expect(results.count == 3)
        #expect(logs.filter { $0.contains("phase=completed") }.count == 3)
        #expect(logs.contains { $0.contains("user_copy_preserved") })
        #expect(logs.allSatisfy { !$0.contains("fixture") })
    }

    @MainActor @Test func failedPasteRestoresClipboardAndPendingCancellationHasOneTerminalResult() {
        let pasteboard = NSPasteboard(name: .init("CommonPhraseTests." + UUID().uuidString))
        pasteboard.setString("prior", forType: .string)
        var pending: [() -> Void] = []
        var results: [String] = []
        var logs: [String] = []
        let inserter = CommonPhraseInserter(pasteboard: pasteboard, validateTarget: { _ in nil },
            postPaste: { false }, schedule: { pending.append($0) }, logger: { logs.append($0) })
        inserter.insert("test", into: 1) { results.append($0) }
        inserter.insert("cancelled", into: 1) { results.append($0) }
        inserter.cancelPending()
        pending.removeFirst()()
        #expect(pasteboard.string(forType: .string) == "prior")
        #expect(results.contains("common_phrases.error.cancelled"))
        #expect(results.contains("common_phrases.error.paste_failed"))
        #expect(logs.filter { $0.contains("phase=completed") }.count == 2)
    }

    @MainActor @Test func unavailableOrChangedTargetNeverPostsPasteAndNextAttemptRecovers() {
        let pasteboard = NSPasteboard(name: .init("CommonPhraseTests." + UUID().uuidString))
        pasteboard.setString("prior", forType: .string)
        var failure: String? = "input_unavailable"
        var posts = 0
        var pending: [() -> Void] = []
        let inserter = CommonPhraseInserter(pasteboard: pasteboard, validateTarget: { _ in failure },
            postPaste: { posts += 1; return true }, schedule: { pending.append($0) }, logger: { _ in })
        inserter.insert("rejected", into: 1) { _ in }
        #expect(posts == 0)
        #expect(pasteboard.string(forType: .string) == "prior")
        failure = nil
        inserter.insert("recovered", into: 1) { _ in }
        #expect(posts == 1)
        pending.removeFirst()()
        #expect(pasteboard.string(forType: .string) == "prior")
    }

    @MainActor @Test func hidPanelBypassesDoubleClickAndHeldRepeatThenRestoresNormalMapping() throws {
        let suite = "CommonPhraseTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.arrowLeft, for: .left)
        settings.setAction(.commandCopy, for: .left, trigger: .doubleClick)
        let profileID = try #require(settings.selectedRemoteProfileID)
        var routing = CommonPhraseRouting()
        routing.open(source: "hid")
        var inserts = 0, ordinary = 0
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profileID, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in ordinary += 1; return true },
            diagnosticLogger: { _ in })
        monitor.claimsRuntimeButton = { _, button in routing.claims(button, source: "hid") }
        monitor.onRuntimeButton = { _, button, phase in
            switch routing.handle(button, phase: phase, source: "hid") {
            case .unhandled: return false
            case .insert: inserts += 1
            case .close: routing.close()
            case .consumed: break
            }
            return true
        }
        monitor.connectSimulatedDevice(fingerprint: "phrase-test", profileID: profileID)
        let report = Data([UInt8(RemoteButton.left.hidUsage), 0, 0, 0, 0, 0])
        monitor.handleSimulatedReport(reportID: 1, data: report)
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(inserts == 1)
        #expect(ordinary == 0)
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(inserts == 2)
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        routing.close()
        settings.setAction(.disabled, for: .left, trigger: .doubleClick)
        monitor.handleSimulatedReport(reportID: 1, data: report)
        #expect(ordinary == 1)
        monitor.disconnectSimulatedDevice()
    }
}
