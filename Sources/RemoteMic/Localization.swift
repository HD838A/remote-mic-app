import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var nativeDisplayName: String {
        switch self {
        case .system: return "System Default"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

struct LocalizedMessage: Equatable {
    let key: String
    let arguments: [String]

    init(_ key: String, arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }

    func text(using localization: LocalizationStore) -> String {
        let template = localization.text(key)
        guard !arguments.isEmpty else { return template }
        return String(
            format: template,
            locale: localization.locale,
            arguments: arguments
        )
    }
}

final class LocalizationStore: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published private(set) var locale: Locale

    private let settings: AppSettings
    private var localeObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        language = settings.applicationLanguage
        locale = Self.resolvedLocale(for: settings.applicationLanguage)
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.language == .system else { return }
            self.locale = Self.resolvedLocale(for: .system)
        }
    }

    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }

    func select(_ language: AppLanguage) {
        guard self.language != language else { return }
        settings.applicationLanguage = language
        self.language = language
        locale = Self.resolvedLocale(for: language)
    }

    func text(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func localizedURL(forResource name: String, withExtension extension: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: `extension`,
            subdirectory: nil,
            localization: locale.identifier
        )
    }

    private var localizedBundle: Bundle {
        guard let path = Bundle.main.path(forResource: locale.identifier, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return .main
        }
        return bundle
    }

    private static func resolvedLocale(for language: AppLanguage) -> Locale {
        switch language {
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        case .system:
            let usesChinese = Locale.preferredLanguages.contains { identifier in
                Locale(identifier: identifier).language.languageCode?.identifier == "zh"
            }
            return Locale(identifier: usesChinese ? "zh-Hans" : "en")
        }
    }
}
