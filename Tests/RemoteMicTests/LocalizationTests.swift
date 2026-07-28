import Foundation
import Testing
@testable import RemoteMic

@Suite("Application localization")
struct LocalizationTests {
    @Test func languageSelectionPersistsAndUpdatesTheLocaleImmediately() throws {
        let suiteName = "RemoteMicTests.Localization.(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let localization = LocalizationStore(settings: settings)

        localization.select(.english)
        #expect(localization.language == .english)
        #expect(localization.locale.identifier == "en")
        #expect(AppSettings(defaults: defaults).applicationLanguage == .english)

        localization.select(.simplifiedChinese)
        #expect(localization.language == .simplifiedChinese)
        #expect(localization.locale.identifier == "zh-Hans")
        #expect(AppSettings(defaults: defaults).applicationLanguage == .simplifiedChinese)
    }
}
