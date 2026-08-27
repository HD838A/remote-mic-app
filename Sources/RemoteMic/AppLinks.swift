import Foundation

enum AppLinks {
    static let githubRepository = URL(
        string: "https://github.com/HD838A/remote-mic-app"
    )!
    static let chineseWebsite = URL(string: "https://sayall.app/")!
    static let englishWebsite = URL(string: "https://sayall.app/en/")!
    static let testFlightPublicBeta = URL(
        string: "https://testflight.apple.com/join/J8k8fb7v"
    )!
    static let feedback = URL(
        string: "https://my.sayall.app/api/guest-entry?source=mac"
    )!
    static let doubaoInputMethod = URL(
        string: "https://shurufa.doubao.com/?from=sayall.app"
    )!

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }
}
