import AppKit
import Combine
import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Quick phrases")
struct QuickPhrasesTests {
    @Test func defaultsDoNotShipPersonalContent() {
        #expect(QuickPhrase.defaults.isEmpty)
    }

    @Test func paletteNavigationMatchesTheTwoColumnGrid() {
        #expect(QuickPhraseGridNavigation.destination(
            from: 0, button: .right, itemCount: 5
        ) == 1)
        #expect(QuickPhraseGridNavigation.destination(
            from: 1, button: .down, itemCount: 5
        ) == 3)
        #expect(QuickPhraseGridNavigation.destination(
            from: 3, button: .down, itemCount: 5
        ) == 4)
        #expect(QuickPhraseGridNavigation.destination(
            from: 4, button: .up, itemCount: 5
        ) == 2)
        #expect(QuickPhraseGridNavigation.destination(
            from: 0, button: .left, itemCount: 5
        ) == 0)
    }

    @Test func quickPhrasesAreEditableAndPersisted() throws {
        let suiteName = "RemoteMic.QuickPhrases.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let id = settings.addQuickPhrase()
        settings.updateQuickPhrase(id: id, title: "新名称", text: "新内容")
        settings.moveQuickPhrase(id: id, offset: -1)

        let reloaded = AppSettings(defaults: defaults)
        let phrase = try #require(reloaded.quickPhrases.first(where: { $0.id == id }))
        #expect(phrase.title == "新名称")
        #expect(phrase.text == "新内容")
        reloaded.removeQuickPhrase(id: id)
        #expect(!reloaded.quickPhrases.contains(where: { $0.id == id }))
    }

    @Test func unchangedEditorValuesDoNotRepublishTheWholePhraseList() throws {
        let suiteName = "RemoteMic.QuickPhrases.NoOp.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let id = settings.addQuickPhrase()
        settings.updateQuickPhrase(id: id, title: "测试", text: "普通测试文字")
        let phrase = try #require(settings.quickPhrases.first)
        var emissions = 0
        let observation = settings.$quickPhrases.dropFirst().sink { _ in emissions += 1 }

        #expect(!settings.updateQuickPhrase(
            id: phrase.id,
            title: phrase.title,
            text: phrase.text
        ))
        #expect(emissions == 0)
        #expect(settings.updateQuickPhrase(
            id: phrase.id,
            title: phrase.title + " 2",
            text: phrase.text + " 2"
        ))
        #expect(emissions == 1)
        withExtendedLifetime(observation) {}
    }

    @Test func settingsEditorUsesALocalDraftInsteadOfPersistingEveryKeystroke() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("quickPhraseDraftTitle"))
        #expect(source.contains("quickPhraseDraftText"))
        #expect(source.contains("350_000_000"))
        #expect(source.contains("guard !Task.isCancelled"))
        #expect(!source.contains("set: { settings.updateQuickPhrase(id: id"))
    }

    @Test func quickPhrasesTravelWithConfigurationExportAndImport() throws {
        let sourceName = "RemoteMic.QuickPhrases.Source.\(UUID().uuidString)"
        let targetName = "RemoteMic.QuickPhrases.Target.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceName))
        let targetDefaults = try #require(UserDefaults(suiteName: targetName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceName)
            targetDefaults.removePersistentDomain(forName: targetName)
        }
        let source = AppSettings(defaults: sourceDefaults)
        let id = source.addQuickPhrase()
        source.updateQuickPhrase(id: id, title: "跨设备", text: "导出的常用语")

        let target = AppSettings(defaults: targetDefaults)
        try target.importConfiguration(from: source.exportedConfigurationData())
        #expect(target.quickPhrases.contains {
            $0.id == id && $0.title == "跨设备" && $0.text == "导出的常用语"
        })
    }

    @Test func actionIsASelectableNonRepeatingInternalAction() {
        #expect(ButtonAction(rawValue: "showQuickPhrases") == .showQuickPhrases)
        #expect(ButtonAction.showQuickPhrases.category == .custom)
        #expect(ButtonAction.showQuickPhrases.isAppInternal)
        #expect(!ButtonAction.showQuickPhrases.allowsRepeat)
    }

    @Test @MainActor func pasteRestoresThePreviousClipboardAfterPostingCommandV() throws {
        let pasteboard = NSPasteboard(name: .init("RemoteMic.QuickPhrases.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("原剪贴板", forType: .string)
        var posted: [(CGKeyCode, Bool, CGEventFlags)] = []
        var restore: (() -> Void)?

        #expect(QuickPhrasePaster.paste(
            "待插入文字",
            pasteboard: pasteboard,
            keyStatePoster: { code, isDown, flags in
                posted.append((code, isDown, flags))
                return true
            },
            scheduler: { _, action in restore = action }
        ))
        #expect(pasteboard.string(forType: .string) == "待插入文字")
        #expect(posted.count == 2)
        #expect(posted[0].0 == 9 && posted[0].1)
        #expect(posted[1].0 == 9 && !posted[1].1)
        #expect(posted.allSatisfy { $0.2.contains(.maskCommand) })

        let restoreClipboard = try #require(restore)
        restoreClipboard()
        #expect(pasteboard.string(forType: .string) == "原剪贴板")
    }

    @Test @MainActor func clipboardRestoreDoesNotOverwriteAUsersNewCopy() throws {
        let pasteboard = NSPasteboard(name: .init("RemoteMic.QuickPhrases.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("原剪贴板", forType: .string)
        var restore: (() -> Void)?

        #expect(QuickPhrasePaster.paste(
            "待插入文字",
            pasteboard: pasteboard,
            keyStatePoster: { _, _, _ in true },
            scheduler: { _, action in restore = action }
        ))
        pasteboard.clearContents()
        pasteboard.setString("用户新复制", forType: .string)
        let restoreClipboard = try #require(restore)
        restoreClipboard()
        #expect(pasteboard.string(forType: .string) == "用户新复制")
    }

    @Test @MainActor func emptyOrFailedPasteDoesNotLoseTheExistingClipboard() {
        let pasteboard = NSPasteboard(name: .init("RemoteMic.QuickPhrases.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("原剪贴板", forType: .string)
        var events = 0

        #expect(!QuickPhrasePaster.paste(
            "",
            pasteboard: pasteboard,
            keyStatePoster: { _, _, _ in
                events += 1
                return true
            }
        ))
        #expect(events == 0)
        #expect(pasteboard.string(forType: .string) == "原剪贴板")

        #expect(!QuickPhrasePaster.paste(
            "测试文字",
            pasteboard: pasteboard,
            keyStatePoster: { _, _, _ in false }
        ))
        #expect(pasteboard.string(forType: .string) == "原剪贴板")
    }
}
