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
        #expect(localization.localizedWebsiteURL.absoluteString == AppLinks.githubRepository.absoluteString)
        #expect(AppSettings(defaults: defaults).applicationLanguage == .english)

        localization.select(.simplifiedChinese)
        #expect(localization.language == .simplifiedChinese)
        #expect(localization.locale.identifier == "zh-Hans")
        #expect(localization.localizedWebsiteURL.absoluteString == AppLinks.githubRepository.absoluteString)
        #expect(AppSettings(defaults: defaults).applicationLanguage == .simplifiedChinese)
    }

    @Test func forkLinksDoNotSendUsersToUpstreamServices() throws {
        #expect(AppLinks.website(for: Locale(identifier: "en")) == AppLinks.githubRepository)
        #expect(AppLinks.website(for: Locale(identifier: "zh-Hant")) == AppLinks.githubRepository)
        #expect(AppLinks.feedback.absoluteString ==
            "https://github.com/unfla-sh/MiRemote2Pro-Whisper/issues")
        for readmeName in ["README.md", "README.en.md"] {
            let readme = try String(
                contentsOf: repositoryRoot.appendingPathComponent(readmeName),
                encoding: .utf8
            )
            #expect(readme.contains("https://github.com/unfla-sh/MiRemote2Pro-Whisper/releases"))
            #expect(!readme.contains("https://testflight.apple.com/join/"))
        }
    }

    @Test func localizationFilesUseSemanticCompleteKeysAndMatchingFormats() throws {
        let localizationDirectories = try sourceLocalizationDirectories()
        let englishDirectory = try #require(
            localizationDirectories.first { $0.lastPathComponent == "en.lproj" }
        )
        let english = try strings(at: englishDirectory.appendingPathComponent("Localizable.strings"))
        let englishInfo = try strings(at: englishDirectory.appendingPathComponent("InfoPlist.strings"))

        #expect(english["action.command_delete"] == "Command-Delete")
        #expect(english["button_mapping.action_filter.all"] == "All")
        #expect(english["shortcut.editor.instructions"]?.contains("single key") == true)
        #expect(english["shortcut.editor.instructions"]?.contains("recorded alone") == true)
        #expect(english["action.scroll_up"] == "Scroll Up")
        #expect(english["action.scroll_down"] == "Scroll Down")
        #expect(english["keyboard.key.delete"] == "Delete")
        #expect(english["keyboard.key.left"] == "Left")
        #expect(english["keyboard.key.right"] == "Right")
        #expect(english["keyboard.key.up"] == "Up")
        #expect(english["keyboard.key.down"] == "Down")
        #expect(english["about.support.feedback"] == "Feedback")
        #expect(english["onboarding.remote.first_pairing.wake"] == "Hold TV for about 2 seconds until the white light at the bottom starts flashing.")
        #expect(english["onboarding.remote.first_pairing.pair"] == "Then hold Home + Menu together to enter Bluetooth pairing mode.")
        #expect(english["onboarding.remote.button_waiting_detail"] == "Press the center OK button or an arrow button. Do not press the microphone/voice button.")
        #expect(english["onboarding.remote.voice_button_mistake.title"] == "That was the voice button")
        #expect(english["onboarding.remote.voice_button_mistake.detail"] == "This step checks a normal control button. Press the center OK button or an arrow button instead.")
        #expect(english["onboarding.voice_tool.weixin.title"] == "WeChat Input Method")
        #expect(english["onboarding.voice_tool.system_fn.conflict"] == "macOS is still using Fn")
        #expect(english["remote.device.model.apple_siri_remote_a2854"] == "Apple Remote Type-C")
        #expect(english["remote.device.model.apple_siri_remote_a2540"] == "Apple Remote Lightning")

        #expect(!english.isEmpty)
        for (key, value) in english {
            #expect(key.range(of: #"^[a-z0-9]+(?:[._][a-z0-9]+)*$"#, options: .regularExpression) != nil)
            #expect(!value.isEmpty)
            #expect(value != key)
        }

        for directory in localizationDirectories {
            let localized = try strings(at: directory.appendingPathComponent("Localizable.strings"))
            let localizedInfo = try strings(at: directory.appendingPathComponent("InfoPlist.strings"))
            if directory.lastPathComponent == "zh-Hans.lproj" {
                #expect(localized["action.command_delete"] == "Command-Delete")
                #expect(localized["button_mapping.action_filter.all"] == "全部")
                #expect(localized["shortcut.editor.instructions"]?.contains("单个按键") == true)
                #expect(localized["shortcut.editor.instructions"]?.contains("单独录入") == true)
                #expect(localized["action.scroll_up"] == "向上滚动")
                #expect(localized["action.scroll_down"] == "向下滚动")
                #expect(localized["about.support.feedback"] == "问题反馈")
                #expect(localized["onboarding.remote.first_pairing.wake"] == "长按 TV 键约 2 秒，直到遥控器底部白灯开始闪烁。")
                #expect(localized["onboarding.remote.first_pairing.pair"] == "同时长按 Home（主页）+ Menu（菜单）键，进入蓝牙配对模式。")
                #expect(localized["onboarding.remote.button_waiting_detail"] == "请短按圆盘中间的确定键或任意方向键，不要按麦克风/语音键。")
                #expect(localized["onboarding.remote.voice_button_mistake.title"] == "刚才按的是语音键")
                #expect(localized["onboarding.remote.voice_button_mistake.detail"] == "这一步检查普通控制键。请改为短按圆盘中间的确定键或任意方向键。")
                #expect(localized["onboarding.voice_tool.weixin.title"] == "微信输入法")
                #expect(localized["onboarding.voice_tool.system_fn.conflict"] == "系统仍在使用 Fn")
                #expect(localized["remote.device.model.apple_siri_remote_a2854"] == "苹果遥控器 Type-C")
                #expect(localized["remote.device.model.apple_siri_remote_a2540"] == "苹果遥控器 Lightning")
            }
            #expect(Set(localized.keys) == Set(english.keys))
            #expect(Set(localizedInfo.keys) == Set(englishInfo.keys))

            for key in english.keys {
                let englishValue = try #require(english[key])
                let localizedValue = try #require(localized[key])
                #expect(!localizedValue.isEmpty)
                #expect(localizedValue != key)
                #expect(formatPlaceholders(in: localizedValue) == formatPlaceholders(in: englishValue))
                #expect(!containsRestrictedUserTerm(localizedValue))
            }
        }
    }

    @Test func glossaryResourcesContainTheDocumentedTechnicalTerms() throws {
        for localization in ["en", "zh-Hans"] {
            let glossaryURL = repositoryRoot
                .appendingPathComponent("Resources")
                .appendingPathComponent("\(localization).lproj")
                .appendingPathComponent("Glossary.md")
            let glossary = try String(contentsOf: glossaryURL, encoding: .utf8)
            for term in ["RC003", "ATVV", "HID", "UUID", "Core Audio", "DMG", "PKG"] {
                #expect(glossary.contains(term))
            }
        }
    }

    @Test func localizedDocumentsFallBackToEnglish() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("RemoteMicLocalizationTests-\(UUID().uuidString)")
        let bundleURL = temporaryRoot.appendingPathComponent("Localization.bundle")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        let englishURL = resourcesURL.appendingPathComponent("en.lproj")
        let chineseURL = resourcesURL.appendingPathComponent("zh-Hans.lproj")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try fileManager.createDirectory(at: englishURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: chineseURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": "com.hd838a.RemoteMic.LocalizationTests",
            "CFBundlePackageType": "BNDL"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data("English glossary".utf8).write(to: englishURL.appendingPathComponent("Glossary.md"))

        let bundle = try #require(Bundle(url: bundleURL))
        let suiteName = "RemoteMicTests.LocalizationFallback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.applicationLanguage = .simplifiedChinese
        let localization = LocalizationStore(settings: settings, resourceBundle: bundle)
        let localizedURL = try #require(
            localization.localizedURL(forResource: "Glossary", withExtension: "md")
        )

        #expect(try String(contentsOf: localizedURL, encoding: .utf8) == "English glossary")
    }
}

private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func sourceLocalizationDirectories() throws -> [URL] {
    let resourcesURL = repositoryRoot.appendingPathComponent("Resources")
    return try FileManager.default.contentsOfDirectory(
        at: resourcesURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "lproj" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func strings(at url: URL) throws -> [String: String] {
    let data = try Data(contentsOf: url)
    let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    )
    return try #require(propertyList as? [String: String])
}

private func formatPlaceholders(in value: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: #"%(?:[0-9]+\$)?[a-zA-Z@]"#)
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        guard let range = Range(match.range, in: value) else { return nil }
        return String(value[range])
    }.sorted()
}

private func containsRestrictedUserTerm(_ value: String) -> Bool {
    value.range(
        of: #"RC003|ATVV|\bHID\b|\bUUID\b|virtual[ -]transport"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}
