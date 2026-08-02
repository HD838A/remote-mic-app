import Combine
import Foundation

enum AppConfigurationError: Error {
    case unsupportedVersion
    case invalidValues
}

private struct PersonalizedConfiguration: Codable {
    let formatVersion: Int
    let gainDB: Double
    let selectedAudioDeviceUID: String
    let customMappingEnabled: Bool
    let buttonBindings: [String: ButtonAction]
    let buttonShortcuts: [String: CustomKeyboardShortcut]
    let secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]
    let applicationLanguage: AppLanguage
    let showDockIcon: Bool
    let openMainWindowAtLaunch: Bool?
}

final class AppSettings: ObservableObject {
    private enum Keys {
        static let gainDB = "gainDB"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let customMappingEnabled = "customMappingEnabled"
        static let legacyExclusiveHID = "exclusiveHID"
        static let buttonBindings = "buttonBindings"
        static let buttonShortcuts = "buttonShortcuts"
        static let secondaryButtonBindings = "secondaryButtonBindings"
        static let peripheralIdentifier = "peripheralIdentifier"
        static let applicationLanguage = "applicationLanguage"
        static let showDockIcon = "showDockIcon"
        static let openMainWindowAtLaunch = "openMainWindowAtLaunch"
        static let lastLaunchedBuild = "launch.lastLaunchedBuild"
        static let totalButtonPressCount = "usage.totalButtonPressCount"
        static let totalVoiceDuration = "usage.totalVoiceDuration"
        static let trustedPhoneIdentityFingerprints = "security.trustedPhoneIdentityFingerprints"
    }

    private let defaults: UserDefaults

    @Published var gainDB: Double {
        didSet { defaults.set(gainDB, forKey: Keys.gainDB) }
    }

    @Published var selectedAudioDeviceUID: String {
        didSet { defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID) }
    }

    @Published var customMappingEnabled: Bool {
        didSet { defaults.set(customMappingEnabled, forKey: Keys.customMappingEnabled) }
    }

    @Published var buttonBindings: [RemoteButton: ButtonAction] {
        didSet { saveBindings() }
    }

    @Published var buttonShortcuts: [RemoteButton: CustomKeyboardShortcut] {
        didSet { saveShortcuts() }
    }

    @Published var secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] {
        didSet { saveSecondaryBindings() }
    }

    @Published var applicationLanguage: AppLanguage {
        didSet { defaults.set(applicationLanguage.rawValue, forKey: Keys.applicationLanguage) }
    }

    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }

    @Published var openMainWindowAtLaunch: Bool {
        didSet { defaults.set(openMainWindowAtLaunch, forKey: Keys.openMainWindowAtLaunch) }
    }

    @Published private(set) var totalButtonPressCount: UInt64 {
        didSet {
            defaults.set(NSNumber(value: totalButtonPressCount), forKey: Keys.totalButtonPressCount)
        }
    }

    @Published private(set) var totalVoiceDuration: TimeInterval {
        didSet { defaults.set(totalVoiceDuration, forKey: Keys.totalVoiceDuration) }
    }

    @Published private(set) var trustedPhoneIdentityFingerprints: Set<String> {
        didSet {
            defaults.set(
                trustedPhoneIdentityFingerprints.sorted(),
                forKey: Keys.trustedPhoneIdentityFingerprints
            )
        }
    }

    var peripheralIdentifier: UUID? {
        get {
            guard let raw = defaults.string(forKey: Keys.peripheralIdentifier) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            defaults.set(newValue?.uuidString, forKey: Keys.peripheralIdentifier)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gainDB = defaults.object(forKey: Keys.gainDB) == nil
            ? 10.0
            : defaults.double(forKey: Keys.gainDB)
        selectedAudioDeviceUID = defaults.string(forKey: Keys.selectedAudioDeviceUID) ?? ""
        if defaults.object(forKey: Keys.customMappingEnabled) != nil {
            customMappingEnabled = defaults.bool(forKey: Keys.customMappingEnabled)
        } else {
            customMappingEnabled = defaults.bool(forKey: Keys.legacyExclusiveHID)
        }

        if
            let data = defaults.data(forKey: Keys.buttonBindings),
            let decoded = try? JSONDecoder().decode([String: ButtonAction].self, from: data)
        {
            buttonBindings = Self.defaultBindings.merging(
                Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                })
            ) { _, saved in saved }
        } else {
            buttonBindings = Self.defaultBindings
        }

        if
            let data = defaults.data(forKey: Keys.buttonShortcuts),
            let decoded = try? JSONDecoder().decode([String: CustomKeyboardShortcut].self, from: data)
        {
            buttonShortcuts = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            })
        } else {
            buttonShortcuts = [:]
        }

        if
            let data = defaults.data(forKey: Keys.secondaryButtonBindings),
            let decoded = try? JSONDecoder().decode(
                [String: [String: ConfiguredButtonAction]].self,
                from: data
            )
        {
            secondaryButtonBindings = Dictionary(uniqueKeysWithValues: decoded.compactMap { buttonKey, bindings in
                guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
                let parsed = Dictionary(uniqueKeysWithValues: bindings.compactMap { triggerKey, binding in
                    ButtonTrigger(rawValue: triggerKey).map { ($0, binding) }
                })
                return parsed.isEmpty ? nil : (button, parsed)
            })
        } else {
            secondaryButtonBindings = [:]
        }

        applicationLanguage = AppLanguage(
            rawValue: defaults.string(forKey: Keys.applicationLanguage) ?? ""
        ) ?? .system
        showDockIcon = defaults.object(forKey: Keys.showDockIcon) == nil
            ? true
            : defaults.bool(forKey: Keys.showDockIcon)
        openMainWindowAtLaunch = defaults.object(forKey: Keys.openMainWindowAtLaunch) == nil
            ? true
            : defaults.bool(forKey: Keys.openMainWindowAtLaunch)
        totalButtonPressCount = (
            defaults.object(forKey: Keys.totalButtonPressCount) as? NSNumber
        )?.uint64Value ?? 0
        totalVoiceDuration = defaults.object(forKey: Keys.totalVoiceDuration) == nil
            ? 0
            : max(0, defaults.double(forKey: Keys.totalVoiceDuration))
        trustedPhoneIdentityFingerprints = Set(
            defaults.stringArray(forKey: Keys.trustedPhoneIdentityFingerprints) ?? []
        )
    }

    func action(for button: RemoteButton) -> ButtonAction {
        buttonBindings[button] ?? .disabled
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton) {
        buttonBindings[button] = action
    }

    func shortcut(for button: RemoteButton) -> CustomKeyboardShortcut? {
        buttonShortcuts[button]
    }

    func setShortcut(_ shortcut: CustomKeyboardShortcut?, for button: RemoteButton) {
        buttonShortcuts[button] = shortcut
    }

    func configuredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> ConfiguredButtonAction {
        if trigger == .singleClick {
            return ConfiguredButtonAction(
                action: action(for: button),
                shortcut: shortcut(for: button)
            )
        }
        return secondaryButtonBindings[button]?[trigger] ?? .disabled
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton, trigger: ButtonTrigger) {
        guard trigger != .singleClick else {
            setAction(action, for: button)
            if action != .customShortcut { setShortcut(nil, for: button) }
            return
        }

        var bindings = secondaryButtonBindings[button] ?? [:]
        if action == .disabled {
            bindings.removeValue(forKey: trigger)
        } else {
            let shortcut = action == .customShortcut ? bindings[trigger]?.shortcut : nil
            bindings[trigger] = ConfiguredButtonAction(action: action, shortcut: shortcut)
        }
        secondaryButtonBindings[button] = bindings.isEmpty ? nil : bindings
    }

    func setShortcut(
        _ shortcut: CustomKeyboardShortcut?,
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        guard trigger != .singleClick else {
            setShortcut(shortcut, for: button)
            return
        }
        guard var bindings = secondaryButtonBindings[button], var binding = bindings[trigger] else {
            return
        }
        binding.shortcut = shortcut
        bindings[trigger] = binding
        secondaryButtonBindings[button] = bindings
    }

    func hasSecondaryAction(for button: RemoteButton) -> Bool {
        [.doubleClick, .longPress].contains { trigger in
            configuredAction(for: button, trigger: trigger).action != .disabled
        }
    }

    func resetBindings() {
        buttonBindings = Self.defaultBindings
        buttonShortcuts = [:]
        secondaryButtonBindings = [:]
    }

    func recordButtonPress() {
        guard totalButtonPressCount < .max else { return }
        totalButtonPressCount += 1
    }

    func recordVoiceDuration(_ duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        totalVoiceDuration += duration
    }

    func isPhoneIdentityTrusted(_ fingerprint: String) -> Bool {
        trustedPhoneIdentityFingerprints.contains(fingerprint)
    }

    func trustPhoneIdentity(_ fingerprint: String) {
        guard !fingerprint.isEmpty else { return }
        trustedPhoneIdentityFingerprints.insert(fingerprint)
    }

    func clearTrustedPhoneIdentities() {
        trustedPhoneIdentityFingerprints.removeAll()
    }

    func recordLaunchAndDetectCompletedUpdate(
        currentBuild: String,
        sparkleHadLaunchedBefore: Bool
    ) -> Bool {
        let previousBuild = defaults.string(forKey: Keys.lastLaunchedBuild)
        defaults.set(currentBuild, forKey: Keys.lastLaunchedBuild)
        if
            let previousBuild,
            let previousBuildNumber = Int(previousBuild),
            let currentBuildNumber = Int(currentBuild)
        {
            return currentBuildNumber > previousBuildNumber
        }
        return previousBuild == nil && sparkleHadLaunchedBefore
    }

    func exportedConfigurationData() throws -> Data {
        let configuration = PersonalizedConfiguration(
            formatVersion: 1,
            gainDB: gainDB,
            selectedAudioDeviceUID: selectedAudioDeviceUID,
            customMappingEnabled: customMappingEnabled,
            buttonBindings: Dictionary(
                uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) }
            ),
            buttonShortcuts: Dictionary(
                uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) }
            ),
            secondaryButtonBindings: Dictionary(
                uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
                    (
                        button.rawValue,
                        Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
                    )
                }
            ),
            applicationLanguage: applicationLanguage,
            showDockIcon: showDockIcon,
            openMainWindowAtLaunch: openMainWindowAtLaunch
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    func importConfiguration(from data: Data) throws {
        let configuration = try JSONDecoder().decode(PersonalizedConfiguration.self, from: data)
        guard configuration.formatVersion == 1 else {
            throw AppConfigurationError.unsupportedVersion
        }
        guard configuration.gainDB.isFinite, (0...24).contains(configuration.gainDB) else {
            throw AppConfigurationError.invalidValues
        }

        let importedBindings = Dictionary(
            uniqueKeysWithValues: configuration.buttonBindings.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            }
        )
        let importedShortcuts = Dictionary(
            uniqueKeysWithValues: configuration.buttonShortcuts.compactMap { key, value in
                RemoteButton(rawValue: key).map { ($0, value) }
            }
        )
        let importedSecondaryBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] =
            Dictionary(
                uniqueKeysWithValues: configuration.secondaryButtonBindings.compactMap { buttonKey, bindings in
                    guard let button = RemoteButton(rawValue: buttonKey) else { return nil }
                    let parsed = Dictionary(
                        uniqueKeysWithValues: bindings.compactMap { triggerKey, binding in
                            ButtonTrigger(rawValue: triggerKey).map { ($0, binding) }
                        }
                    )
                    return parsed.isEmpty ? nil : (button, parsed)
                }
            )

        gainDB = configuration.gainDB
        selectedAudioDeviceUID = configuration.selectedAudioDeviceUID
        customMappingEnabled = configuration.customMappingEnabled
        buttonBindings = Self.defaultBindings.merging(importedBindings) { _, imported in imported }
        buttonShortcuts = importedShortcuts
        secondaryButtonBindings = importedSecondaryBindings
        applicationLanguage = configuration.applicationLanguage
        showDockIcon = configuration.showDockIcon
        if let openMainWindowAtLaunch = configuration.openMainWindowAtLaunch {
            self.openMainWindowAtLaunch = openMainWindowAtLaunch
        }
    }

    private func saveBindings() {
        let raw = Dictionary(uniqueKeysWithValues: buttonBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonBindings)
        }
    }

    private func saveShortcuts() {
        let raw = Dictionary(uniqueKeysWithValues: buttonShortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonShortcuts)
        }
    }

    private func saveSecondaryBindings() {
        let raw = Dictionary(uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
            (
                button.rawValue,
                Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
            )
        })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.secondaryButtonBindings)
        }
    }

    static let defaultBindings: [RemoteButton: ButtonAction] = [
        .power: .escape,
        .up: .arrowUp,
        .left: .arrowLeft,
        .ok: .returnKey,
        .right: .arrowRight,
        .down: .arrowDown,
        .back: .deleteBackward,
        .volumeUp: .volumeUp,
        .home: .showDesktop,
        .volumeDown: .volumeDown,
        .menu: .contextMenu,
        .tv: .appSwitcher,
    ]
}
