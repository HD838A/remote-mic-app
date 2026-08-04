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
    let checksForPreReleaseUpdates: Bool?
    let experimentalContinuousRecordingEnabled: Bool?
    let continuousRecordingPowerBindingBackup: ConfiguredButtonAction?
}

enum UsageStatisticsPeriod: String, CaseIterable, Identifiable {
    case today
    case thisWeek
    case total

    var id: String { rawValue }
}

struct UsageStatistics: Equatable {
    let buttonPressCount: UInt64
    let voiceDuration: TimeInterval
}

private struct DailyUsageStatistics: Codable {
    var buttonPressCount: UInt64 = 0
    var voiceDuration: TimeInterval = 0
}

final class AppSettings: ObservableObject {
    static let continuousRecordingExperimentAvailable = false

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
        static let checksForPreReleaseUpdates = "checksForPreReleaseUpdates"
        static let experimentalContinuousRecordingEnabled = "experimentalContinuousRecordingEnabled"
        static let continuousRecordingPowerBindingBackup = "continuousRecordingPowerBindingBackup"
        static let lastLaunchedBuild = "launch.lastLaunchedBuild"
        static let totalButtonPressCount = "usage.totalButtonPressCount"
        static let totalVoiceDuration = "usage.totalVoiceDuration"
        static let dailyStatistics = "usage.dailyStatistics"
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

    @Published var checksForPreReleaseUpdates: Bool {
        didSet {
            defaults.set(checksForPreReleaseUpdates, forKey: Keys.checksForPreReleaseUpdates)
        }
    }

    @Published private(set) var experimentalContinuousRecordingEnabled: Bool {
        didSet {
            defaults.set(
                experimentalContinuousRecordingEnabled,
                forKey: Keys.experimentalContinuousRecordingEnabled
            )
        }
    }

    private var continuousRecordingPowerBindingBackup: ConfiguredButtonAction? {
        didSet { saveContinuousRecordingPowerBindingBackup() }
    }

    @Published private(set) var totalButtonPressCount: UInt64 {
        didSet {
            defaults.set(NSNumber(value: totalButtonPressCount), forKey: Keys.totalButtonPressCount)
        }
    }

    @Published private(set) var totalVoiceDuration: TimeInterval {
        didSet { defaults.set(totalVoiceDuration, forKey: Keys.totalVoiceDuration) }
    }

    @Published private var dailyStatistics: [String: DailyUsageStatistics] {
        didSet {
            if let data = try? JSONEncoder().encode(dailyStatistics) {
                defaults.set(data, forKey: Keys.dailyStatistics)
            }
        }
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
        checksForPreReleaseUpdates = defaults.bool(forKey: Keys.checksForPreReleaseUpdates)
        experimentalContinuousRecordingEnabled = defaults.bool(
            forKey: Keys.experimentalContinuousRecordingEnabled
        )
        continuousRecordingPowerBindingBackup = defaults
            .data(forKey: Keys.continuousRecordingPowerBindingBackup)
            .flatMap { try? JSONDecoder().decode(ConfiguredButtonAction.self, from: $0) }
        totalButtonPressCount = (
            defaults.object(forKey: Keys.totalButtonPressCount) as? NSNumber
        )?.uint64Value ?? 0
        totalVoiceDuration = defaults.object(forKey: Keys.totalVoiceDuration) == nil
            ? 0
            : max(0, defaults.double(forKey: Keys.totalVoiceDuration))
        dailyStatistics = defaults.data(forKey: Keys.dailyStatistics)
            .flatMap { try? JSONDecoder().decode([String: DailyUsageStatistics].self, from: $0) }
            ?? [:]
        trustedPhoneIdentityFingerprints = Set(
            defaults.stringArray(forKey: Keys.trustedPhoneIdentityFingerprints) ?? []
        )
        applyContinuousRecordingExperimentState(
            enabled: experimentalContinuousRecordingEnabled,
            backup: continuousRecordingPowerBindingBackup
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

    func setExperimentalContinuousRecordingEnabled(_ enabled: Bool) {
        let backup = enabled
            ? continuousRecordingPowerBindingBackup ?? configuredAction(for: .power, trigger: .singleClick)
            : continuousRecordingPowerBindingBackup
        applyContinuousRecordingExperimentState(enabled: enabled, backup: backup)
    }

    func resetBindings() {
        buttonBindings = Self.defaultBindings
        buttonShortcuts = [:]
        secondaryButtonBindings = [:]
        if experimentalContinuousRecordingEnabled {
            continuousRecordingPowerBindingBackup = ConfiguredButtonAction(
                action: .escape,
                shortcut: nil
            )
            setAction(.toggleLongRecording, for: .power, trigger: .singleClick)
        }
    }

    func recordButtonPress(at date: Date = Date(), calendar: Calendar = .current) {
        if totalButtonPressCount < .max {
            totalButtonPressCount += 1
        }

        let key = Self.dayKey(for: date, calendar: calendar)
        var statistics = dailyStatistics[key] ?? DailyUsageStatistics()
        if statistics.buttonPressCount < .max {
            statistics.buttonPressCount += 1
            dailyStatistics[key] = statistics
        }
    }

    func recordVoiceDuration(
        _ duration: TimeInterval,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard duration.isFinite, duration > 0 else { return }
        totalVoiceDuration = Self.addingDuration(duration, to: totalVoiceDuration)

        let key = Self.dayKey(for: date, calendar: calendar)
        var statistics = dailyStatistics[key] ?? DailyUsageStatistics()
        statistics.voiceDuration = Self.addingDuration(duration, to: statistics.voiceDuration)
        dailyStatistics[key] = statistics
    }

    func usageStatistics(
        for period: UsageStatisticsPeriod,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageStatistics {
        switch period {
        case .today:
            return Self.usageStatistics(
                from: dailyStatistics[Self.dayKey(for: date, calendar: calendar)]
            )
        case .thisWeek:
            guard let week = Self.weekInterval(containing: date, calendar: calendar) else {
                return UsageStatistics(buttonPressCount: 0, voiceDuration: 0)
            }
            return dailyStatistics.reduce(
                into: UsageStatistics(buttonPressCount: 0, voiceDuration: 0)
            ) { result, entry in
                guard
                    let day = Self.date(fromDayKey: entry.key, calendar: calendar),
                    day >= week.start,
                    day < week.end
                else { return }
                result = UsageStatistics(
                    buttonPressCount: Self.addingCount(
                        entry.value.buttonPressCount,
                        to: result.buttonPressCount
                    ),
                    voiceDuration: Self.addingDuration(
                        entry.value.voiceDuration,
                        to: result.voiceDuration
                    )
                )
            }
        case .total:
            return UsageStatistics(
                buttonPressCount: totalButtonPressCount,
                voiceDuration: totalVoiceDuration
            )
        }
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
            openMainWindowAtLaunch: openMainWindowAtLaunch,
            checksForPreReleaseUpdates: checksForPreReleaseUpdates,
            experimentalContinuousRecordingEnabled: experimentalContinuousRecordingEnabled,
            continuousRecordingPowerBindingBackup: continuousRecordingPowerBindingBackup
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
        if let checksForPreReleaseUpdates = configuration.checksForPreReleaseUpdates {
            self.checksForPreReleaseUpdates = checksForPreReleaseUpdates
        }
        applyContinuousRecordingExperimentState(
            enabled: configuration.experimentalContinuousRecordingEnabled ?? false,
            backup: configuration.continuousRecordingPowerBindingBackup
        )
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

    private func saveContinuousRecordingPowerBindingBackup() {
        guard let continuousRecordingPowerBindingBackup else {
            defaults.removeObject(forKey: Keys.continuousRecordingPowerBindingBackup)
            return
        }
        if let data = try? JSONEncoder().encode(continuousRecordingPowerBindingBackup) {
            defaults.set(data, forKey: Keys.continuousRecordingPowerBindingBackup)
        }
    }

    private func applyContinuousRecordingExperimentState(
        enabled: Bool,
        backup: ConfiguredButtonAction?
    ) {
        let enabled = enabled && Self.continuousRecordingExperimentAvailable
        if enabled {
            let current = configuredAction(for: .power, trigger: .singleClick)
            continuousRecordingPowerBindingBackup = Self.safeContinuousRecordingBackup(
                backup ?? current
            )
            experimentalContinuousRecordingEnabled = true
            customMappingEnabled = true
            setAction(.toggleLongRecording, for: .power, trigger: .singleClick)
            return
        }

        experimentalContinuousRecordingEnabled = false
        if backup != nil || action(for: .power) == .toggleLongRecording {
            let restored = Self.safeContinuousRecordingBackup(
                backup ?? ConfiguredButtonAction(action: .escape, shortcut: nil)
            )
            setAction(restored.action, for: .power, trigger: .singleClick)
            setShortcut(restored.shortcut, for: .power, trigger: .singleClick)
        }
        continuousRecordingPowerBindingBackup = nil
    }

    private static func safeContinuousRecordingBackup(
        _ binding: ConfiguredButtonAction
    ) -> ConfiguredButtonAction {
        guard binding.action == .toggleLongRecording else { return binding }
        return ConfiguredButtonAction(action: .escape, shortcut: nil)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func weekInterval(
        containing date: Date,
        calendar: Calendar
    ) -> DateInterval? {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceWeekStart = (weekday - calendar.firstWeekday + 7) % 7
        guard
            let start = calendar.date(byAdding: .day, value: -daysSinceWeekStart, to: startOfDay),
            let end = calendar.date(byAdding: .day, value: 7, to: start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func usageStatistics(
        from daily: DailyUsageStatistics?
    ) -> UsageStatistics {
        UsageStatistics(
            buttonPressCount: daily?.buttonPressCount ?? 0,
            voiceDuration: max(0, daily?.voiceDuration ?? 0)
        )
    }

    private static func addingCount(_ value: UInt64, to total: UInt64) -> UInt64 {
        let (result, overflow) = total.addingReportingOverflow(value)
        return overflow ? .max : result
    }

    private static func addingDuration(
        _ duration: TimeInterval,
        to total: TimeInterval
    ) -> TimeInterval {
        let result = max(0, total) + max(0, duration)
        return result.isFinite ? result : .greatestFiniteMagnitude
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
