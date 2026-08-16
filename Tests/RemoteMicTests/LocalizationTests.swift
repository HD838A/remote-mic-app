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
        #expect(localization.localizedWebsiteURL.absoluteString == "https://sayall.app/en/")
        #expect(AppSettings(defaults: defaults).applicationLanguage == .english)

        localization.select(.simplifiedChinese)
        #expect(localization.language == .simplifiedChinese)
        #expect(localization.locale.identifier == "zh-Hans")
        #expect(localization.localizedWebsiteURL.absoluteString == "https://sayall.app/")
        #expect(AppSettings(defaults: defaults).applicationLanguage == .simplifiedChinese)
    }

    @Test func appLinksProvideThePublicTestFlightBetaEverywhere() throws {
        let expectedURL = "https://testflight.apple.com/join/J8k8fb7v"
        #expect(AppLinks.testFlightPublicBeta.absoluteString == expectedURL)

        for readmeName in ["README.md", "README.en.md"] {
            let readme = try String(
                contentsOf: repositoryRoot.appendingPathComponent(readmeName),
                encoding: .utf8
            )
            #expect(readme.contains(expectedURL))
        }

        let expression = try NSRegularExpression(
            pattern: #"https://testflight\.apple\.com/join/[A-Za-z0-9]+"#
        )
        let allowedExtensions = Set([
            "json", "md", "plist", "sh", "strings", "swift", "ts", "tsx", "yaml", "yml"
        ])
        let ignoredDirectories = Set([".build", ".git", ".swiftpm", "dist"])
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: repositoryRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        )
        var referencedURLs: Set<String> = []

        while let fileURL = enumerator.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                if ignoredDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard allowedExtensions.contains(fileURL.pathExtension.lowercased()),
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                continue
            }
            let range = NSRange(contents.startIndex..., in: contents)
            for match in expression.matches(in: contents, range: range) {
                guard let matchRange = Range(match.range, in: contents) else { continue }
                referencedURLs.insert(String(contents[matchRange]))
            }
        }

        #expect(referencedURLs == [expectedURL])
    }

    @Test func readmesUseVersionIndependentMacDownloadEntries() throws {
        let stableURL = "https://download.sayall.app/mac"
        let previewURL = "https://github.com/HD838A/remote-mic-app/releases"
        let expectations = [
            ("README.md", "## 下载与安装", "- 最新正式版（Apple Silicon）：", "- 最新预览版（Apple Silicon / Intel）："),
            ("README.en.md", "## Download and install", "- Latest stable release (Apple Silicon):", "- Latest pre-release (Apple Silicon / Intel):"),
        ]

        for (readmeName, sectionHeading, stablePrefix, previewPrefix) in expectations {
            let readme = try String(
                contentsOf: repositoryRoot.appendingPathComponent(readmeName),
                encoding: .utf8
            )
            let sectionStart = try #require(readme.range(of: sectionHeading))
            let remainingReadme = readme[sectionStart.upperBound...]
            let sectionEnd = remainingReadme.range(of: "\n## ")?.lowerBound ?? readme.endIndex
            let downloadSection = readme[sectionStart.lowerBound..<sectionEnd]
            let stableEntry = try #require(
                downloadSection.split(separator: "\n").first { $0.hasPrefix(stablePrefix) }
            )
            let previewEntry = try #require(
                downloadSection.split(separator: "\n").first { $0.hasPrefix(previewPrefix) }
            )

            #expect(stableEntry.contains("](\(stableURL))"))
            #expect(!stableEntry.contains("/releases/"))
            #expect(previewEntry.contains("](\(previewURL))"))
            #expect(!previewEntry.contains("/releases/tag/"))
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
        #expect(english["about.support.feedback"] == "Feedback")
        #expect(english["onboarding.remote.first_pairing.wake"] == "Hold TV for about 2 seconds until the white light at the bottom starts flashing.")
        #expect(english["onboarding.remote.first_pairing.pair"] == "Then hold Home + Menu together to enter Bluetooth pairing mode.")
        #expect(english["onboarding.voice_tool.weixin.title"] == "WeChat Input Method")
        #expect(english["onboarding.voice_tool.system_fn.conflict"] == "macOS is still using Fn")

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
                #expect(localized["about.support.feedback"] == "问题反馈")
                #expect(localized["onboarding.remote.first_pairing.wake"] == "长按 TV 键约 2 秒，直到遥控器底部白灯开始闪烁。")
                #expect(localized["onboarding.remote.first_pairing.pair"] == "同时长按 Home（主页）+ Menu（菜单）键，进入蓝牙配对模式。")
                #expect(localized["onboarding.voice_tool.weixin.title"] == "微信输入法")
                #expect(localized["onboarding.voice_tool.system_fn.conflict"] == "系统仍在使用 Fn")
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
