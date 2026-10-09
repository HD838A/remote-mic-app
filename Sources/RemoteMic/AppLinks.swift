import Foundation

enum AppLinks {
    static let githubRepository = URL(
        string: "https://github.com/HD838A/remote-mic-app"
    )!
    static let chineseWebsite = URL(string: "https://sayall.app/")!
    static let englishWebsite = URL(string: "https://sayall.app/en/")!
    static let chineseIOSAppStore = URL(
        string: "https://apps.apple.com/app/%E6%97%A0%E7%BA%BF%E9%BA%A6/id6797208067"
    )!
    static let englishIOSAppStore = URL(
        string: "https://apps.apple.com/app/sayall/id6797208067"
    )!
    static let feedback = URL(
        string: "https://my.sayall.app/api/guest-entry?source=mac"
    )!
    static let doubaoInputMethod = URL(
        string: "https://shurufa.doubao.com/?from=sayall.app"
    )!
    static let vokieWebsite = URL(string: "https://vokie.com/?from=sayall.app")!

    static func iOSAppStore(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseIOSAppStore
            : englishIOSAppStore
    }

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }
}
