import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var nativeDisplayName: String {
        guard self != .system else { return rawValue }
        let nativeLocale = Locale(identifier: rawValue)
        return nativeLocale.localizedString(forIdentifier: rawValue) ?? rawValue
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
    private let resourceBundle: Bundle
    private var localeObserver: NSObjectProtocol?

    init(settings: AppSettings, resourceBundle: Bundle = .main) {
        self.settings = settings
        self.resourceBundle = resourceBundle
        language = settings.applicationLanguage
        locale = Self.resolvedLocale(
            for: settings.applicationLanguage,
            resourceBundle: resourceBundle
        )
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.language == .system else { return }
            self.locale = Self.resolvedLocale(
                for: .system,
                resourceBundle: self.resourceBundle
            )
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
        locale = Self.resolvedLocale(for: language, resourceBundle: resourceBundle)
    }

    func text(_ key: String) -> String {
        if let localizedBundle = bundle(for: locale.identifier) {
            let value = localizedBundle.localizedString(
                forKey: key,
                value: nil,
                table: "Localizable"
            )
            if value != key {
                return value
            }
        }

        if locale.identifier != AppLanguage.english.rawValue,
           let englishBundle = bundle(for: AppLanguage.english.rawValue) {
            return englishBundle.localizedString(
                forKey: key,
                value: key,
                table: "Localizable"
            )
        }

        return key
    }

    func localizedURL(forResource name: String, withExtension extension: String) -> URL? {
        if let localizedURL = resourceBundle.url(
            forResource: name,
            withExtension: `extension`,
            subdirectory: nil,
            localization: locale.identifier
        ) {
            return localizedURL
        }

        guard locale.identifier != AppLanguage.english.rawValue else { return nil }
        return resourceBundle.url(
            forResource: name,
            withExtension: `extension`,
            subdirectory: nil,
            localization: AppLanguage.english.rawValue
        )
    }

    private func bundle(for localizationIdentifier: String) -> Bundle? {
        guard let path = resourceBundle.path(
            forResource: localizationIdentifier,
            ofType: "lproj"
        ) else {
            return nil
        }
        return Bundle(path: path)
    }

    private static func resolvedLocale(
        for language: AppLanguage,
        resourceBundle: Bundle
    ) -> Locale {
        switch language {
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        case .system:
            let supportedLocalizations = resourceBundle.localizations.filter { $0 != "Base" }
            let preferredLocalization = Bundle.preferredLocalizations(
                from: supportedLocalizations,
                forPreferences: Locale.preferredLanguages
            ).first ?? AppLanguage.english.rawValue
            return Locale(identifier: preferredLocalization)
        }
    }
}
