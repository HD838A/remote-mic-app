import AppKit
import CoreBluetooth
import Foundation

struct AgentConfigurationResult: Codable, Equatable {
    enum Status: String, Codable {
        case configured
        case needsChoice = "needs_choice"
        case permissionRequired = "permission_required"
        case notFound = "not_found"
        case failed
    }

    let status: Status
    let reason: String?
    let controlSource: String?
    let voiceTool: String?
    let gesture: String?
    let candidates: [String]
    let remaining: [String]
}

@MainActor
enum AgentConfigurationCommand {
    private static let backupKey = "onboarding.agent_configuration_backup"

    private struct Options {
        var json = false
        var verify = false
        var automatic = false
        var controlSource: OnboardingControlSource?
        var voiceTool: OnboardingVoiceTool?
    }

    static func run(arguments: [String]) -> Int32 {
        let options = parse(arguments: arguments)
        AppLogger.shared.write(
            "ONBOARDING AI_CONFIG request=true mode=\(options.verify ? "verify" : "configure")"
        )
        let result = options.verify ? verify() : configure(options: options)
        AppLogger.shared.write(
            "ONBOARDING AI_CONFIG outcome=\(result.status.rawValue)" +
                " reason=\(result.reason ?? "none")" +
                " control_source=\(result.controlSource ?? "unknown")" +
                " tool=\(result.voiceTool ?? "unknown")"
        )
        write(result, json: options.json)
        return result.status == .configured || result.status == .permissionRequired ? 0 : 1
    }

    private static func parse(arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                options.json = true
            case "--verify":
                options.verify = true
            case "--auto":
                options.automatic = true
            case "--control-source":
                index += 1
                if index < arguments.count {
                    options.controlSource = OnboardingControlSource(rawValue: arguments[index])
                }
            case "--voice-tool":
                index += 1
                if index < arguments.count {
                    options.voiceTool = OnboardingVoiceTool(rawValue: arguments[index])
                }
            default:
                break
            }
            index += 1
        }
        return options
    }

    private static func configure(options: Options) -> AgentConfigurationResult {
        recoverInterruptedConfigurationIfNeeded()
        let settings = AppSettings()
        let remoteCandidates = connectedRemoteCandidates(settings: settings)
        guard !remoteCandidates.isEmpty else {
            return result(.notFound, reason: "connected_remote", remaining: ["remote"])
        }

        let controlSource: OnboardingControlSource
        if let requested = options.controlSource {
            controlSource = requested
        } else if let selectedProfile = settings.selectedRemoteProfile,
                  let selectedSource = remoteCandidates.first(where: {
                      $0.profileID == selectedProfile.id
                  })?.source {
            controlSource = selectedSource
        } else {
            let sources = Array(Set(remoteCandidates.map(\.source))).sorted {
                $0.rawValue < $1.rawValue
            }
            guard sources.count == 1, let onlySource = sources.first else {
                return result(
                    .needsChoice,
                    reason: "control_source",
                    candidates: sources.map(\.rawValue)
                )
            }
            controlSource = onlySource
        }

        let toolCandidates = availableVoiceTools()
        let voiceTool: OnboardingVoiceTool
        if let requested = options.voiceTool {
            voiceTool = requested
        } else if isAvailable(settings.onboardingVoiceTool),
                  settings.onboardingVoiceTool != .unselected {
            voiceTool = settings.onboardingVoiceTool
        } else if let current = currentInputSourceVoiceTool(from: toolCandidates) {
            voiceTool = current
        } else {
            let running = toolCandidates.filter {
                OnboardingInputSourceSwitcher.runtimeState(for: $0) == .running
            }
            if running.count == 1, let onlyRunning = running.first {
                voiceTool = onlyRunning
            } else if toolCandidates.count == 1 {
                voiceTool = toolCandidates[0]
            } else if toolCandidates.count > 1 {
                return result(
                    .needsChoice,
                    reason: "voice_tool",
                    controlSource: controlSource,
                    candidates: toolCandidates.map(\.rawValue)
                )
            } else {
                voiceTool = .other
            }
        }

        guard let audioDevice = supportedAudioDevice() else {
            return result(
                .notFound,
                reason: "audio_device",
                controlSource: controlSource,
                voiceTool: voiceTool,
                remaining: ["audio_device"]
            )
        }
        guard let plan = OnboardingVoicePairingPlan.resolve(
            tool: voiceTool,
            controlSource: controlSource,
            preferredGesture: nil,
            userBinding: nil,
            forceFunctionKey: true
        ) else {
            return result(
                .failed,
                reason: "pairing_plan",
                controlSource: controlSource,
                voiceTool: voiceTool
            )
        }

        let domainName = Bundle.main.bundleIdentifier ?? "com.hd838a.RemoteMic"
        let defaults = UserDefaults.standard
        let previousDomain = defaults.persistentDomain(forName: domainName)
        let stageSuiteName = "\(domainName).agent-stage.\(UUID().uuidString)"
        guard let stageDefaults = UserDefaults(suiteName: stageSuiteName) else {
            return result(
                .failed,
                reason: "staging_defaults",
                controlSource: controlSource,
                voiceTool: voiceTool
            )
        }

        stageDefaults.setPersistentDomain(previousDomain ?? [:], forName: stageSuiteName)
        let stagedSettings = AppSettings(defaults: stageDefaults)
        if stagedSettings.isOnboardingComplete {
            stagedSettings.prepareOnboardingForAgentConfiguration()
        }
        stagedSettings.setOnboardingControlSource(controlSource)
        stagedSettings.setOnboardingVoiceTool(voiceTool)
        stagedSettings.setOnboardingPreferredGesture(plan.binding.gestureMode)
        stagedSettings.beginOnboardingVoiceTrial(plan)
        stagedSettings.selectedAudioDeviceUID = audioDevice.uid
        stagedSettings.setOnboardingStep(.voiceTest)
        stageDefaults.set(true, forKey: AppSettings.agentConfigurationPendingKey)

        let valid = stagedSettings.onboardingStep == .voiceTest &&
            stagedSettings.onboardingControlSource == controlSource &&
            stagedSettings.onboardingVoiceTool == voiceTool &&
            stagedSettings.stagedVoiceToolBinding == plan.binding &&
            stagedSettings.voiceKeyMode == .function &&
            stagedSettings.selectedAudioDeviceUID == audioDevice.uid
        guard valid else {
            stageDefaults.removePersistentDomain(forName: stageSuiteName)
            restore(previousDomain, in: defaults, name: domainName)
            defaults.removeObject(forKey: backupKey)
            return result(
                .failed,
                reason: "write",
                controlSource: controlSource,
                voiceTool: voiceTool,
                gesture: plan.binding.gestureMode.rawValue
            )
        }

        // Keep the rollback copy in SayAll's own persistent domain. The command
        // may be interrupted after the domain swap and before cleanup; a backup
        // stored only in the temporary suite would be lost with that suite.
        defaults.set(previousDomain ?? [:], forKey: backupKey)
        let stagedDomain = stageDefaults.persistentDomain(forName: stageSuiteName) ?? [:]
        defaults.setPersistentDomain(stagedDomain, forName: domainName)
        guard defaults.persistentDomain(forName: domainName) != nil else {
            stageDefaults.removePersistentDomain(forName: stageSuiteName)
            restore(previousDomain, in: defaults, name: domainName)
            defaults.removeObject(forKey: backupKey)
            return result(
                .failed,
                reason: "commit",
                controlSource: controlSource,
                voiceTool: voiceTool,
                gesture: plan.binding.gestureMode.rawValue
            )
        }
        stageDefaults.removePersistentDomain(forName: stageSuiteName)
        defaults.removeObject(forKey: backupKey)

        let missingPermissions = missingPermissionReasons()
        let status: AgentConfigurationResult.Status = missingPermissions.isEmpty
            ? .configured
            : .permissionRequired
        return result(
            status,
            reason: missingPermissions.isEmpty ? nil : "permissions",
            controlSource: controlSource,
            voiceTool: voiceTool,
            gesture: plan.binding.gestureMode.rawValue,
            remaining: missingPermissions + ["real_voice_test"]
        )
    }

    private static func verify() -> AgentConfigurationResult {
        let settings = AppSettings()
        guard let binding = settings.stagedVoiceToolBinding,
              settings.onboardingStep == .voiceTest,
              settings.voiceKeyMode == .function,
              settings.selectedAudioDeviceUID != ""
        else {
            return result(.failed, reason: "staged_configuration_missing")
        }
        let missingPermissions = missingPermissionReasons()
        let status: AgentConfigurationResult.Status = missingPermissions.isEmpty
            ? .configured
            : .permissionRequired
        return result(
            status,
            controlSource: settings.onboardingControlSource,
            voiceTool: binding.tool,
            gesture: binding.gestureMode.rawValue,
            remaining: missingPermissions + ["real_voice_test"]
        )
    }

    private static func recoverInterruptedConfigurationIfNeeded() {
        let defaults = UserDefaults.standard
        guard let backup = defaults.dictionary(forKey: backupKey) else { return }
        let domainName = Bundle.main.bundleIdentifier ?? "com.hd838a.RemoteMic"
        restore(backup, in: defaults, name: domainName)
        defaults.removeObject(forKey: backupKey)
        AppLogger.shared.write("ONBOARDING AI_CONFIG outcome=rollback reason=interrupted")
    }

    private static func availableVoiceTools() -> [OnboardingVoiceTool] {
        [
            .doubao, .weixin, .vokie, .typeless,
        ].filter { OnboardingInputSourceSwitcher.availability(for: $0) == .available }
    }

    private static func isAvailable(_ tool: OnboardingVoiceTool) -> Bool {
        guard tool != .unselected else { return false }
        switch tool {
        case .other:
            return true
        case .doubao, .weixin, .vokie, .typeless:
            return OnboardingInputSourceSwitcher.availability(for: tool) == .available
        case .unselected:
            return false
        }
    }

    private static func currentInputSourceVoiceTool(
        from candidates: [OnboardingVoiceTool]
    ) -> OnboardingVoiceTool? {
        candidates.first { tool in
            guard tool.preferredInputSourceID != nil else { return false }
            return OnboardingInputSourceSwitcher.isSelected(tool)
        }
    }

    private struct RemoteCandidate {
        let profileID: UUID
        let source: OnboardingControlSource
    }

    private static func connectedRemoteCandidates(
        settings: AppSettings
    ) -> [RemoteCandidate] {
        settings.remoteDeviceProfiles.compactMap { profile in
            guard profile.bluetoothIdentifier != nil || profile.hidFingerprint != nil else {
                return nil
            }
            return RemoteCandidate(
                profileID: profile.id,
                source: controlSource(for: profile.model)
            )
        }
    }

    private static func supportedAudioDevice() -> AudioDeviceInfo? {
        let devices = CoreAudioDeviceCatalog.outputDevices()
        return devices.first { device in
            device.uid == DoubaoAudioDevicePolicy.deviceUID ||
                device.name == DoubaoAudioDevicePolicy.legacyDeviceName ||
                device.name.localizedCaseInsensitiveContains("BlackHole 2ch")
        }
    }

    private static func controlSource(for model: XiaomiRemoteModel) -> OnboardingControlSource {
        if model.isAppleSiriRemote { return .siriRemote }
        if model.isChromecastRemote { return .chromecastRemote }
        return .xiaomiRemote
    }

    private static func missingPermissionReasons() -> [String] {
        var missing: [String] = []
        if CBManager.authorization != .allowedAlways { missing.append("bluetooth") }
        if !HIDRemoteMonitor.isInputMonitoringGranted { missing.append("input_monitoring") }
        if !KeyboardInjector.isAccessibilityTrusted { missing.append("accessibility") }
        return missing
    }

    private static func result(
        _ status: AgentConfigurationResult.Status,
        reason: String? = nil,
        controlSource: OnboardingControlSource? = nil,
        voiceTool: OnboardingVoiceTool? = nil,
        gesture: String? = nil,
        candidates: [String] = [],
        remaining: [String] = []
    ) -> AgentConfigurationResult {
        AgentConfigurationResult(
            status: status,
            reason: reason,
            controlSource: controlSource?.rawValue,
            voiceTool: voiceTool?.rawValue,
            gesture: gesture,
            candidates: candidates,
            remaining: remaining
        )
    }

    private static func restore(
        _ domain: [String: Any]?,
        in defaults: UserDefaults,
        name: String
    ) {
        defaults.removePersistentDomain(forName: name)
        if let domain {
            defaults.setPersistentDomain(domain, forName: name)
        }
    }

    private static func write(_ result: AgentConfigurationResult, json: Bool) {
        if json {
            guard let data = try? JSONEncoder().encode(result) else { return }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            return
        }
        let summary = result.reason.map { "\(result.status.rawValue): \($0)" } ?? result.status.rawValue
        print(summary)
    }
}
