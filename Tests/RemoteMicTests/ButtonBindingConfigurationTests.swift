import AppKit
import Foundation
import Testing
@testable import RemoteMic
#if canImport(SayAllButtonProfiles)
import SayAllButtonProfiles
#endif

@Suite("Unified button configuration", .serialized)
struct ButtonBindingConfigurationTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: TestUserDefaults(suiteName: "UnifiedButtons.\(UUID().uuidString)")!)
    }

    @Test(arguments: [true, false]) func saveRecoveryDoesNotReloadConfirmedSuccess(success: Bool) {
        var reloads = 0
        var reads = 0
        let result = ButtonMappingWriteRecovery.perform(write: { success }, reload: { reloads += 1; return true }, matches: { reads += 1; return false })
        #expect(result == (success ? .saved : .failed))
        #expect(reloads == (success ? 0 : 1))
        #expect(reads == (success ? 0 : 1))
    }

    @Test func reloadFailureRemainsUnknownWithoutComparingStaleValue() {
        var compared = false
        let result = ButtonMappingWriteRecovery.perform(write: { false }, reload: { false }, matches: { compared = true; return true })
        #expect(result == .unknown)
        #expect(!compared)
    }

    @Test func staleSuccessReceiptCannotClearNewFailure() {
        let target = ButtonMappingSaveTarget(profileID: UUID(), deviceID: UUID(), button: .back, trigger: .singleClick)
        var state = ButtonMappingSaveState()
        state.record(.saved, retry: .action(.disabled), target: target)
        let receipt = state.receipt
        state.record(.failed, retry: .action(.disabled), target: target)
        state.clearSuccess(receipt)
        #expect(state.outcome == .failed)
        #expect(state.retry != nil)
        #expect(state.target == target)
        state.record(.saved, retry: .action(.disabled), target: target)
        state.clearSuccess(state.receipt)
        #expect(state.outcome == nil)
        #expect(state.retry == nil)
    }

    @Test func actionChangeHoldFeedbackOutlivesTheSuccessReceipt() {
        let target = ButtonMappingSaveTarget(profileID: UUID(), deviceID: UUID(), button: .back, trigger: .singleClick)
        var state = ButtonMappingSaveState()
        state.record(.saved, retry: .action(.disabled), target: target)
        state.holdClearedByActionChange = true
        state.clearSuccess(state.receipt)
        #expect(state.outcome == nil)
        #expect(!state.holdClearedByActionChange)

        state.record(.saved, retry: .action(.disabled), target: target)
        state.holdClearFailedByActionChange = true
        state.clearSuccess(state.receipt)
        #expect(state.outcome == nil)
        #expect(state.holdClearFailedByActionChange)

        state.record(.saved, retry: .action(.disabled), target: target)
        #expect(!state.holdClearFailedByActionChange)
        #expect(!state.holdClearedByActionChange)
    }

    @Test func baseDirectEditPersistsDisabledEscapeAndHoldAcrossRestart() throws {
        let defaults = try #require(TestUserDefaults(suiteName: "Autosave.\(UUID().uuidString)"))
        let source = AppSettings(defaults: defaults)
        let device = source.selectedRemoteProfileID
        #expect(source.writeBaseBinding(.disabled, for: .back, trigger: .singleClick, profileID: device))
        #expect(source.configuredBaseAction(for: .back, trigger: .singleClick).action == .disabled)
        #expect(source.writeBaseBinding(.init(action: .escape, shortcut: nil), for: .back, trigger: .singleClick, profileID: device))
        #expect(source.writeHoldMode(.once, for: .back, profileID: device))
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.configuredBaseAction(for: .back, trigger: .singleClick).action == .escape)
        #expect(reopened.interactionSettings.modes[RemoteButton.back.rawValue] == "once")
        #expect(!source.writeHoldMode(.repeatSingle, for: .back, profileID: UUID()))
        #expect(source.writeHoldMode(.singleHold, for: .right, profileID: device))
        #expect(source.reloadBaseHoldModes())
        #expect(source.interactionSettings.mode(for: .right) == .singleHold)
        #expect(!source.writeHoldMode(.longHold, for: .up, profileID: device))
        #expect(source.interactionSettings.mode(for: .up) == .once)
    }

    @Test func mappingProfileSnapshotKeepsUnsetEntriesInherited() throws {
        let defaults = try #require(TestUserDefaults(suiteName: "ProfileSnapshot.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let device = settings.selectedRemoteProfileID
        settings.setBaseBinding(.init(action: .arrowRight, shortcut: nil),
            for: .back, trigger: .singleClick, profileID: device)
        settings.setBaseBinding(.disabled, for: .up, trigger: .singleClick, profileID: device)
        settings.setHoldMode(.repeatSingle, for: .back)

        let unset = try #require(RemoteButton.allCases.flatMap { button in
            ButtonTrigger.allCases.map { (button, $0) }
        }.first {
            settings.configuredBaseAction(for: $0.0, trigger: $0.1, profileID: device).action == .disabled &&
                !settings.hasExplicitBaseBinding(for: $0.0, trigger: $0.1, profileID: device)
        })
        let holdUnset = try #require(RemoteButton.allCases.first {
            settings.interactionSettings.modes[$0.rawValue] == nil
        })

        let snapshot = settings.mappingProfileSnapshot(deviceID: device) { _ in true }
        #expect(snapshot.bindings.contains {
            $0.button == .back && $0.trigger == .singleClick && $0.configured.action == .arrowRight
        })
        #expect(snapshot.bindings.contains {
            $0.button == .up && $0.trigger == .singleClick && $0.configured.action == .disabled
        })
        #expect(!snapshot.bindings.contains { $0.button == unset.0 && $0.trigger == unset.1 })
        #expect(snapshot.holdModes[RemoteButton.back.rawValue] == "repeatSingle")
        #expect(snapshot.holdModes[holdUnset.rawValue] == nil)
    }

    @Test func publicBuildHidesProfileActionsAndQueriesStayUnavailable() {
        #if !canImport(SayAllButtonProfiles)
        let integration = MacroFeatureIntegration()
        #expect(!integration.isButtonProfilesVisible)
        #expect(!integration.supportsMappingProfileAutosave)
        #expect(integration.mappingProfiles(device: nil).isEmpty)
        #expect(integration.createMappingProfile(named: "Unavailable", copying: nil, bindings: [], holdModes: [:]) == nil)
        if case .unavailable = integration.displayProfileBinding(device: nil, profile: UUID(), button: .back, trigger: .singleClick) {} else { Issue.record("Missing component must be unavailable") }
        #endif
    }

    @Test func futureHostPayloadDisplaysButCannotBeSilentlyRewritten() throws {
        let value = ConfiguredButtonAction(action: .commandCopy, shortcut: nil)
        let encoded = try JSONEncoder().encode(value)
        #expect(MappingHostBindingCodec.decode(encoded)?.isEditable == true)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["futureField"] = ["mustKeep": true]
        let future = try JSONSerialization.data(withJSONObject: json)
        #expect(MappingHostBindingCodec.decode(future)?.configured == value)
        #expect(MappingHostBindingCodec.decode(future)?.isEditable == false)
        #expect(MappingHostBindingCodec.decode(Data("broken".utf8)) == nil)
    }

    #if SAYALL_BUTTON_PROFILE_AUTOSAVE && SAYALL_UNIFIED_BUTTON_CONFIGURATION && SAYALL_BUTTON_PROFILE_BINDING_TEXT
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"] != nil))
    @MainActor func mappingProfileAdapterPreservesReadOnlyDisplayAndCompleteCopy() throws {
        // The binary integration runner supplies an isolated storage root.
        let root = try #require(ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"])
        #expect(root.hasPrefix("/"))
        let integration = MacroFeatureIntegration(localeIdentifier: "en")
        integration.loadProfilesForScreenshot()
        integration.updateButtonProfilesAccess(.authorized)
        let disabled = UnifiedButtonBinding(remoteProfileID: nil, button: .ok, trigger: .singleClick, configured: .disabled)
        let id = try #require(integration.createMappingProfile(named: "Integration", copying: nil,
            bindings: [disabled], holdModes: ["ok": "once"]))
        let copy = try #require(integration.createMappingProfile(named: "Integration copy", copying: id,
            bindings: [], holdModes: [:]))
        let holdModes = try #require(integration.createMappingProfile(named: "Hold modes", copying: nil,
            bindings: [], holdModes: ["right": "singleHold", "back": "repeatLong"]))
        #if SAYALL_BUTTON_PROFILE_DIRECTIONAL_HOLD
        #expect(integration.supportedProfileHoldModes ==
            [.once, .repeatSingle, .repeatLong, .singleHold, .longHold])
        #expect(integration.profileHoldMode(profile: holdModes, button: .right) == "singleHold")
        #expect(integration.profileHoldMode(profile: holdModes, button: .back) == "repeatLong")
        #expect(integration.writeProfileHoldMode(.singleHold, profile: holdModes, button: .right))
        #expect(integration.writeProfileHoldMode(.longHold, profile: holdModes, button: .back))
        #expect(integration.writeProfileHoldMode(.repeatSingle, profile: holdModes, button: .right))
        #else
        #expect(integration.supportedProfileHoldModes == [.once, .repeatSingle, .repeatLong])
        #expect(integration.profileHoldMode(profile: holdModes, button: .right) == nil)
        #expect(integration.profileHoldMode(profile: holdModes, button: .back) == "repeatLong")
        #expect(!integration.writeProfileHoldMode(.singleHold, profile: holdModes, button: .right))
        #expect(!integration.writeProfileHoldMode(.longHold, profile: holdModes, button: .back))
        #expect(integration.writeProfileHoldMode(.repeatSingle, profile: holdModes, button: .right))
        #endif
        let matchesDisabled = integration.profileBindingMatches(.disabled, profile: copy, button: .ok, trigger: .singleClick)
        let matchesInherited = integration.profileBindingMatches(.disabled, profile: copy, button: .ok, trigger: .doubleClick)
        let matchesMissingHold = integration.profileHoldModeMatches(.once, profile: copy, button: .back)
        let matchesExplicitHold = integration.profileHoldModeMatches(.once, profile: copy, button: .ok)
        #expect(matchesDisabled)
        #expect(!matchesInherited)
        #expect(!matchesMissingHold)
        #expect(matchesExplicitHold)
        integration.updateButtonProfilesAccess(.requiresPlus)
        #expect(integration.mappingProfiles(device: UUID()).contains { $0.id == id })
        if case let .explicit(value) = integration.displayProfileBinding(device: nil, profile: copy, button: .ok, trigger: .singleClick) {
            #expect(value.configured == .disabled)
        } else { Issue.record("Explicit disabled was lost") }
        if case .inherited = integration.displayProfileBinding(device: nil, profile: copy, button: .ok, trigger: .doubleClick) {} else { Issue.record("Inheritance was lost") }
        if case let .explicit(mode) = integration.displayProfileHoldMode(profile: copy, button: .ok) { #expect(mode == .once) }
        else { Issue.record("Hold was lost") }
        #expect(!integration.writeProfileBinding(nil, profile: copy, button: .ok, trigger: .singleClick, displayName: nil))
        #expect(integration.profileBinding(device: nil, profile: copy, button: .ok, trigger: .singleClick) == nil)
        integration.updateButtonProfilesAccess(.authorized)
        #expect(integration.writeProfileBinding(nil, profile: copy, button: .ok, trigger: .singleClick, displayName: nil))
        #expect(integration.reloadMappingProfiles())
        if case .inherited = integration.displayProfileBinding(device: nil, profile: copy, button: .ok, trigger: .singleClick) {} else { Issue.record("Clear did not persist") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"] != nil))
    @MainActor func migratesResolvableLegacyShortcutReferencesAndKeepsMissingOnes() async throws {
        let rootPath = try #require(ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"])
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let privateDirectory = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        let documentURL = privateDirectory.appendingPathComponent("local-automation-profiles.json")
        let shortcutID = "shortcut.migration.\(UUID().uuidString.lowercased())"
        let missingID = "shortcut.missing.\(UUID().uuidString.lowercased())"
        let now = ISO8601DateFormatter().string(from: Date())
        var document = (try? JSONSerialization.jsonObject(with: Data(contentsOf: documentURL))) as? [String: Any]
            ?? ["formatVersion": 1, "focusProfiles": [], "keyboardShortcuts": []]
        var shortcuts = document["keyboardShortcuts"] as? [[String: Any]] ?? []
        shortcuts.append([
            "id": shortcutID,
            "displayName": "Migration Copy",
            "keyCode": 8,
            "keyLabel": "C",
            "modifiers": ["command"],
            "createdAt": now,
            "updatedAt": now,
        ])
        document["keyboardShortcuts"] = shortcuts
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: documentURL, options: .atomic)

        let selfContainedShortcut = CustomKeyboardShortcut(
            keyCode: 48,
            modifierFlags: [.command],
            keyLabel: "Tab"
        )
        let selfContainedAction = ConfiguredButtonAction(
            action: .customShortcut,
            shortcut: selfContainedShortcut
        )
        let selfContainedPayload = try JSONEncoder().encode(selfContainedAction)
        let selfContainedHost = RemoteMicHostActionReference(
            id: "host.action.customShortcut",
            displayName: "Tab",
            payload: selfContainedPayload
        )
        let profileID = UUID()
        let profileDocumentURL = root.appendingPathComponent("button-profiles.json")
        var profileDocument = (try? JSONSerialization.jsonObject(with: Data(contentsOf: profileDocumentURL))) as? [String: Any]
            ?? ["formatVersion": 2, "profiles": [], "selections": [], "applicationRules": []]
        var profiles = profileDocument["profiles"] as? [[String: Any]] ?? []
        let defaultID: String
        if let existingDefault = profiles.first(where: {
            $0["usesGeneratedDefaultName"] as? Bool == true
        })?["id"] as? String {
            defaultID = existingDefault
        } else {
            defaultID = UUID().uuidString
            profiles.append([
                "id": defaultID,
                "name": "Default",
                "usesGeneratedDefaultName": true,
                "source": "local",
                "bindings": [],
            ])
        }
        let migrationProfile = RemoteMicButtonProfile(
            id: profileID,
            remoteProfileID: nil,
            name: "Migration",
            bindings: [
                .init(button: .home, trigger: .singleClick): .shortcut(profileKey: shortcutID),
                .init(button: .home, trigger: .doubleClick): .shortcut(profileKey: missingID),
                .init(button: .home, trigger: .longPress): .host(selfContainedHost),
            ]
        )
        profiles.append(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(migrationProfile)
        ) as? [String: Any] ?? [:])
        profileDocument["profiles"] = profiles
        profileDocument["formatVersion"] = 2
        profileDocument["applicationRules"] = profileDocument["applicationRules"] ?? []
        var selections = profileDocument["selections"] as? [[String: Any]] ?? []
        if !selections.contains(where: { ($0["remoteProfileID"] as? String) == nil }) {
            let selection = RemoteMicButtonProfileSelection(
                remoteProfileID: nil,
                manualProfileID: profileID,
                defaultProfileID: try #require(UUID(uuidString: defaultID))
            )
            selections.append(try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(selection)
            ) as? [String: Any] ?? [:])
        }
        profileDocument["selections"] = selections
        try JSONSerialization.data(withJSONObject: profileDocument, options: [.sortedKeys])
            .write(to: profileDocumentURL, options: .atomic)

        let integration = MacroFeatureIntegration(localeIdentifier: "en")
        integration.loadProfilesForScreenshot()
        integration.updateButtonProfilesAccess(.allowed(validUntil: .distantFuture))
        // The controller's initial reload is asynchronous and loads the shortcut library
        // separately from the synchronous profile helper. Wait until the legacy ref resolves.
        var resolved = false
        for _ in 0..<60 {
            if case let .explicit(value) = integration.displayProfileBinding(
                device: nil, profile: profileID, button: .home, trigger: .singleClick
            ), value.configured?.action == .customShortcut,
                value.configured?.shortcut?.keyCode == 8 {
                resolved = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(resolved)

        // Other suites share the process-wide storage root; wait out a transient
        // pending import before asserting the migration result.
        var migration: (reference: RemoteMicHostActionReference,
                        configured: ConfiguredButtonAction)?
        for _ in 0..<60 {
            integration.migrateLegacyShortcutBindingsIfNeeded()
            if case let .host(reference)? = integration.rawProfileBinding(
                device: nil, profile: profileID, button: .home, trigger: .singleClick
            ), let configured = MappingHostBindingCodec.decode(reference.payload)?.configured {
                migration = (reference, configured)
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let (reference, migrated) = migration else {
            Issue.record("Resolvable shortcut was not migrated to a self-contained host action")
            return
        }
        #expect(reference.displayName.contains("⌘"))
        #expect(migrated.action == .customShortcut)
        #expect(migrated.shortcut?.keyCode == 8)
        #expect(migrated.shortcut?.modifierFlags.contains(.command) == true)
        #expect(integration.profileBinding(device: nil, profile: profileID,
            button: .home, trigger: .singleClick) == migrated)
        #expect(integration.rawProfileBinding(device: nil, profile: profileID,
            button: .home, trigger: .doubleClick) == .shortcut(profileKey: missingID))
        #expect(integration.rawProfileBinding(device: nil, profile: profileID,
            button: .home, trigger: .longPress) == .host(selfContainedHost))
        #expect(integration.profileBinding(device: nil, profile: profileID,
            button: .home, trigger: .longPress) == selfContainedAction)

        // A second pass must not rewrite the already self-contained action.
        integration.migrateLegacyShortcutBindingsIfNeeded()
        guard case let .host(afterSecondPass)? = integration.rawProfileBinding(
            device: nil, profile: profileID, button: .home, trigger: .singleClick
        ) else {
            Issue.record("Migration was not idempotent")
            return
        }
        #expect(afterSecondPass == reference)
    }
    #endif

    #if canImport(SayAllButtonProfiles) && SAYALL_UNIFIED_BUTTON_CONFIGURATION && !SAYALL_BUTTON_PROFILE_AUTOSAVE
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"] != nil))
    @MainActor func legacyComponentKeepsProfileListVisibleAndSupportsCreateAndCopy() throws {
        // The binary integration runner supplies an isolated storage root.
        _ = try #require(ProcessInfo.processInfo.environment["SAYALL_MACRO_STORAGE_ROOT"])
        let integration = MacroFeatureIntegration(localeIdentifier: "en")
        integration.updateButtonProfilesAccess(.allowed(validUntil: .distantFuture))
        integration.prepareMappingDevice(nil)

        let created = try #require(integration.createMappingProfile(named: "Legacy create", copying: nil,
            bindings: [.init(remoteProfileID: nil, button: .ok, trigger: .singleClick, configured: .disabled)],
            holdModes: ["ok": "repeatLong"]))
        let listed = integration.mappingProfiles(device: nil)
        #expect(listed.contains { $0.id == created })
        #expect(listed.contains { $0.isDefault && $0.id != created })

        guard case let .explicit(value) = integration.displayProfileBinding(device: nil, profile: created,
            button: .ok, trigger: .singleClick) else {
            Issue.record("Legacy explicit binding was not displayed")
            return
        }
        #expect(value.configured == .disabled)
        #expect(!value.isEditable)
        if case .inherited = integration.displayProfileBinding(device: nil, profile: created,
            button: .back, trigger: .singleClick) {} else { Issue.record("Legacy inheritance was not displayed") }
        if integration.supportsProfileHoldModes {
            #expect(integration.profileHoldMode(profile: created, button: .ok) == "repeatLong")
        }

        // Exact copies keep future payloads and unreferenced shortcut types instead of
        // rewriting them as host actions.
        let futurePayload = Data(#"{"action":"commandCopy","futureField":true}"#.utf8)
        let futureHost = RemoteMicHostActionReference(id: "host.action.future",
            displayName: "Future", payload: futurePayload)
        integration.setRawProfileBinding(.host(futureHost), profile: created,
            button: .back, trigger: .longPress)
        integration.setRawProfileBinding(.shortcut(profileKey: "legacy.missing"), profile: created,
            button: .up, trigger: .longPress)

        let copy = try #require(integration.createMappingProfile(named: "Legacy copy", copying: created,
            bindings: [], holdModes: [:]))
        #expect(integration.mappingProfiles(device: nil).contains { $0.id == copy })
        #expect(integration.rawProfileBinding(device: nil, profile: copy, button: .back,
            trigger: .longPress) == .host(futureHost))
        #expect(integration.rawProfileBinding(device: nil, profile: copy, button: .up,
            trigger: .longPress) == .shortcut(profileKey: "legacy.missing"))
        guard case let .explicit(copied) = integration.displayProfileBinding(device: nil, profile: copy,
            button: .ok, trigger: .singleClick) else {
            Issue.record("Legacy copied binding was not displayed")
            return
        }
        #expect(copied.configured == .disabled)
        if case let .explicit(copiedFuture) = integration.displayProfileBinding(device: nil, profile: copy,
            button: .back, trigger: .longPress) {
            #expect(copiedFuture.configured == .init(action: .commandCopy, shortcut: nil))
            #expect(!copiedFuture.isEditable)
        } else { Issue.record("Legacy future payload was not displayed read-only") }
        if case .unavailable = integration.displayProfileBinding(device: nil, profile: copy,
            button: .up, trigger: .longPress) {} else {
            Issue.record("Legacy missing shortcut must be unavailable")
        }
        // 执行路径不能因为一条失效引用就把物理按键变成死键；返回 nil 让基础映射继续执行。
        #expect(integration.profileBinding(device: nil, profile: copy,
            button: .up, trigger: .longPress) == nil)

        let invalidHost = RemoteMicHostActionReference(
            id: "host.action.invalid",
            displayName: "Invalid",
            payload: Data(#"{"action":"customShortcut"}"#.utf8)
        )
        integration.setRawProfileBinding(.host(invalidHost), profile: copy,
            button: .home, trigger: .singleClick)
        #expect(integration.profileBinding(device: nil, profile: copy,
            button: .home, trigger: .singleClick) == nil)

        integration.setRawProfileBinding(.focus(profileKey: "focus.missing"), profile: copy,
            button: .home, trigger: .doubleClick)
        #expect(integration.profileBinding(device: nil, profile: copy,
            button: .home, trigger: .doubleClick) == nil)

        // 2.0.8 的方案自定义快捷键写入自包含 host payload；升级到 2.0.9 后必须原样执行和显示。
        let v208Shortcut = CustomKeyboardShortcut(
            keyCode: 8,
            modifierFlags: [.command],
            keyLabel: "C"
        )
        let v208Action = ConfiguredButtonAction(action: .customShortcut, shortcut: v208Shortcut)
        let v208Payload = try JSONEncoder().encode(v208Action)
        integration.setRawProfileBinding(.host(RemoteMicHostActionReference(
            id: "host.action.customShortcut",
            displayName: "Copy",
            payload: v208Payload
        )), profile: copy, button: .home, trigger: .longPress)
        #expect(integration.profileBinding(device: nil, profile: copy,
            button: .home, trigger: .longPress) == v208Action)
        guard case let .explicit(upgraded) = integration.displayProfileBinding(
            device: nil, profile: copy, button: .home, trigger: .longPress
        ) else {
            Issue.record("2.0.8 shortcut payload was not displayed after upgrade")
            return
        }
        #expect(upgraded.configured == v208Action)
        if integration.supportsProfileHoldModes {
            #expect(integration.profileHoldMode(profile: copy, button: .ok) == "repeatLong")
        }

        // Non-members keep the display list and values, but everything stays read-only.
        integration.updateButtonProfilesAccess(.requiresPlus)
        let visible = integration.mappingProfiles(device: nil)
        #expect(visible.contains { $0.id == created })
        #expect(visible.contains { $0.id == copy })
        if case let .explicit(readOnly) = integration.displayProfileBinding(device: nil, profile: copy,
            button: .ok, trigger: .singleClick) {
            #expect(!readOnly.isEditable)
        } else { Issue.record("Legacy non-member display was lost") }
        if integration.supportsProfileHoldModes {
            if case let .explicit(mode) = integration.displayProfileHoldMode(profile: copy, button: .ok) {
                #expect(mode == .repeatLong)
            } else { Issue.record("Legacy non-member hold was lost") }
        }
    }
    #endif

    @Test(arguments: ["saved", "recovered", "failed", "unknown"])
    func holdReconciliationRunsOnlyAfterConfirmedAction(mode: String) {
        var holdWrites = 0
        let result = ButtonMappingWriteRecovery.saveAction(write: { mode == "saved" },
            reload: { mode != "unknown" }, matches: { mode == "recovered" },
            reconcileHold: { holdWrites += 1 })
        #expect(holdWrites == (mode == "saved" || mode == "recovered" ? 1 : 0))
        #expect(result == (mode == "unknown" ? .unknown : mode == "failed" ? .failed : .saved))
    }

    @Test func holdFailureRetryWritesOnlyHoldAndRejectsAnotherTarget() {
        let target = ButtonMappingSaveTarget(profileID: UUID(), deviceID: UUID(), button: .ok, trigger: nil)
        let other = ButtonMappingSaveTarget(profileID: UUID(), deviceID: target.deviceID, button: .ok, trigger: nil)
        var state = ButtonMappingSaveState()
        state.record(.failed, retry: .hold(.repeatSingle), target: target)
        var actions = 0
        var holds = 0
        #expect(!state.performRetry(target: other, writeAction: { _ in actions += 1 }, writeHold: { _ in holds += 1 }))
        var retriedMode: RemoteButtonHoldMode?
        let accepted = state.performRetry(target: target, writeAction: { _ in actions += 1 }, writeHold: { mode in
            retriedMode = mode
            holds += 1
        })
        #expect(accepted)
        #expect(retriedMode == .repeatSingle)
        #expect(actions == 0)
        #expect(holds == 1)
        state = .init()
        #expect(!state.performRetry(target: target, writeAction: { _ in actions += 1 }, writeHold: { _ in holds += 1 }))
        #expect(holds == 1)
    }

    @Test func explicitDisabledOverrideNeverInherits() {
        let settings = settings()
        settings.setAction(.commandCopy, for: .home)
        settings.configuredActionOverride = { _, _, _ in .disabled }
        #expect(settings.configuredAction(for: .home, trigger: .singleClick) == .disabled)
        settings.configuredActionOverride = { _, _, _ in nil }
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).action == .commandCopy)
    }

    @Test func migrationPreservesOldValuesAndIsIdempotent() throws {
        let settings = settings()
        settings.setAction(.commandPaste, for: .home)
        let binding = UnifiedButtonBinding(remoteProfileID: settings.selectedRemoteProfileID,
            button: .home, trigger: .singleClick,
            configured: ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.example"))
        try settings.migrateLegacyMacroBindings([binding])
        try settings.migrateLegacyMacroBindings([binding, binding])
        #expect(settings.unifiedBaseBindings.count == 1)
        #expect(settings.buttonBindings[.home] == .commandPaste)
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).macroID == "macro.example")
    }

    @Test func deletingMacroReferencesClearsUnifiedAndSecondaryBindings() {
        let settings = settings()
        let macro = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.deleted")
        settings.setBaseBinding(macro, for: .home, trigger: .singleClick, profileID: nil)
        settings.secondaryButtonBindings = [.ok: [.doubleClick: macro]]
        settings.removeMacroReferences(to: "macro.deleted")
        #expect(settings.unifiedBaseBindings.isEmpty)
        #expect(settings.secondaryButtonBindings.isEmpty)
    }

    @Test func historicalMissingReferencesAreRemovedAcrossDevicesAndSurviveRestart() throws {
        let suite = "UnifiedButtons.HistoricalCleanup.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let first = settings.registerHIDRemote(fingerprint: "cleanup-first")
        let second = settings.registerHIDRemote(fingerprint: "cleanup-second")
        let missing = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "local.missing")
        let valid = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "local.valid")
        settings.setBaseBinding(missing, for: .home, trigger: .singleClick, profileID: first)
        settings.setBaseBinding(valid, for: .up, trigger: .singleClick, profileID: second)
        settings.setBaseBinding(.disabled, for: .down, trigger: .singleClick, profileID: second)
        settings.secondaryButtonBindings = [.ok: [.doubleClick: missing, .longPress: valid]]
        let deviceProfiles = settings.remoteDeviceProfiles.map { profile in
            var updated = profile
            updated.mappings.secondaryButtonBindings["home"] = ["doubleClick": missing, "longPress": valid]
            return updated
        }
        defaults.set(try JSONEncoder().encode(deviceProfiles), forKey: "remoteDeviceProfiles")
        let cleanup = AppSettings(defaults: defaults)
        cleanup.removeMacroReferences(to: "local.missing")
        cleanup.removeMacroReferences(to: "local.missing")
        let reopened = AppSettings(defaults: defaults)
        #expect(!reopened.unifiedBaseBindings.contains { $0.configured.macroID == "local.missing" })
        #expect(reopened.unifiedBaseBindings.contains { $0.configured == valid })
        #expect(reopened.unifiedBaseBindings.contains { $0.configured == .disabled })
        #expect(reopened.remoteDeviceProfiles.allSatisfy { profile in
            profile.mappings.secondaryButtonBindings.values.allSatisfy {
                !$0.values.contains { $0.macroID == "local.missing" }
            }
        })
        #expect(reopened.remoteDeviceProfiles.contains { profile in
            profile.mappings.secondaryButtonBindings.values.contains { $0.values.contains(valid) }
        })
    }

    @Test func devicesAndTriggersRemainIndependent() {
        let settings = settings()
        let first = UUID(), second = UUID()
        settings.setBaseBinding(ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
                                for: .home, trigger: .singleClick, profileID: first)
        settings.setBaseBinding(.disabled, for: .home, trigger: .doubleClick, profileID: first)
        settings.setBaseBinding(ConfiguredButtonAction(action: .returnKey, shortcut: nil),
                                for: .home, trigger: .singleClick, profileID: second)
        #expect(settings.action(for: .home, profileID: first) == .commandCopy)
        #expect(settings.action(for: .home, profileID: second) == .returnKey)
        #expect(settings.configuredAction(for: .home, trigger: .doubleClick, profileID: first) == .disabled)
    }

    @Test func selectedProfileKeepsShortcutMappingsAfterReload() throws {
        let suite = "UnifiedButtons.SelectedProfile.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let profileID = settings.registerHIDRemote(fingerprint: "rc001-mapping")
        settings.selectRemoteProfile(profileID)
        let shortcut = CustomKeyboardShortcut(keyCode: 48, modifierFlags: .command, keyLabel: "Tab")
        let configured = ConfiguredButtonAction(action: .customShortcut, shortcut: shortcut)

        for button in [RemoteButton.tv, .home, .menu, .volumeDown] {
            settings.setBaseBinding(configured, for: button, trigger: .singleClick, profileID: profileID)
        }

        let profile = try #require(settings.remoteDeviceProfiles.first { $0.id == profileID })
        #expect(profile.mappings.parsedButtonBindings[.tv] == .customShortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.tv] == shortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.home] == shortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.menu] == shortcut)
        #expect(profile.mappings.parsedButtonShortcuts[.volumeDown] == shortcut)

        let reopened = AppSettings(defaults: defaults)
        reopened.selectRemoteProfile(profileID)
        for button in [RemoteButton.tv, .home, .menu, .volumeDown] {
            #expect(reopened.configuredAction(for: button, trigger: .singleClick, profileID: profileID) == configured)
        }
    }

    @Test func chosenCombinationActionPersistsForOnlyOriginalButton() throws {
        let suite = "UnifiedButtons.MacroReturn.\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let originalDevice = settings.registerHIDRemote(fingerprint: "macro-return-original-device")
        let otherDevice = settings.registerHIDRemote(fingerprint: "macro-return-other-device")
        let baseline = settings.configuredBaseAction(for: .ok, trigger: .doubleClick, profileID: originalDevice)
        let otherBaseline = settings.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: otherDevice)
        let chosen = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "local.return-choice")
        settings.setBaseBinding(chosen, for: .ok, trigger: .singleClick, profileID: originalDevice)

        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: originalDevice) == chosen)
        #expect(reopened.configuredBaseAction(for: .ok, trigger: .doubleClick, profileID: originalDevice) == baseline)
        #expect(reopened.configuredBaseAction(for: .ok, trigger: .singleClick, profileID: otherDevice) == otherBaseline)
    }

    @Test func versionTwoBackupRetainsMacroAndShortcutParameters() throws {
        let source = settings(), target = settings()
        let shortcut = CustomKeyboardShortcut(keyCode: 0, modifierFlags: .command, keyLabel: "A")
        let binding = ConfiguredButtonAction(action: .combinationAction, shortcut: shortcut, macroID: "macro.example")
        source.setBaseBinding(binding, for: .home, trigger: .singleClick, profileID: nil)
        let data = try source.exportedConfigurationData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 2)
        try target.importConfiguration(from: data)
        #expect(target.unifiedBaseBindings.first?.configured == binding)
    }

    @Test func invalidMacroReferenceIsRejectedDuringImport() throws {
        let source = settings(), target = settings()
        source.setBaseBinding(ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "invalid\n"),
                              for: .home, trigger: .singleClick, profileID: nil)
        try target.importConfiguration(from: source.exportedConfigurationData())
        #expect(target.unifiedBaseBindings.first?.configured == .disabled)
    }
    @Test func unavailableReferenceRemainsExplicitAcrossSceneChanges() {
        let settings = settings()
        settings.setBaseBinding(ConfiguredButtonAction(action: .commandCopy, shortcut: nil),
            for: .home, trigger: .singleClick, profileID: nil)
        var active: ConfiguredButtonAction? = ConfiguredButtonAction(
            action: .combinationAction, shortcut: nil, macroID: "macro.deleted")
        settings.configuredActionOverride = { _, _, _ in active }
        #expect(settings.configuredAction(for: .home, trigger: .singleClick).macroID == "macro.deleted")
        #expect(settings.action(for: .home) == .combinationAction)
        active = .disabled
        #expect(settings.action(for: .home) == .disabled)
        active = nil
        #expect(settings.action(for: .home) == .commandCopy)
    }

    @Test func rejectedMacroDoesNotReleaseHIDOrInventPermissionFailure() throws {
        let settings = settings()
        settings.customMappingEnabled = true
        let profileID = try #require(settings.selectedRemoteProfileID)
        settings.setBaseBinding(ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.deleted"),
            for: .ok, trigger: .singleClick, profileID: profileID)
        var attempts = 0
        var logs: [String] = []
        let monitor = HIDRemoteMonitor(settings: settings, profileID: profileID,
            ownsEventSuppressor: false, runtimePermissions: { true },
            actionPerformer: { _, _, _ in attempts += 1; return false },
            diagnosticLogger: { logs.append($0) })
        monitor.connectSimulatedDevice(fingerprint: "macro-test", profileID: profileID)
        let originalStatus = monitor.status
        let press = Data([0x28, 0, 0, 0, 0, 0])
        monitor.handleSimulatedReport(reportID: 1, data: press)
        monitor.handleSimulatedReport(reportID: 1, data: press)
        #expect(attempts == 1)
        #expect(monitor.status == originalStatus)
        #expect(logs.contains { $0.contains("HID ACTION failed") })
        monitor.disconnectSimulatedDevice()
    }

    @Test func resetOneDeviceShadowsLegacyUnscopedMacro() throws {
        let settings = settings()
        let first = settings.registerBluetoothRemote(identifier: UUID())
        let second = settings.registerBluetoothRemote(identifier: UUID())
        let macro = ConfiguredButtonAction(action: .combinationAction, shortcut: nil, macroID: "macro.example")
        try settings.migrateLegacyMacroBindings([UnifiedButtonBinding(remoteProfileID: nil,
            button: .home, trigger: .singleClick, configured: macro)])
        settings.selectRemoteProfile(first)
        settings.resetBindings()
        #expect(settings.configuredBaseAction(for: .home, trigger: .singleClick, profileID: first).action == AppSettings.defaultBindings[.home])
        #expect(settings.configuredBaseAction(for: .home, trigger: .singleClick, profileID: second) == macro)
    }

}
