import Foundation

enum AppLinks {
    static let githubRepository = URL(
        string: "https://github.com/HD838A/remote-mic-app"
    )!
    static let chineseWebsite = URL(string: "https://8586ai.com/")!
    static let englishWebsite = URL(string: "https://8586ai.com/en/")!
    static let testFlightPublicBeta = URL(
        string: "https://testflight.apple.com/join/J8k8fb7v"
    )!

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }
}
