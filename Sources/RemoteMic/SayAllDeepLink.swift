import Foundation

enum SayAllDeepLinkStatus: String, CaseIterable {
    case received
    case configured
    case partial
    case ready
    case failed
}

struct SayAllDeepLinkRequest: Equatable {
    let source: String?
    let status: SayAllDeepLinkStatus?
    let reason: String?

    static func parse(_ url: URL) -> Self? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "sayall",
              components.host?.lowercased() == "launch",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }

        let items = Dictionary(
            grouping: components.queryItems ?? [],
            by: \.name
        )
        guard items.values.allSatisfy({ $0.count == 1 }) else { return nil }

        let sourceValue = items["source"]?.first?.value?.lowercased()
        let source = sourceValue == "vokie" ? sourceValue : nil
        let status = items["status"]?.first?.value
            .flatMap(SayAllDeepLinkStatus.init(rawValue:))
        let reason = items["reason"]?.first?.value.flatMap(normalizedReason)
        return Self(source: source, status: status, reason: reason)
    }

    private static func normalizedReason(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.")
        guard value.lowercased().unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value.lowercased()
    }
}

enum VokieDeepLink {
    static func launchURL(for plan: OnboardingVoicePairingPlan) -> URL? {
        guard plan.binding.tool == .vokie else { return nil }
        var components = URLComponents()
        components.scheme = "vokie"
        components.host = "launch"
        components.queryItems = [
            URLQueryItem(name: "source", value: "xiaomi-mic"),
            URLQueryItem(
                name: "action",
                value: plan.binding.gestureMode == .toggle ? "handsfree-ptt" : "ptt"
            ),
        ]
        return components.url
    }
}

extension Notification.Name {
    static let sayAllDeepLinkReceived = Notification.Name("sayall.deepLink.received")
}
