import Foundation
import Testing
@testable import RemoteMic

@Suite("Post-dictation text targeting")
struct PostDictationPolishCoordinatorTests {
    @Test func computesAnInsertionAtTheOriginalCursor() throws {
        let original = "前文后文"
        let updated = "前文这是本次语音后文"
        let change = try #require(
            PostDictationPolishCoordinator.continuousChange(
                original: original,
                updated: updated,
                originalSelection: NSRange(location: 2, length: 0)
            )
        )

        #expect(change.oldRange == NSRange(location: 2, length: 0))
        #expect(change.newText == "这是本次语音")
        #expect((updated as NSString).substring(with: change.newRange) == change.newText)
    }

    @Test func computesReplacementOfTheOriginalSelection() throws {
        let change = try #require(
            PostDictationPolishCoordinator.continuousChange(
                original: "请在旧内容之后继续",
                updated: "请在新内容之后继续",
                originalSelection: NSRange(location: 2, length: 3)
            )
        )

        #expect(change.oldRange == NSRange(location: 2, length: 3))
        #expect(change.newRange == NSRange(location: 2, length: 3))
        #expect(change.newText == "新内容")
    }

    @Test func frozenContextUsesOneHundredVisibleCharactersAndKeepsEmojiIntact() throws {
        let before = String(repeating: "甲", count: 105) + "👨‍👩‍👧‍👦"
        let after = "e\u{301}" + String(repeating: "乙", count: 105)
        let text = before + after
        let selection = NSRange(text.index(text.startIndex, offsetBy: before.count)..<text.index(text.startIndex, offsetBy: before.count), in: text)
        let context = try #require(
            PostDictationPolishCoordinator.frozenContext(text: text, selection: selection)
        )

        #expect(context.before.count == 100)
        #expect(context.before.hasSuffix("👨‍👩‍👧‍👦"))
        #expect(context.after.count == 100)
        #expect(context.after.hasPrefix("e\u{301}"))
    }

    @Test func defaultFeatureFlagIsOffAndPersistsExplicitChanges() throws {
        let suiteName = "RemoteMicTests.PostDictation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.deepSeekPostDictationEnabled == false)
        settings.deepSeekPostDictationEnabled = true
        #expect(AppSettings(defaults: defaults).deepSeekPostDictationEnabled == true)
        settings.deepSeekPostDictationEnabled = false
        #expect(AppSettings(defaults: defaults).deepSeekPostDictationEnabled == false)
    }
}
