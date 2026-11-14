import Foundation
import Testing
@testable import RemoteMic

@Suite("Application button overrides")
struct ApplicationButtonBindingTests {
    private func makeSettings(
        frontmostBundleIdentifier: @escaping () -> String? = { nil }
    ) -> (AppSettings, UserDefaults, String) {
        let name = "SayAll.ApplicationButtons.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.frontmostApplicationBundleIdentifier = frontmostBundleIdentifier
        return (settings, defaults, name)
    }

    @Test func explicitOverrideWinsOverGlobalAndProfile() {
        let (settings, defaults, name) = makeSettings(frontmostBundleIdentifier: { "com.example.target" })
        defer { defaults.removePersistentDomain(forName: name) }
        let appID = settings.addCustomApplicationProfile(CustomApplicationProfile(
            displayName: "Target", bundleIdentifier: "com.example.target", applicationPath: ""
        ))
        settings.setBaseBinding(
            .init(action: .commandCopy, shortcut: nil),
            for: .ok,
            trigger: .singleClick,
            profileID: nil
        )
        settings.configuredActionOverride = { _, _, _ in
            .init(action: .commandPaste, shortcut: nil)
        }
        #expect(settings.setApplicationButtonOverride(
            .init(action: .arrowLeft, shortcut: nil),
            applicationProfileID: appID,
            button: .ok,
            trigger: .singleClick
        ) == .wrote)
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: nil).action == .arrowLeft)
        #expect(settings.configuredGlobalAction(for: .ok, trigger: .singleClick, profileID: nil).action == .commandPaste)
    }

    @Test func missingEntryFallsBackToCurrentProfile() {
        let (settings, defaults, name) = makeSettings(frontmostBundleIdentifier: { "com.example.target" })
        defer { defaults.removePersistentDomain(forName: name) }
        _ = settings.addCustomApplicationProfile(CustomApplicationProfile(
            displayName: "Target", bundleIdentifier: "com.example.target", applicationPath: ""
        ))
        settings.configuredActionOverride = { _, _, _ in
            .init(action: .commandPaste, shortcut: nil)
        }
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: nil).action == .commandPaste)
    }

    @Test func explicitDisabledDoesNotInheritGlobal() {
        let (settings, defaults, name) = makeSettings(frontmostBundleIdentifier: { "com.example.target" })
        defer { defaults.removePersistentDomain(forName: name) }
        let appID = settings.addCustomApplicationProfile(CustomApplicationProfile(
            displayName: "Target", bundleIdentifier: "com.example.target", applicationPath: ""
        ))
        settings.configuredActionOverride = { _, _, _ in
            .init(action: .commandPaste, shortcut: nil)
        }
        #expect(settings.setApplicationButtonOverride(
            .disabled,
            applicationProfileID: appID,
            button: .ok,
            trigger: .singleClick
        ) == .wrote)
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: nil).action == .disabled)
    }

    @Test func frontmostUnknownFallsBackToGlobal() {
        let state = ApplicationButtonBindingScope.overrideState(
            customMappingEnabled: true,
            supportedButton: true,
            frontmostBundleIdentifier: nil,
            applicationBindings: nil,
            button: .ok,
            trigger: .singleClick
        )
        #expect(state == .globalFallback(reason: "frontmost_unknown"))
    }

    @Test func missingApplicationFallsBackToGlobal() {
        let state = ApplicationButtonBindingScope.overrideState(
            customMappingEnabled: true,
            supportedButton: true,
            frontmostBundleIdentifier: "com.example.other",
            applicationBindings: nil,
            button: .ok,
            trigger: .singleClick
        )
        #expect(state == .globalFallback(reason: "not_configured"))
    }

    @Test func customMappingDisabledFallsBackToGlobal() {
        let state = ApplicationButtonBindingScope.overrideState(
            customMappingEnabled: false,
            supportedButton: true,
            frontmostBundleIdentifier: "com.example.target",
            applicationBindings: nil,
            button: .ok,
            trigger: .singleClick
        )
        #expect(state == .globalFallback(reason: "custom_mapping_disabled"))
    }

    @Test func unsupportedButtonsNeverUseApplicationOverrides() {
        let (settings, defaults, name) = makeSettings(frontmostBundleIdentifier: { "com.example.target" })
        defer { defaults.removePersistentDomain(forName: name) }
        let appID = settings.addCustomApplicationProfile(CustomApplicationProfile(
            displayName: "Target", bundleIdentifier: "com.example.target", applicationPath: ""
        ))
        let writeResult = settings.setApplicationButtonOverride(
            .disabled,
            applicationProfileID: appID,
            button: .tv,
            trigger: .singleClick
        )
        #expect(writeResult == .invalidTarget)
        #expect(settings.applicationButtonOverrideExists(for: .tv, trigger: .singleClick) == false)
    }

    @Test func sanitizeDropsInvalidAndDuplicateBindings() {
        let valid = ApplicationButtonBinding(
            button: .ok,
            trigger: .singleClick,
            configured: .init(action: .commandCopy, shortcut: nil)
        )
        let duplicate = ApplicationButtonBinding(
            button: .ok,
            trigger: .singleClick,
            configured: .init(action: .commandPaste, shortcut: nil)
        )
        let unsupported = ApplicationButtonBinding(
            button: .tv,
            trigger: .singleClick,
            configured: .disabled
        )
        let sanitized = ApplicationButtonBindingScope.sanitize(
            [valid, duplicate, unsupported],
            validateAction: { $0 }
        )
        #expect(sanitized == [valid])
    }

    @Test func clearOverridesRestoresGlobalImmediately() {
        let (settings, defaults, name) = makeSettings(frontmostBundleIdentifier: { "com.example.target" })
        defer { defaults.removePersistentDomain(forName: name) }
        let appID = settings.addCustomApplicationProfile(CustomApplicationProfile(
            displayName: "Target", bundleIdentifier: "com.example.target", applicationPath: ""
        ))
        _ = settings.setApplicationButtonOverride(
            .init(action: .arrowLeft, shortcut: nil),
            applicationProfileID: appID,
            button: .ok,
            trigger: .singleClick
        )
        #expect(settings.clearApplicationButtonOverrides(applicationProfileID: appID) == .cleared)
        #expect(settings.applicationButtonOverrideExists(for: .ok, trigger: .singleClick) == false)
        #expect(settings.customApplicationProfile(id: appID)?.buttonBindings == nil)
    }

    @Test func oldProfileWithoutButtonBindingsInheritsGlobal() throws {
        let (settings, defaults, name) = makeSettingsWithDecodedProfile(
            "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"displayName\":\"Target\",\"bundleIdentifier\":\"com.example.target\",\"applicationPath\":\"\",\"focusStrategy\":\"none\"}]"
        )
        defer { defaults.removePersistentDomain(forName: name) }
        settings.frontmostApplicationBundleIdentifier = { "com.example.target" }
        settings.customMappingEnabled = true
        settings.configuredActionOverride = { _, _, _ in
            .init(action: .commandCopy, shortcut: nil)
        }
        #expect(settings.customApplicationProfiles.first?.buttonBindings == nil)
        #expect(settings.configuredAction(for: .ok, trigger: .singleClick, profileID: nil).action == .commandCopy)
    }

    @Test func importRejectsInvalidApplicationButtonReference() throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let appID = UUID()
        let payload = try configurationData(
            appID: appID,
            binding: """
            {"button":"ok","trigger":"singleClick","configured":{"action":"openCustomApplication","applicationProfileID":"00000000-0000-0000-0000-000000000002","shortcut":null}}
            """
        )
        try settings.importConfiguration(from: payload)
        #expect(settings.customApplicationProfiles.first?.buttonBindings == nil)
        #expect(settings.configurationImportNotice?.rejectedEntryStorageKeys.contains("customApplicationProfiles") == true)
    }

    @Test func completeSnapshotAcceptsEmptyApplicationButtonBindings() throws {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.addCustomApplicationProfile(CustomApplicationProfile(
            displayName: "Target",
            bundleIdentifier: "com.example.target",
            applicationPath: "",
            buttonBindings: []
        ))
        let snapshot = try settings.completeConfigurationSnapshot()
        let validated = try settings.validatedCompleteConfigurationSnapshot(snapshot)
        #expect(validated.count > 0)
    }

    private func makeSettingsWithDecodedProfile(_ json: String) -> (AppSettings, UserDefaults, String) {
        let name = "SayAll.ApplicationButtons.Decoded.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(Data(json.utf8), forKey: "customApplicationProfiles")
        return (AppSettings(defaults: defaults), defaults, name)
    }

    private func configurationData(appID: UUID, binding: String) throws -> Data {
        let json = """
        {
          "formatVersion": 2,
          "gainDB": 0,
          "selectedAudioDeviceUID": "",
          "customMappingEnabled": true,
          "buttonBindings": {},
          "buttonShortcuts": {},
          "secondaryButtonBindings": {},
          "customApplicationProfiles": [{
            "id": "\(appID.uuidString)",
            "displayName": "Target",
            "bundleIdentifier": "com.example.target",
            "applicationPath": "",
            "focusStrategy": "none",
            "buttonBindings": [\(binding)]
          }],
          "applicationLanguage": "zh-Hans",
          "showDockIcon": true
        }
        """
        return try #require(json.data(using: .utf8))
    }
}
