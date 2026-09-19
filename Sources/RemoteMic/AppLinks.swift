import Foundation

enum AppLinks {
    // This fork's own repository — a derivative of HD838A/remote-mic-app
    // (see `upstreamGithubRepository` below) that adds embedded, on-device
    // Cantonese/English transcription. Points here, not upstream, since
    // this is where this fork's own code, issues, and changes live.
    static let githubRepository = URL(
        string: "https://github.com/unfla-sh/MiRemote2Pro-Whisper"
    )!
    static let upstreamGithubRepository = URL(
        string: "https://github.com/HD838A/remote-mic-app"
    )!
    // This fork has no separate website. The repository is its public home.
    static let chineseWebsite = githubRepository
    static let englishWebsite = githubRepository
    // The upstream feedback form (my.sayall.app) is HD838A's own backend
    // service for the original app; this fork has no equivalent service, so
    // feedback goes to this fork's own GitHub Issues instead.
    static let feedback = URL(
        string: "https://github.com/unfla-sh/MiRemote2Pro-Whisper/issues"
    )!

    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }
}
