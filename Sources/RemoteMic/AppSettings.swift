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
    let buttonApplicationProfileIDs: [String: UUID]?
    let secondaryButtonBindings: [String: [String: ConfiguredButtonAction]]
    let customApplicationProfiles: [CustomApplicationProfile]?
    let applicationLanguage: AppLanguage
    let showDockIcon: Bool
    let openMainWindowAtLaunch: Bool?
    let checksForPreReleaseUpdates: Bool?
    let experimentalContinuousRecordingEnabled: Bool?
    let voiceFnTapModeEnabled: Bool?
    let voiceKeyMode: VoiceKeyMode?
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

struct UsageStatisticsBucket: Equatable, Identifiable {
    let startDate: Date
    let statistics: UsageStatistics

    var id: Date { startDate }
}

struct WeeklyUsageStatisticsSeries: Equatable {
    let earlierStatistics: UsageStatistics
    let weeklyBuckets: [UsageStatisticsBucket]
}

enum UsageEventSource: String, Codable, CaseIterable, Hashable {
    case bluetoothRemote = "bluetooth_remote"
    case nearbyPhone = "nearby_phone"
    case webRemote = "web_remote"
    case unknown
}

enum UsageControl {
    case remoteButton(RemoteButton)
    case voice

    var identifier: String {
        switch self {
        case let .remoteButton(button): return "button.\(button.rawValue)"
        case .voice: return "voice"
        }
    }
}

struct UsageStatisticsMetadata: Equatable {
    var firstActivityAt: Date?
    var lastActivityAt: Date?
    var buttonPressCountBySource: [UsageEventSource: UInt64] = [:]
    var buttonPressCountByControl: [String: UInt64] = [:]
    var buttonPressCountByHour: [Int: UInt64] = [:]
    var voiceSessionCount: UInt64 = 0
    var voiceSessionCountBySource: [UsageEventSource: UInt64] = [:]
    var voiceSessionCountByEndHour: [Int: UInt64] = [:]
    var voiceDurationBySource: [UsageEventSource: TimeInterval] = [:]
    var voiceDurationByEndHour: [Int: TimeInterval] = [:]
    var longestVoiceSessionDuration: TimeInterval = 0
    var longestVoiceSessionDurationBySource: [UsageEventSource: TimeInterval] = [:]
    var timeZoneIdentifiers: Set<String> = []
    var calendarIdentifiers: Set<String> = []
    var schemaVersions: Set<Int> = []
}

struct VoiceSessionUsageRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date?
    let endedAt: Date
    let duration: TimeInterval
    let source: UsageEventSource?
}

private struct DailyUsageMetadata: Codable {
    var schemaVersion = 0
    var firstActivityAt: Date?
    var lastActivityAt: Date?
    var buttonPressCountBySource: [String: UInt64] = [:]
    var buttonPressCountByControl: [String: UInt64] = [:]
    var buttonPressCountByHour: [Int: UInt64] = [:]
    var voiceSessionCount: UInt64 = 0
    var voiceSessionCountBySource: [String: UInt64] = [:]
    var voiceSessionCountByEndHour: [Int: UInt64] = [:]
    var voiceDurationBySource: [String: TimeInterval] = [:]
    var voiceDurationByEndHour: [Int: TimeInterval] = [:]
    var longestVoiceSessionDuration: TimeInterval = 0
    var longestVoiceSessionDurationBySource: [String: TimeInterval] = [:]
    var timeZoneIdentifiers: Set<String> = []
    var calendarIdentifiers: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case firstActivityAt
        case lastActivityAt
        case buttonPressCountBySource
        case buttonPressCountByControl
        case buttonPressCountByHour
        case voiceSessionCount
        case voiceSessionCountBySource
        case voiceSessionCountByEndHour
        case voiceDurationBySource
        case voiceDurationByEndHour
        case longestVoiceSessionDuration
        case longestVoiceSessionDurationBySource
        case timeZoneIdentifiers
        case calendarIdentifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        firstActivityAt = try container.decodeIfPresent(Date.self, forKey: .firstActivityAt)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        buttonPressCountBySource = try container.decodeIfPresent(
            [String: UInt64].self,
            forKey: .buttonPressCountBySource
        ) ?? [:]
        buttonPressCountByControl = try container.decodeIfPresent(
            [String: UInt64].self,
            forKey: .buttonPressCountByControl
        ) ?? [:]
        buttonPressCountByHour = try container.decodeIfPresent(
            [Int: UInt64].self,
            forKey: .buttonPressCountByHour
        ) ?? [:]
        voiceSessionCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .voiceSessionCount
        ) ?? 0
        voiceSessionCountBySource = try container.decodeIfPresent(
            [String: UInt64].self,
            forKey: .voiceSessionCountBySource
        ) ?? [:]
        voiceSessionCountByEndHour = try container.decodeIfPresent(
            [Int: UInt64].self,
            forKey: .voiceSessionCountByEndHour
        ) ?? [:]
        voiceDurationBySource = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .voiceDurationBySource
        ) ?? [:]
        voiceDurationByEndHour = try container.decodeIfPresent(
            [Int: TimeInterval].self,
            forKey: .voiceDurationByEndHour
        ) ?? [:]
        longestVoiceSessionDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .longestVoiceSessionDuration
        ) ?? 0
        longestVoiceSessionDurationBySource = try container.decodeIfPresent(
            [String: TimeInterval].self,
            forKey: .longestVoiceSessionDurationBySource
        ) ?? [:]
        timeZoneIdentifiers = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .timeZoneIdentifiers
        ) ?? []
        calendarIdentifiers = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .calendarIdentifiers
        ) ?? []
    }
}

private struct DailyUsageStatistics: Codable {
    var buttonPressCount: UInt64 = 0
    var voiceDuration: TimeInterval = 0
    var metadata = DailyUsageMetadata()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case buttonPressCount
        case voiceDuration
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttonPressCount = try container.decodeIfPresent(
            UInt64.self,
            forKey: .buttonPressCount
        ) ?? 0
        voiceDuration = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .voiceDuration
        ) ?? 0
        metadata = try container.decodeIfPresent(
            DailyUsageMetadata.self,
            forKey: .metadata
        ) ?? DailyUsageMetadata()
    }
}

final class AppSettings: ObservableObject {
    static let continuousRecordingExperimentAvailable = false
    static let currentOnboardingVersion = 1

    private enum Keys {
        static let gainDB = "gainDB"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let customMappingEnabled = "customMappingEnabled"
        static let legacyExclusiveHID = "exclusiveHID"
        static let buttonBindings = "buttonBindings"
        static let buttonShortcuts = "buttonShortcuts"
        static let buttonApplicationProfileIDs = "buttonApplicationProfileIDs"
        static let secondaryButtonBindings = "secondaryButtonBindings"
        static let customApplicationProfiles = "customApplicationProfiles"
        static let peripheralIdentifier = "peripheralIdentifier"
        static let remoteDeviceProfiles = "remoteDeviceProfiles"
        static let selectedRemoteProfileID = "selectedRemoteProfileID"
        static let applicationLanguage = "applicationLanguage"
        static let showDockIcon = "showDockIcon"
        static let openMainWindowAtLaunch = "openMainWindowAtLaunch"
        static let checksForPreReleaseUpdates = "checksForPreReleaseUpdates"
        static let experimentalContinuousRecordingEnabled = "experimentalContinuousRecordingEnabled"
        static let voiceFnTapModeEnabled = "voiceFnTapModeEnabled"
        static let voiceKeyMode = "voiceKeyMode"
        static let localTranscriptHistoryEnabled = "localTranscriptHistoryEnabled"
        static let continuousRecordingPowerBindingBackup = "continuousRecordingPowerBindingBackup"
        static let lastLaunchedBuild = "launch.lastLaunchedBuild"
        static let totalButtonPressCount = "usage.totalButtonPressCount"
        static let totalVoiceDuration = "usage.totalVoiceDuration"
        static let dailyStatistics = "usage.dailyStatistics"
        static let voiceSessionRanking = "usage.voiceSessionRanking"
        static let trustedPhoneIdentityFingerprints = "security.trustedPhoneIdentityFingerprints"
        static let onboardingCompletedVersion = "onboarding.completedVersion"
        static let onboardingStep = "onboarding.step"
        static let onboardingRemoteAvailability = "onboarding.remoteAvailability"
        static let onboardingControlMethod = "onboarding.controlMethod"
        static let onboardingVoiceTool = "onboarding.voiceTool"
        static let onboardingMigrationVersion = "onboarding.migrationVersion"
        static let firstUseEvents = "onboarding.diagnostics.events"
        static let firstUseStepStartedAt = "onboarding.diagnostics.stepStartedAt"
        static let firstUseLastSignature = "onboarding.diagnostics.lastSignature"
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
        didSet {
            saveBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonShortcuts: [RemoteButton: CustomKeyboardShortcut] {
        didSet {
            saveShortcuts()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var buttonApplicationProfileIDs: [RemoteButton: UUID] {
        didSet {
            saveButtonApplicationProfileIDs()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published var secondaryButtonBindings: [RemoteButton: [ButtonTrigger: ConfiguredButtonAction]] {
        didSet {
            saveSecondaryBindings()
            saveSelectedRemoteProfileMappings()
        }
    }

    @Published private(set) var customApplicationProfiles: [CustomApplicationProfile] {
        didSet { saveCustomApplicationProfiles() }
    }

    @Published private(set) var remoteDeviceProfiles: [RemoteDeviceProfile] {
        didSet { saveRemoteDeviceProfiles() }
    }

    @Published private(set) var selectedRemoteProfileID: UUID? {
        didSet { defaults.set(selectedRemoteProfileID?.uuidString, forKey: Keys.selectedRemoteProfileID) }
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

    @Published var voiceFnTapModeEnabled: Bool {
        didSet {
            defaults.set(
                voiceFnTapModeEnabled,
                forKey: Keys.voiceFnTapModeEnabled
            )
        }
    }

    @Published var voiceKeyMode: VoiceKeyMode {
        didSet {
            defaults.set(voiceKeyMode.rawValue, forKey: Keys.voiceKeyMode)
        }
    }

    @Published var localTranscriptHistoryEnabled: Bool {
        didSet {
            defaults.set(
                localTranscriptHistoryEnabled,
                forKey: Keys.localTranscriptHistoryEnabled
            )
        }
    }

    private var continuousRecordingPowerBindingBackup: ConfiguredButtonAction? {
        didSet { saveContinuousRecordingPowerBindingBackup() }
    }

    private var isLoadingRemoteProfile = false

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

    @Published private(set) var voiceSessionRanking: [VoiceSessionUsageRecord] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceSessionRanking) {
                defaults.set(data, forKey: Keys.voiceSessionRanking)
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

    @Published private(set) var onboardingCompletedVersion: Int {
        didSet {
            defaults.set(onboardingCompletedVersion, forKey: Keys.onboardingCompletedVersion)
        }
    }

    @Published private(set) var onboardingStep: OnboardingStep {
        didSet { defaults.set(onboardingStep.rawValue, forKey: Keys.onboardingStep) }
    }

    @Published private(set) var onboardingRemoteAvailability: OnboardingRemoteAvailability {
        didSet {
            defaults.set(
                onboardingRemoteAvailability.rawValue,
                forKey: Keys.onboardingRemoteAvailability
            )
        }
    }

    @Published private(set) var onboardingControlMethod: OnboardingControlMethod {
        didSet {
            defaults.set(onboardingControlMethod.rawValue, forKey: Keys.onboardingControlMethod)
        }
    }

    @Published private(set) var onboardingVoiceTool: OnboardingVoiceTool {
        didSet { defaults.set(onboardingVoiceTool.rawValue, forKey: Keys.onboardingVoiceTool) }
    }

    var isOnboardingComplete: Bool {
        onboardingCompletedVersion >= Self.currentOnboardingVersion
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
        remoteDeviceProfiles = []
        selectedRemoteProfileID = nil
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
            let data = defaults.data(forKey: Keys.buttonApplicationProfileIDs),
            let decoded = try? JSONDecoder().decode([String: UUID].self, from: data)
        {
            buttonApplicationProfileIDs = Dictionary(
                uniqueKeysWithValues: decoded.compactMap { key, value in
                    RemoteButton(rawValue: key).map { ($0, value) }
                }
            )
        } else {
            buttonApplicationProfileIDs = [:]
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

        customApplicationProfiles = defaults
            .data(forKey: Keys.customApplicationProfiles)
            .flatMap { try? JSONDecoder().decode([CustomApplicationProfile].self, from: $0) }
            ?? []

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
        voiceFnTapModeEnabled = defaults.bool(
            forKey: Keys.voiceFnTapModeEnabled
        )
        voiceKeyMode = VoiceKeyMode(
            rawValue: defaults.string(forKey: Keys.voiceKeyMode) ?? ""
        ) ?? .function
        localTranscriptHistoryEnabled = defaults.bool(
            forKey: Keys.localTranscriptHistoryEnabled
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
        voiceSessionRanking = Self.normalizedVoiceSessionRanking(
            defaults.data(forKey: Keys.voiceSessionRanking)
                .flatMap { try? JSONDecoder().decode([VoiceSessionUsageRecord].self, from: $0) }
                ?? []
        )
        trustedPhoneIdentityFingerprints = Set(
            defaults.stringArray(forKey: Keys.trustedPhoneIdentityFingerprints) ?? []
        )
        onboardingCompletedVersion = defaults.integer(forKey: Keys.onboardingCompletedVersion)
        let persistedOnboardingStep = defaults.string(forKey: Keys.onboardingStep)
            .flatMap(OnboardingStep.init(rawValue:))
            ?? .welcome
        onboardingStep = persistedOnboardingStep
        let persistedControlMethod = defaults.string(forKey: Keys.onboardingControlMethod)
            .flatMap(OnboardingControlMethod.init(rawValue:))
            ?? (persistedOnboardingStep == .welcome ||
                persistedOnboardingStep == .voiceTool ||
                persistedOnboardingStep == .remoteAvailability ||
                persistedOnboardingStep == .controlMethod
                ? .unselected
                : .physicalRemote)
        onboardingControlMethod = persistedControlMethod
        onboardingRemoteAvailability = defaults.string(
            forKey: Keys.onboardingRemoteAvailability
        )
            .flatMap(OnboardingRemoteAvailability.init(rawValue:))
            ?? {
                switch persistedControlMethod {
                case .physicalRemote:
                    return .hasRemote
                case .iPhoneApp, .webRemote:
                    return .noRemote
                case .unselected:
                    return .unselected
                }
            }()
        onboardingVoiceTool = defaults.string(forKey: Keys.onboardingVoiceTool)
            .flatMap(OnboardingVoiceTool.init(rawValue:))
            ?? .unselected
        let legacyMappings = RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings
        )
        if
            let data = defaults.data(forKey: Keys.remoteDeviceProfiles),
            let decoded = try? JSONDecoder().decode([RemoteDeviceProfile].self, from: data),
            !decoded.isEmpty
        {
            remoteDeviceProfiles = decoded
            let savedID = defaults.string(forKey: Keys.selectedRemoteProfileID).flatMap(UUID.init(uuidString:))
            selectedRemoteProfileID = decoded.contains(where: { $0.id == savedID })
                ? savedID
                : decoded.first?.id
            if let selectedRemoteProfileID,
               let selected = decoded.first(where: { $0.id == selectedRemoteProfileID }) {
                buttonBindings = Self.defaultBindings.merging(selected.mappings.parsedButtonBindings) {
                    _, saved in saved
                }
                buttonShortcuts = selected.mappings.parsedButtonShortcuts
                buttonApplicationProfileIDs = selected.mappings.parsedButtonApplicationProfileIDs
                secondaryButtonBindings = selected.mappings.parsedSecondaryButtonBindings
            }
        } else {
            let migrated = RemoteDeviceProfile(
                bluetoothIdentifier: defaults.string(forKey: Keys.peripheralIdentifier).flatMap(UUID.init(uuidString:)),
                mappings: legacyMappings
            )
            remoteDeviceProfiles = [migrated]
            selectedRemoteProfileID = migrated.id
        }
        applyContinuousRecordingExperimentState(
            enabled: experimentalContinuousRecordingEnabled,
            backup: continuousRecordingPowerBindingBackup
        )
    }

    func setOnboardingStep(_ step: OnboardingStep) {
        guard !isOnboardingComplete, onboardingStep != step else { return }
        onboardingStep = step
    }

    func recordFirstUseEvent(
        _ kind: FirstUseEventKind,
        step: OnboardingStep,
        failureReason: FirstUseFailureReason? = nil,
        at date: Date = Date()
    ) {
        let stepStartedAt = defaults.object(forKey: Keys.firstUseStepStartedAt) as? Date ?? date
        let event = FirstUseEvent(
            timestamp: date,
            kind: kind,
            step: step,
            elapsedMilliseconds: max(0, Int(date.timeIntervalSince(stepStartedAt) * 1_000)),
            failureReason: failureReason
        )
        if kind == .blocked,
           defaults.string(forKey: Keys.firstUseLastSignature) == event.deduplicationSignature {
            return
        }
        var events = firstUseEvents
        events.append(event)
        if events.count > 100 {
            events.removeFirst(events.count - 100)
        }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Keys.firstUseEvents)
        }
        defaults.set(event.deduplicationSignature, forKey: Keys.firstUseLastSignature)
        if kind == .entered {
            defaults.set(date, forKey: Keys.firstUseStepStartedAt)
        }
    }

    var firstUseEvents: [FirstUseEvent] {
        defaults.data(forKey: Keys.firstUseEvents)
            .flatMap { try? JSONDecoder().decode([FirstUseEvent].self, from: $0) }
            ?? []
    }

    func setOnboardingVoiceTool(_ voiceTool: OnboardingVoiceTool) {
        let shouldEnableFnTap = voiceTool == .typeless && voiceKeyMode == .function
        if voiceFnTapModeEnabled != shouldEnableFnTap {
            voiceFnTapModeEnabled = shouldEnableFnTap
        }
        guard onboardingVoiceTool != voiceTool else { return }
        onboardingVoiceTool = voiceTool
    }

    func setOnboardingControlMethod(_ controlMethod: OnboardingControlMethod) {
        guard onboardingControlMethod != controlMethod else { return }
        onboardingControlMethod = controlMethod
    }

    func setOnboardingRemoteAvailability(_ availability: OnboardingRemoteAvailability) {
        guard onboardingRemoteAvailability != availability else { return }
        onboardingRemoteAvailability = availability
    }

    func completeOnboarding() {
        recordFirstUseEvent(.completed, step: .complete)
        onboardingStep = .complete
        onboardingCompletedVersion = Self.currentOnboardingVersion
    }

    func restartOnboarding() {
        onboardingVoiceTool = .unselected
        onboardingRemoteAvailability = .unselected
        onboardingControlMethod = .unselected
        onboardingStep = .welcome
        onboardingCompletedVersion = 0
        defaults.removeObject(forKey: Keys.firstUseStepStartedAt)
        defaults.removeObject(forKey: Keys.firstUseLastSignature)
    }

    func action(for button: RemoteButton) -> ButtonAction {
        buttonBindings[button] ?? .disabled
    }

    func action(for button: RemoteButton, profileID: UUID?) -> ButtonAction {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return action(for: button) }
        return profile.mappings.parsedButtonBindings[button] ?? Self.defaultBindings[button] ?? .disabled
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton) {
        buttonBindings[button] = action
    }

    func shortcut(for button: RemoteButton) -> CustomKeyboardShortcut? {
        buttonShortcuts[button]
    }

    func shortcut(for button: RemoteButton, profileID: UUID?) -> CustomKeyboardShortcut? {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return shortcut(for: button) }
        return profile.mappings.parsedButtonShortcuts[button]
    }

    func setShortcut(_ shortcut: CustomKeyboardShortcut?, for button: RemoteButton) {
        buttonShortcuts[button] = shortcut
    }

    func applicationProfileID(for button: RemoteButton) -> UUID? {
        buttonApplicationProfileIDs[button]
    }

    func applicationProfileID(for button: RemoteButton, profileID: UUID?) -> UUID? {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return applicationProfileID(for: button) }
        return profile.mappings.parsedButtonApplicationProfileIDs[button]
    }

    func customApplicationProfile(id: UUID?) -> CustomApplicationProfile? {
        guard let id else { return nil }
        return customApplicationProfiles.first(where: { $0.id == id })
    }

    @discardableResult
    func addCustomApplicationProfile(_ profile: CustomApplicationProfile) -> UUID {
        customApplicationProfiles.append(profile)
        return profile.id
    }

    func updateCustomApplicationProfile(_ profile: CustomApplicationProfile) {
        guard let index = customApplicationProfiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        customApplicationProfiles[index] = profile
    }

    func configuredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> ConfiguredButtonAction {
        if trigger == .singleClick {
            return ConfiguredButtonAction(
                action: action(for: button),
                shortcut: shortcut(for: button),
                applicationProfileID: applicationProfileID(for: button)
            )
        }
        return secondaryButtonBindings[button]?[trigger] ?? .disabled
    }

    func configuredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        profileID: UUID?
    ) -> ConfiguredButtonAction {
        guard let profileID, profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return configuredAction(for: button, trigger: trigger) }
        let bindings = profile.mappings.parsedButtonBindings
        let shortcuts = profile.mappings.parsedButtonShortcuts
        if trigger == .singleClick {
            return ConfiguredButtonAction(
                action: bindings[button] ?? Self.defaultBindings[button] ?? .disabled,
                shortcut: shortcuts[button],
                applicationProfileID: profile.mappings.parsedButtonApplicationProfileIDs[button]
            )
        }
        return profile.mappings.parsedSecondaryButtonBindings[button]?[trigger] ?? .disabled
    }

    var selectedRemoteProfile: RemoteDeviceProfile? {
        guard let selectedRemoteProfileID else { return nil }
        return remoteDeviceProfiles.first(where: { $0.id == selectedRemoteProfileID })
    }

    func selectRemoteProfile(_ profileID: UUID) {
        guard profileID != selectedRemoteProfileID,
              let profile = remoteDeviceProfiles.first(where: { $0.id == profileID })
        else { return }
        isLoadingRemoteProfile = true
        selectedRemoteProfileID = profileID
        buttonBindings = Self.defaultBindings.merging(profile.mappings.parsedButtonBindings) {
            _, saved in saved
        }
        buttonShortcuts = profile.mappings.parsedButtonShortcuts
        buttonApplicationProfileIDs = profile.mappings.parsedButtonApplicationProfileIDs
        secondaryButtonBindings = profile.mappings.parsedSecondaryButtonBindings
        isLoadingRemoteProfile = false
    }

    @discardableResult
    func registerBluetoothRemote(identifier: UUID) -> UUID {
        if let existing = remoteDeviceProfiles.first(where: { $0.bluetoothIdentifier == identifier }) {
            return existing.id
        }
        if let index = remoteDeviceProfiles.firstIndex(where: {
            $0.bluetoothIdentifier == nil && $0.model == .unknown
        }) {
            remoteDeviceProfiles[index].bluetoothIdentifier = identifier
            return remoteDeviceProfiles[index].id
        }
        let profile = RemoteDeviceProfile(
            bluetoothIdentifier: identifier,
            mappings: mappingsForNewRemote()
        )
        remoteDeviceProfiles.append(profile)
        return profile.id
    }

    @discardableResult
    func registerHIDRemote(fingerprint: String) -> UUID {
        if let existing = remoteDeviceProfiles.first(where: { $0.hidFingerprint == fingerprint }) {
            return existing.id
        }
        let selectedUnboundIndex = remoteDeviceProfiles.firstIndex(where: {
            $0.id == selectedRemoteProfileID && $0.hidFingerprint == nil
        })
        if let index = selectedUnboundIndex ?? remoteDeviceProfiles.firstIndex(where: { $0.hidFingerprint == nil }) {
            let defaultMappings = RemoteDeviceMappings(
                buttonBindings: Self.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
            if remoteDeviceProfiles[index].mappings == defaultMappings,
               let configured = remoteDeviceProfiles.first(where: {
                   $0.id != remoteDeviceProfiles[index].id && $0.mappings != defaultMappings
               }) {
                remoteDeviceProfiles[index].mappings = configured.mappings
            }
            remoteDeviceProfiles[index].hidFingerprint = fingerprint
            return remoteDeviceProfiles[index].id
        }
        let profile = RemoteDeviceProfile(
            hidFingerprint: fingerprint,
            mappings: mappingsForNewRemote()
        )
        remoteDeviceProfiles.append(profile)
        return profile.id
    }

    func profileID(forBluetoothIdentifier identifier: UUID) -> UUID? {
        remoteDeviceProfiles.first(where: { $0.bluetoothIdentifier == identifier })?.id
    }

    func profileID(forHIDFingerprint fingerprint: String) -> UUID? {
        remoteDeviceProfiles.first(where: { $0.hidFingerprint == fingerprint })?.id
    }

    func bindHIDFingerprint(_ fingerprint: String, to profileID: UUID) {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        for candidate in remoteDeviceProfiles.indices where remoteDeviceProfiles[candidate].hidFingerprint == fingerprint {
            remoteDeviceProfiles[candidate].hidFingerprint = nil
        }
        remoteDeviceProfiles[index].hidFingerprint = fingerprint
    }

    private func mappingsForNewRemote() -> RemoteDeviceMappings {
        selectedRemoteProfile?.mappings ?? RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings
        )
    }

    func updateRemoteProfile(
        _ profileID: UUID,
        model: XiaomiRemoteModel,
        customName: String
    ) {
        guard let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }) else { return }
        remoteDeviceProfiles[index].model = model
        remoteDeviceProfiles[index].customName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func updateRemoteProfileModel(_ profileID: UUID, model: XiaomiRemoteModel) {
        guard model != .unknown,
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == profileID }),
              remoteDeviceProfiles[index].model != model
        else { return }
        remoteDeviceProfiles[index].model = model
    }

    func setAction(_ action: ButtonAction, for button: RemoteButton, trigger: ButtonTrigger) {
        guard trigger != .singleClick else {
            setAction(action, for: button)
            return
        }

        var bindings = secondaryButtonBindings[button] ?? [:]
        let shortcut = bindings[trigger]?.shortcut
        let applicationProfileID = bindings[trigger]?.applicationProfileID
        bindings[trigger] = ConfiguredButtonAction(
            action: action,
            shortcut: shortcut,
            applicationProfileID: applicationProfileID
        )
        secondaryButtonBindings[button] = bindings.isEmpty ? nil : bindings
    }

    func setApplicationProfileID(
        _ applicationProfileID: UUID?,
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) {
        guard trigger != .singleClick else {
            buttonApplicationProfileIDs[button] = applicationProfileID
            return
        }
        guard var bindings = secondaryButtonBindings[button], var binding = bindings[trigger] else {
            return
        }
        binding.applicationProfileID = applicationProfileID
        bindings[trigger] = binding
        secondaryButtonBindings[button] = bindings
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

    func hasSecondaryAction(for button: RemoteButton, profileID: UUID?) -> Bool {
        [.doubleClick, .longPress].contains { trigger in
            configuredAction(for: button, trigger: trigger, profileID: profileID).action != .disabled
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
        buttonApplicationProfileIDs = [:]
        secondaryButtonBindings = [:]
        if experimentalContinuousRecordingEnabled {
            continuousRecordingPowerBindingBackup = ConfiguredButtonAction(
                action: .escape,
                shortcut: nil
            )
            setAction(.toggleLongRecording, for: .power, trigger: .singleClick)
        }
    }

    func recordButtonPress(
        control: UsageControl? = nil,
        source: UsageEventSource = .unknown,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) {
        if totalButtonPressCount < .max {
            totalButtonPressCount += 1
        }

        let key = Self.dayKey(for: date, calendar: calendar)
        var statistics = dailyStatistics[key] ?? DailyUsageStatistics()
        if statistics.buttonPressCount < .max {
            statistics.buttonPressCount += 1
        }
        Self.recordActivityProvenance(
            in: &statistics.metadata,
            startingAt: date,
            endingAt: date,
            calendar: calendar
        )
        Self.addCount(1, for: source.rawValue, to: &statistics.metadata.buttonPressCountBySource)
        if let control {
            Self.addCount(
                1,
                for: control.identifier,
                to: &statistics.metadata.buttonPressCountByControl
            )
        }
        Self.addCount(
            1,
            for: calendar.component(.hour, from: date),
            to: &statistics.metadata.buttonPressCountByHour
        )
        dailyStatistics[key] = statistics
    }

    func recordVoiceDuration(
        _ duration: TimeInterval,
        startedAt: Date? = nil,
        source: UsageEventSource = .unknown,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard duration.isFinite, duration > 0 else { return }
        totalVoiceDuration = Self.addingDuration(duration, to: totalVoiceDuration)

        let key = Self.dayKey(for: date, calendar: calendar)
        var statistics = dailyStatistics[key] ?? DailyUsageStatistics()
        statistics.voiceDuration = Self.addingDuration(duration, to: statistics.voiceDuration)
        Self.recordActivityProvenance(
            in: &statistics.metadata,
            startingAt: startedAt ?? date,
            endingAt: date,
            calendar: calendar
        )
        statistics.metadata.voiceSessionCount = Self.addingCount(
            1,
            to: statistics.metadata.voiceSessionCount
        )
        Self.addCount(
            1,
            for: source.rawValue,
            to: &statistics.metadata.voiceSessionCountBySource
        )
        let endHour = calendar.component(.hour, from: date)
        Self.addCount(
            1,
            for: endHour,
            to: &statistics.metadata.voiceSessionCountByEndHour
        )
        Self.addDuration(
            duration,
            for: source.rawValue,
            to: &statistics.metadata.voiceDurationBySource
        )
        Self.addDuration(
            duration,
            for: endHour,
            to: &statistics.metadata.voiceDurationByEndHour
        )
        statistics.metadata.longestVoiceSessionDuration = max(
            statistics.metadata.longestVoiceSessionDuration,
            duration
        )
        statistics.metadata.longestVoiceSessionDurationBySource[source.rawValue] = max(
            statistics.metadata.longestVoiceSessionDurationBySource[source.rawValue] ?? 0,
            duration
        )
        dailyStatistics[key] = statistics

        voiceSessionRanking = Self.normalizedVoiceSessionRanking(
            voiceSessionRanking + [VoiceSessionUsageRecord(
                id: UUID(),
                startedAt: startedAt,
                endedAt: date,
                duration: duration,
                source: source
            )]
        )
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
            return usageStatistics(in: week, calendar: calendar)
        case .total:
            return UsageStatistics(
                buttonPressCount: totalButtonPressCount,
                voiceDuration: totalVoiceDuration
            )
        }
    }

    func dailyUsageStatistics(
        endingAt date: Date = Date(),
        days: Int = 7,
        calendar: Calendar = .current
    ) -> [UsageStatisticsBucket] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: date)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return UsageStatisticsBucket(
                startDate: day,
                statistics: Self.usageStatistics(
                    from: dailyStatistics[Self.dayKey(for: day, calendar: calendar)]
                )
            )
        }
    }

    func weeklyUsageStatistics(
        endingAt date: Date = Date(),
        weeks: Int = 8,
        calendar: Calendar = .current
    ) -> [UsageStatisticsBucket] {
        guard
            weeks > 0,
            let currentWeek = Self.weekInterval(containing: date, calendar: calendar)
        else { return [] }

        return (0..<weeks).reversed().compactMap { offset in
            guard
                let start = calendar.date(
                    byAdding: .day,
                    value: -(offset * 7),
                    to: currentWeek.start
                ),
                let end = calendar.date(byAdding: .day, value: 7, to: start)
            else { return nil }
            return UsageStatisticsBucket(
                startDate: start,
                statistics: usageStatistics(
                    in: DateInterval(start: start, end: end),
                    calendar: calendar
                )
            )
        }
    }

    func weeklyUsageStatisticsSeries(
        endingAt date: Date = Date(),
        recentWeeks: Int = 7,
        calendar: Calendar = .current
    ) -> WeeklyUsageStatisticsSeries {
        let weeklyBuckets = weeklyUsageStatistics(
            endingAt: date,
            weeks: recentWeeks,
            calendar: calendar
        )
        let earlierStatistics = weeklyBuckets.first.map { firstBucket in
            usageStatistics(before: firstBucket.startDate, calendar: calendar)
        } ?? UsageStatistics(buttonPressCount: 0, voiceDuration: 0)
        return WeeklyUsageStatisticsSeries(
            earlierStatistics: earlierStatistics,
            weeklyBuckets: weeklyBuckets
        )
    }

    func usageMetadata(
        for period: UsageStatisticsPeriod,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageStatisticsMetadata {
        switch period {
        case .today:
            return Self.usageMetadata(
                from: dailyStatistics[Self.dayKey(for: date, calendar: calendar)]
            )
        case .thisWeek:
            guard let week = Self.weekInterval(containing: date, calendar: calendar) else {
                return UsageStatisticsMetadata()
            }
            return usageMetadata(in: week, calendar: calendar)
        case .total:
            return dailyStatistics.values.reduce(into: UsageStatisticsMetadata()) { result, statistics in
                Self.merge(Self.usageMetadata(from: statistics), into: &result)
            }
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
        let completedUpdate: Bool
        if
            let previousBuild,
            let previousBuildNumber = Int(previousBuild),
            let currentBuildNumber = Int(currentBuild)
        {
            completedUpdate = currentBuildNumber > previousBuildNumber
        } else {
            completedUpdate = previousBuild == nil && sparkleHadLaunchedBefore
        }

        if defaults.integer(forKey: Keys.onboardingMigrationVersion) < Self.currentOnboardingVersion {
            let hasPersistedOnboardingState =
                defaults.object(forKey: Keys.onboardingCompletedVersion) != nil ||
                defaults.object(forKey: Keys.onboardingStep) != nil ||
                defaults.object(forKey: Keys.onboardingRemoteAvailability) != nil ||
                defaults.object(forKey: Keys.onboardingControlMethod) != nil ||
                defaults.object(forKey: Keys.onboardingVoiceTool) != nil
            let isExistingInstall = previousBuild != nil || sparkleHadLaunchedBefore
            if !isOnboardingComplete, !hasPersistedOnboardingState, isExistingInstall {
                completeOnboarding()
            }
            defaults.set(Self.currentOnboardingVersion, forKey: Keys.onboardingMigrationVersion)
        }

        defaults.set(currentBuild, forKey: Keys.lastLaunchedBuild)
        return completedUpdate
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
            buttonApplicationProfileIDs: Dictionary(
                uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
            ),
            secondaryButtonBindings: Dictionary(
                uniqueKeysWithValues: secondaryButtonBindings.map { button, bindings in
                    (
                        button.rawValue,
                        Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
                    )
                }
            ),
            customApplicationProfiles: customApplicationProfiles,
            applicationLanguage: applicationLanguage,
            showDockIcon: showDockIcon,
            openMainWindowAtLaunch: openMainWindowAtLaunch,
            checksForPreReleaseUpdates: checksForPreReleaseUpdates,
            experimentalContinuousRecordingEnabled: experimentalContinuousRecordingEnabled,
            voiceFnTapModeEnabled: voiceFnTapModeEnabled,
            voiceKeyMode: voiceKeyMode,
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
        let importedApplicationProfileIDs = Dictionary(
            uniqueKeysWithValues: (configuration.buttonApplicationProfileIDs ?? [:]).compactMap { key, value in
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
        buttonApplicationProfileIDs = importedApplicationProfileIDs
        secondaryButtonBindings = importedSecondaryBindings
        customApplicationProfiles = configuration.customApplicationProfiles ?? []
        applicationLanguage = configuration.applicationLanguage
        showDockIcon = configuration.showDockIcon
        if let openMainWindowAtLaunch = configuration.openMainWindowAtLaunch {
            self.openMainWindowAtLaunch = openMainWindowAtLaunch
        }
        if let checksForPreReleaseUpdates = configuration.checksForPreReleaseUpdates {
            self.checksForPreReleaseUpdates = checksForPreReleaseUpdates
        }
        voiceFnTapModeEnabled = configuration.voiceFnTapModeEnabled ?? false
        voiceKeyMode = configuration.voiceKeyMode ?? .function
        if voiceKeyMode != .function {
            voiceFnTapModeEnabled = false
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

    private func saveButtonApplicationProfileIDs() {
        let raw = Dictionary(
            uniqueKeysWithValues: buttonApplicationProfileIDs.map { ($0.key.rawValue, $0.value) }
        )
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Keys.buttonApplicationProfileIDs)
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

    private func saveSelectedRemoteProfileMappings() {
        guard !isLoadingRemoteProfile,
              let selectedRemoteProfileID,
              let index = remoteDeviceProfiles.firstIndex(where: { $0.id == selectedRemoteProfileID })
        else { return }
        remoteDeviceProfiles[index].mappings = RemoteDeviceMappings(
            buttonBindings: buttonBindings,
            buttonShortcuts: buttonShortcuts,
            buttonApplicationProfileIDs: buttonApplicationProfileIDs,
            secondaryButtonBindings: secondaryButtonBindings
        )
    }

    private func saveCustomApplicationProfiles() {
        guard let data = try? JSONEncoder().encode(customApplicationProfiles) else { return }
        defaults.set(data, forKey: Keys.customApplicationProfiles)
    }

    private func saveRemoteDeviceProfiles() {
        guard let data = try? JSONEncoder().encode(remoteDeviceProfiles) else { return }
        defaults.set(data, forKey: Keys.remoteDeviceProfiles)
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
            setApplicationProfileID(
                restored.applicationProfileID,
                for: .power,
                trigger: .singleClick
            )
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

    private func usageStatistics(
        in interval: DateInterval,
        calendar: Calendar
    ) -> UsageStatistics {
        dailyStatistics.reduce(
            into: UsageStatistics(buttonPressCount: 0, voiceDuration: 0)
        ) { result, entry in
            guard
                let day = Self.date(fromDayKey: entry.key, calendar: calendar),
                day >= interval.start,
                day < interval.end
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
    }

    private func usageStatistics(
        before date: Date,
        calendar: Calendar
    ) -> UsageStatistics {
        dailyStatistics.reduce(
            into: UsageStatistics(buttonPressCount: 0, voiceDuration: 0)
        ) { result, entry in
            guard
                let day = Self.date(fromDayKey: entry.key, calendar: calendar),
                day < date
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
    }

    private static func recordActivityProvenance(
        in metadata: inout DailyUsageMetadata,
        startingAt: Date,
        endingAt: Date,
        calendar: Calendar
    ) {
        let firstDate = min(startingAt, endingAt)
        let lastDate = max(startingAt, endingAt)
        metadata.schemaVersion = 1
        metadata.firstActivityAt = metadata.firstActivityAt.map { min($0, firstDate) } ?? firstDate
        metadata.lastActivityAt = metadata.lastActivityAt.map { max($0, lastDate) } ?? lastDate
        metadata.timeZoneIdentifiers.insert(calendar.timeZone.identifier)
        metadata.calendarIdentifiers.insert(String(describing: calendar.identifier))
    }

    private static func usageMetadata(
        from daily: DailyUsageStatistics?
    ) -> UsageStatisticsMetadata {
        guard let metadata = daily?.metadata else { return UsageStatisticsMetadata() }
        var result = UsageStatisticsMetadata(
            firstActivityAt: metadata.firstActivityAt,
            lastActivityAt: metadata.lastActivityAt,
            buttonPressCountByControl: metadata.buttonPressCountByControl,
            buttonPressCountByHour: metadata.buttonPressCountByHour,
            voiceSessionCount: metadata.voiceSessionCount,
            voiceSessionCountByEndHour: metadata.voiceSessionCountByEndHour,
            voiceDurationByEndHour: metadata.voiceDurationByEndHour,
            longestVoiceSessionDuration: max(0, metadata.longestVoiceSessionDuration),
            timeZoneIdentifiers: metadata.timeZoneIdentifiers,
            calendarIdentifiers: metadata.calendarIdentifiers,
            schemaVersions: metadata.schemaVersion > 0 ? [metadata.schemaVersion] : []
        )
        for (rawSource, count) in metadata.buttonPressCountBySource {
            addCount(
                count,
                for: UsageEventSource(rawValue: rawSource) ?? .unknown,
                to: &result.buttonPressCountBySource
            )
        }
        for (rawSource, count) in metadata.voiceSessionCountBySource {
            addCount(
                count,
                for: UsageEventSource(rawValue: rawSource) ?? .unknown,
                to: &result.voiceSessionCountBySource
            )
        }
        for (rawSource, duration) in metadata.voiceDurationBySource {
            addDuration(
                duration,
                for: UsageEventSource(rawValue: rawSource) ?? .unknown,
                to: &result.voiceDurationBySource
            )
        }
        for (rawSource, duration) in metadata.longestVoiceSessionDurationBySource {
            let source = UsageEventSource(rawValue: rawSource) ?? .unknown
            result.longestVoiceSessionDurationBySource[source] = max(
                result.longestVoiceSessionDurationBySource[source] ?? 0,
                max(0, duration)
            )
        }
        return result
    }

    private func usageMetadata(
        in interval: DateInterval,
        calendar: Calendar
    ) -> UsageStatisticsMetadata {
        dailyStatistics.reduce(into: UsageStatisticsMetadata()) { result, entry in
            guard
                let day = Self.date(fromDayKey: entry.key, calendar: calendar),
                day >= interval.start,
                day < interval.end
            else { return }
            Self.merge(Self.usageMetadata(from: entry.value), into: &result)
        }
    }

    private static func merge(
        _ metadata: UsageStatisticsMetadata,
        into result: inout UsageStatisticsMetadata
    ) {
        if let firstActivityAt = metadata.firstActivityAt {
            result.firstActivityAt = result.firstActivityAt.map {
                min($0, firstActivityAt)
            } ?? firstActivityAt
        }
        if let lastActivityAt = metadata.lastActivityAt {
            result.lastActivityAt = result.lastActivityAt.map {
                max($0, lastActivityAt)
            } ?? lastActivityAt
        }
        for (source, count) in metadata.buttonPressCountBySource {
            addCount(count, for: source, to: &result.buttonPressCountBySource)
        }
        for (control, count) in metadata.buttonPressCountByControl {
            addCount(count, for: control, to: &result.buttonPressCountByControl)
        }
        for (hour, count) in metadata.buttonPressCountByHour {
            addCount(count, for: hour, to: &result.buttonPressCountByHour)
        }
        result.voiceSessionCount = addingCount(
            metadata.voiceSessionCount,
            to: result.voiceSessionCount
        )
        for (source, count) in metadata.voiceSessionCountBySource {
            addCount(count, for: source, to: &result.voiceSessionCountBySource)
        }
        for (hour, count) in metadata.voiceSessionCountByEndHour {
            addCount(count, for: hour, to: &result.voiceSessionCountByEndHour)
        }
        for (source, duration) in metadata.voiceDurationBySource {
            addDuration(duration, for: source, to: &result.voiceDurationBySource)
        }
        for (hour, duration) in metadata.voiceDurationByEndHour {
            addDuration(duration, for: hour, to: &result.voiceDurationByEndHour)
        }
        result.longestVoiceSessionDuration = max(
            result.longestVoiceSessionDuration,
            metadata.longestVoiceSessionDuration
        )
        for (source, duration) in metadata.longestVoiceSessionDurationBySource {
            result.longestVoiceSessionDurationBySource[source] = max(
                result.longestVoiceSessionDurationBySource[source] ?? 0,
                duration
            )
        }
        result.timeZoneIdentifiers.formUnion(metadata.timeZoneIdentifiers)
        result.calendarIdentifiers.formUnion(metadata.calendarIdentifiers)
        result.schemaVersions.formUnion(metadata.schemaVersions)
    }

    private static func addCount<Key: Hashable>(
        _ value: UInt64,
        for key: Key,
        to values: inout [Key: UInt64]
    ) {
        values[key] = addingCount(value, to: values[key] ?? 0)
    }

    private static func addDuration<Key: Hashable>(
        _ duration: TimeInterval,
        for key: Key,
        to values: inout [Key: TimeInterval]
    ) {
        values[key] = addingDuration(duration, to: values[key] ?? 0)
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

    private static func normalizedVoiceSessionRanking(
        _ records: [VoiceSessionUsageRecord]
    ) -> [VoiceSessionUsageRecord] {
        Array(
            records
                .filter { $0.duration.isFinite && $0.duration > 0 }
                .sorted {
                    if $0.duration == $1.duration {
                        return $0.endedAt > $1.endedAt
                    }
                    return $0.duration > $1.duration
                }
                .prefix(10)
        )
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
