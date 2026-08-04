import SwiftUI

enum AppLanguage: String, CaseIterable, Equatable {
    case chinese = "zh-Hans"
    case english = "en"

    static let storageKey = "appLanguage"

    static func resolve(storedValue: String?, preferredLanguages: [String]) -> AppLanguage {
        if let storedValue, let language = AppLanguage(rawValue: storedValue) {
            return language
        }
        let preferredLanguage = preferredLanguages.first?.lowercased() ?? "en"
        return preferredLanguage.hasPrefix("zh") ? .chinese : .english
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var switchTitle: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.resolve(
        storedValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey),
        preferredLanguages: Locale.preferredLanguages
    )
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}
