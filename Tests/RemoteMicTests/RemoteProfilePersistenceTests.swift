import Foundation
import SayAllMacRemoteCore
import Testing
@testable import RemoteMic

/// A device profile is what draws a card in the connection page, and nothing in the app can
/// delete one. So the question these tests pin is not "is a profile created" but "what does a
/// peripheral have to prove before one is created for it".
///
/// The reported symptom: two cards, the real remote plus a permanent "小米遥控器" with no model
/// and no battery. The runtime log showed the second one was a peripheral advertising the
/// generic name `MI RC` — on the app's name whitelist — that connected, answered reads, and
/// disconnected without ever completing the ATVV handshake.
@Suite("Remote device profile persistence")
struct RemoteProfilePersistenceTests {
    private struct Scope {
        let settings: AppSettings
        let defaults: UserDefaults
        let name: String

        func tearDown() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private static func scopedSettings(_ label: String) throws -> Scope {
        let name = "RemoteProfilePersistenceTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: name))
        return Scope(settings: AppSettings(defaults: defaults), defaults: defaults, name: name)
    }

    /// 运行期创建一对共享稳定身份的 HID/BLE 档案。不能预写入默认值后启动，
    /// 那样加载期去重会先把它们合并，无法验证互补合并本身。
    private static func registerComplementaryPair(
        in settings: AppSettings,
        identity: String = "TESTSERIAL003"
    ) -> (hid: UUID, ble: UUID) {
        let hid = settings.registerHIDRemote(fingerprint: "hid-rc003")
        settings.updateRemoteProfileModel(hid, model: .rc003)
        settings.updateRemoteProfileHardwareIdentity(hid, serialNumber: identity)
        let ble = settings.registerBluetoothRemote(identifier: UUID())
        settings.updateRemoteProfileModel(ble, model: .rc003)
        settings.updateRemoteProfileHardwareIdentity(ble, serialNumber: identity)
        return (hid, ble)
    }

    /// Seed the field shape reported after 2.0.8: a selected default BLE-only record next to
    /// a BLE+HID record that owns the user's action and hold customisations.
    private static func seedBothProfileAndDefaultBLEDuplicate(
        in scope: Scope,
        bleCustomName: String = "",
        bleBindings: [RemoteMic.RemoteButton: ButtonAction] = AppSettings.defaultBindings,
        bleInteractionSettings: RemoteButtonInteractionSettings? = nil,
        identityMatches: Bool = true,
        lowercaseIdentityFingerprint: Bool = false
    ) throws -> (
        both: UUID,
        ble: UUID,
        bothBluetoothIdentifier: UUID,
        bleBluetoothIdentifier: UUID
    ) {
        let bothID = UUID()
        let bleID = UUID()
        let bothBluetoothIdentifier = UUID()
        let bleBluetoothIdentifier = UUID()
        // HID 侧哈希的是系统属性的原始字面量，大小写不被保证。用 `candidates` 里的大写
        // 之外的变体模拟小写档案，验证档案合并路径也接受同一套判定。
        let uppercaseFingerprint = RemoteIdentityFingerprint.fingerprint(
            for: bleBluetoothIdentifier
        )
        let matchingHIDFingerprint: String
        if lowercaseIdentityFingerprint,
           let lowercase = RemoteIdentityFingerprint.candidates(for: bleBluetoothIdentifier)
               .first(where: { $0 != uppercaseFingerprint }) {
            matchingHIDFingerprint = lowercase
        } else {
            matchingHIDFingerprint = uppercaseFingerprint
        }
        var bothBindings = AppSettings.defaultBindings
        bothBindings[.menu] = .openCodex
        let shortcut = CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.command],
            keyLabel: "K"
        )
        let applicationProfileID = UUID()
        let interactionSettings = RemoteButtonInteractionSettings(
            modes: ["up": RemoteButtonHoldMode.repeatSingle.rawValue],
            migratedRepeatButtons: ["up"]
        )
        let both = RemoteDeviceProfile(
            id: bothID,
            model: .rc003,
            bluetoothIdentifier: bothBluetoothIdentifier,
            hidFingerprint: identityMatches ? matchingHIDFingerprint : "hid-other-remote",
            mappings: RemoteDeviceMappings(
                buttonBindings: bothBindings,
                buttonShortcuts: [.menu: shortcut],
                buttonApplicationProfileIDs: [.menu: applicationProfileID],
                secondaryButtonBindings: [
                    .menu: [
                        .longPress: ConfiguredButtonAction(
                            action: .openCodex,
                            shortcut: nil
                        )
                    ]
                ],
                buttonRapidPressEnabled: [.menu: true],
                interactionSettings: interactionSettings
            )
        )
        let ble = RemoteDeviceProfile(
            id: bleID,
            model: .rc003,
            customName: bleCustomName,
            bluetoothIdentifier: bleBluetoothIdentifier,
            mappings: RemoteDeviceMappings(
                buttonBindings: bleBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:],
                interactionSettings: bleInteractionSettings
            )
        )
        scope.defaults.set(
            try JSONEncoder().encode([both, ble]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(bleID.uuidString, forKey: "selectedRemoteProfileID")
        return (bothID, bleID, bothBluetoothIdentifier, bleBluetoothIdentifier)
    }

    @MainActor
    @Test(arguments: [true, false])
    func lateHIDReadyReconcilesAnAlreadyConnectedBLECard(hidStillReady: Bool) async throws {
        let scope = try Self.scopedSettings("late-hid-ready")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(in: scope)
        let settings = AppSettings(defaults: scope.defaults)
        let model = BridgeAppModel(settings: settings)
        let bridge = Self.bridge(ids.bleBluetoothIdentifier, settings: settings, delegate: model)
        let originalMappings = try #require(settings.remoteDeviceProfiles.first { $0.id == ids.both }).mappings

        model.bluetoothBridge(bridge, didChange: .ready("Test 2 Pro"))
        #expect(model.isRemoteConnected(ids.ble))
        #expect(!model.isRemoteConnected(ids.both))

        model.recordHIDButtonStatus(LocalizedMessage("button_mapping.status.connected_fallback"), profileID: ids.both)
        if !hidStillReady {
            model.recordHIDButtonStatus(LocalizedMessage("button_mapping.status.searching"), profileID: ids.both)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(model.isRemoteConnected(ids.ble) == !hidStillReady)
        #expect(model.isRemoteConnected(ids.both) == hidStillReady)
        #expect(model.remoteButtonReadiness[ids.both] == (hidStillReady ? .ready : .checking))
        #expect(settings.remoteDeviceProfiles.count == (hidStillReady ? 1 : 2))
        #expect(settings.remoteDeviceProfiles.first { $0.id == ids.both }?.mappings == originalMappings)
        #expect(settings.selectedRemoteProfileID == (hidStillReady ? ids.both : ids.ble))
    }

    @Test func defaultBLEOnlyDuplicateBesideBothProfileIsMerged() throws {
        let scope = try Self.scopedSettings("both-ble-default-duplicate")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(in: scope)
        let settings = AppSettings(defaults: scope.defaults)
        settings.updateRemoteProfileSystemName(ids.ble, name: "小米蓝牙语音遥控器")

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: [ids.both]
        )

        #expect(replacements[ids.ble] == ids.both)
        #expect(settings.remoteDeviceProfiles.count == 1)
        let merged = try #require(settings.remoteDeviceProfiles.first)
        #expect(merged.id == ids.both)
        #expect(merged.hidFingerprint == RemoteIdentityFingerprint.fingerprint(
            for: ids.bleBluetoothIdentifier
        ))
        #expect(merged.bluetoothIdentifier == ids.bleBluetoothIdentifier)
        #expect(merged.lastKnownBluetoothName == "小米蓝牙语音遥控器")
        #expect(merged.mappings.parsedButtonBindings[.menu] == .openCodex)
        #expect(merged.mappings.parsedButtonShortcuts[.menu]?.keyLabel == "K")
        #expect(merged.mappings.parsedButtonApplicationProfileIDs[.menu] != nil)
        #expect(merged.mappings.parsedSecondaryButtonBindings[.menu]?[.longPress]?
            .action == .openCodex)
        #expect(merged.mappings.parsedButtonRapidPressEnabled[.menu] == true)
        #expect(merged.mappings.interactionSettings?.mode(for: .up) == .repeatSingle)
        #expect(settings.profileID(forBluetoothIdentifier: ids.bleBluetoothIdentifier) == ids.both)
        #expect(settings.profileID(forBluetoothIdentifier: ids.bothBluetoothIdentifier) == nil)
        #expect(settings.selectedRemoteProfileID == ids.both)
        #expect(settings.action(for: .menu) == .openCodex)

        let backupData = try #require(scope.defaults.data(
            forKey: AppSettings.mergedRemoteProfilesBackupKey
        ))
        let backup = try JSONDecoder().decode([RemoteDeviceProfile].self, from: backupData)
        #expect(backup.count == 2)

        #expect(settings.restoreMergedRemoteProfilesBackup())
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == ids.ble })?
            .mappings.parsedButtonBindings == AppSettings.defaultBindings)
    }

    @Test func defaultBLEOnlyDuplicateMergesWhenHIDFingerprintUsesLowercaseLiteral() throws {
        let scope = try Self.scopedSettings("both-ble-lowercase-identity")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(
            in: scope,
            lowercaseIdentityFingerprint: true
        )
        let settings = AppSettings(defaults: scope.defaults)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: [ids.both]
        )

        #expect(replacements[ids.ble] == ids.both)
        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.remoteDeviceProfiles.first?.id == ids.both)
    }

    @Test func BLEOnlyDuplicateWithMismatchedIdentityIsNotMerged() throws {
        let scope = try Self.scopedSettings("both-ble-identity-mismatch")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(
            in: scope,
            identityMatches: false
        )
        let settings = AppSettings(defaults: scope.defaults)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: [ids.both]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func BLEOnlyDuplicateWithCustomNameIsNotMerged() throws {
        let scope = try Self.scopedSettings("both-ble-custom-name")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(
            in: scope,
            bleCustomName: "客卧遥控器"
        )
        let settings = AppSettings(defaults: scope.defaults)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: [ids.both]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func BLEOnlyDuplicateWithCustomActionIsNotMerged() throws {
        let scope = try Self.scopedSettings("both-ble-custom-action")
        defer { scope.tearDown() }
        var customBindings = AppSettings.defaultBindings
        customBindings[.menu] = .openCodex
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(
            in: scope,
            bleBindings: customBindings
        )
        let settings = AppSettings(defaults: scope.defaults)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: [ids.both]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func BLEOnlyDuplicateWithCustomHoldIsNotMerged() throws {
        let scope = try Self.scopedSettings("both-ble-custom-hold")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(
            in: scope,
            bleInteractionSettings: RemoteButtonInteractionSettings(modes: ["up": "once"])
        )
        let settings = AppSettings(defaults: scope.defaults)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: [ids.both]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func BLEOnlyDuplicateWithCustomTimingIsNotMerged() throws {
        let scope = try Self.scopedSettings("both-ble-custom-timing")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(
            in: scope,
            bleInteractionSettings: RemoteButtonInteractionSettings(
                doubleClickMilliseconds: 240
            )
        )
        let settings = AppSettings(defaults: scope.defaults)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: [ids.both]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func BLEOnlyDuplicateNeedsALiveBothProfileAndOneConnectedSide() throws {
        let scope = try Self.scopedSettings("both-ble-liveness")
        defer { scope.tearDown() }
        let ids = try Self.seedBothProfileAndDefaultBLEDuplicate(in: scope)
        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.ble],
            activeHIDProfileIDs: []
        ).isEmpty)
        #expect(settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [],
            activeHIDProfileIDs: [ids.both]
        ).isEmpty)
        #expect(settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ids.both, ids.ble],
            activeHIDProfileIDs: [ids.both]
        ).isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func duplicateHIDProfilesAreCollapsedWithoutLosingSelectedMappings() throws {
        let scope = try Self.scopedSettings("duplicate-hid")
        defer { scope.tearDown() }
        let fingerprint = "apple-siri-remote-test"
        let selectedID = UUID()
        let duplicateID = UUID()
        var configuredBindings = AppSettings.defaultBindings
        configuredBindings[.tv] = .disabled
        let configuredMappings = RemoteDeviceMappings(
            buttonBindings: configuredBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
        let selected = RemoteDeviceProfile(
            id: selectedID,
            model: .appleSiriRemoteA2854,
            hidFingerprint: fingerprint,
            mappings: configuredMappings
        )
        let duplicate = RemoteDeviceProfile(
            id: duplicateID,
            model: .unknown,
            hidFingerprint: fingerprint,
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([selected, duplicate]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(selectedID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.remoteDeviceProfiles.first?.id == selectedID)
        #expect(settings.selectedRemoteProfileID == selectedID)
        var migratedMappings = try #require(settings.selectedRemoteProfile?.mappings)
        #expect(migratedMappings.interactionSettings?.mode(for: .back) == .repeatSingle)
        migratedMappings.interactionSettings = nil
        #expect(migratedMappings == configuredMappings)

        let backupData = try #require(scope.defaults.data(
            forKey: AppSettings.mergedRemoteProfilesBackupKey
        ))
        let backup = try JSONDecoder().decode([RemoteDeviceProfile].self, from: backupData)
        #expect(backup.count == 2)
        #expect(backup.first(where: { $0.id == selectedID })?.mappings == configuredMappings)
        #expect(scope.defaults.string(
            forKey: AppSettings.mergedRemoteProfileSelectionBackupKey
        ) == selectedID.uuidString)
    }

    /// 现场数据的形状：同一台 Apple Remote 留下了两条档案，两条都把序列号存成了设备名
    /// （`C08JV3H32330`），但 `hidFingerprint` 不同——指纹会随接口、重新配对或指纹算法
    /// 版本变化，所以按指纹去重永远认不出这是同一台设备，卡片上就是两张一模一样的卡片。
    @Test func theSameSerialNumberCollapsesAcrossFingerprintChanges() throws {
        let scope = try Self.scopedSettings("duplicate-serial")
        defer { scope.tearDown() }
        let legacyID = UUID()
        let currentID = UUID()
        var configuredBindings = AppSettings.defaultBindings
        configuredBindings[.tv] = .disabled
        let configuredMappings = RemoteDeviceMappings(
            buttonBindings: configuredBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
        let legacy = RemoteDeviceProfile(
            id: legacyID,
            model: .appleSiriRemoteA2854,
            customName: "C08JV3H32330",
            hidFingerprint: "older-fingerprint-scheme",
            mappings: configuredMappings
        )
        let current = RemoteDeviceProfile(
            id: currentID,
            model: .appleSiriRemoteA2854,
            hidFingerprint: "newer-fingerprint-scheme",
            hardwareIdentity: RemoteDeviceIdentity.token(serialNumber: "C08JV3H32330"),
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([legacy, current]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(legacyID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.remoteDeviceProfiles.first?.id == legacyID)
        #expect(settings.remoteDeviceProfiles.first?.hardwareIdentity
            == RemoteDeviceIdentity.token(serialNumber: "C08JV3H32330"))
        var migratedMappings = try #require(settings.selectedRemoteProfile?.mappings)
        migratedMappings.interactionSettings = nil
        #expect(migratedMappings == configuredMappings)
    }

    /// 两台序列号不同的遥控器不能合并，否则会丢一台设备的映射。
    @Test func differentSerialNumbersStaySeparate() throws {
        let scope = try Self.scopedSettings("two-serials")
        defer { scope.tearDown() }
        let first = RemoteDeviceProfile(
            model: .appleSiriRemoteA2854,
            customName: "C08JV3H32330",
            hidFingerprint: "first",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let second = RemoteDeviceProfile(
            model: .appleSiriRemoteA2854,
            customName: "DL1GHATQ17FC",
            hidFingerprint: "second",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([first, second]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(first.id.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    /// 运行期重复项要立刻收敛，而且留下的是**正在用**的那条：连接状态、编辑目标都挂在它身上。
    @Test func runtimeCollapseKeepsTheConnectedProfileAndMovesItsReferences() throws {
        let scope = try Self.scopedSettings("runtime-collapse")
        defer { scope.tearDown() }
        let stale = RemoteDeviceProfile(
            model: .appleSiriRemoteA2854,
            customName: "C08JV3H32330",
            hidFingerprint: "older-fingerprint-scheme",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([stale]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(stale.id.uuidString, forKey: "selectedRemoteProfileID")
        let settings = AppSettings(defaults: scope.defaults)

        let liveID = settings.registerAppleSiriRemote(fingerprint: "newer-fingerprint-scheme")
        #expect(settings.updateRemoteProfileHardwareIdentity(
            liveID, serialNumber: "C08JV3H32330"
        ))
        #expect(settings.remoteDeviceProfiles.count == 2)

        let replacements = settings.collapseDuplicateRemoteProfiles(preferring: [liveID])

        #expect(replacements[stale.id] == liveID)
        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.remoteDeviceProfiles.first?.id == liveID)
        #expect(settings.selectedRemoteProfileID == liveID)
        // 序列号是身份不是显示名：留下来的标题不能变成一串序列号。
        #expect(settings.remoteDeviceProfiles.first?.customName.isEmpty == true)
    }

    /// One physical RC003 can leave an HID-only profile and a BLE-only profile. The card
    /// used to ask the BLE profile for HID readiness and stay at "状态确认中"; merging the
    /// pair keeps the HID monitor, mappings and selection on one record. The merge requires
    /// a shared stable identity so two different remotes cannot be paired by shape alone.
    @Test func complementaryHIDAndBLEProfilesOfTheSameModelAreMerged() throws {
        let scope = try Self.scopedSettings("complementary-pair")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.hid)
        settings.setAction(.openCodex, for: .menu)
        settings.updateRemoteProfileSystemName(pair.ble, name: "小米蓝牙语音遥控器")

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        #expect(settings.remoteDeviceProfiles.count == 1)
        let merged = try #require(settings.remoteDeviceProfiles.first)
        #expect(merged.id == pair.hid)
        #expect(merged.hidFingerprint == "hid-rc003")
        #expect(merged.bluetoothIdentifier != nil)
        #expect(merged.lastKnownBluetoothName == "小米蓝牙语音遥控器")
        #expect(merged.mappings.parsedButtonBindings[.menu] == .openCodex)
        #expect(settings.selectedRemoteProfileID == pair.hid)

        let backupData = try #require(scope.defaults.data(
            forKey: AppSettings.mergedRemoteProfilesBackupKey
        ))
        let backup = try JSONDecoder().decode([RemoteDeviceProfile].self, from: backupData)
        #expect(backup.count == 2)
        #expect(backup.first(where: { $0.id == pair.hid })?.mappings.parsedButtonBindings[.menu]
            == .openCodex)
        #expect(scope.defaults.string(
            forKey: AppSettings.mergedRemoteProfileSelectionBackupKey
        ) == pair.hid.uuidString)
    }

    @Test func complementaryMergeKeepsHIDCustomInteractionSettings() throws {
        let scope = try Self.scopedSettings("complementary-hid-interaction")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.hid)
        let custom = RemoteButtonInteractionSettings(doubleClickMilliseconds: 240)
        settings.interactionSettings = custom

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        #expect(settings.remoteDeviceProfiles.first?.mappings.interactionSettings == custom)
    }

    @Test func complementaryMergeCarriesCustomInteractionSettingsFromBLE() throws {
        let scope = try Self.scopedSettings("complementary-ble-interaction")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.ble)
        let custom = RemoteButtonInteractionSettings(longPressMilliseconds: 480)
        settings.interactionSettings = custom
        settings.selectRemoteProfile(pair.hid)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        let mergedSettings = try #require(
            settings.remoteDeviceProfiles.first?.mappings.interactionSettings
        )
        #expect(mergedSettings.doubleClickMilliseconds == custom.doubleClickMilliseconds)
        #expect(mergedSettings.longPressMilliseconds == custom.longPressMilliseconds)
        #expect(mergedSettings.migratedRepeatButtons?.isEmpty == false)
    }

    @Test func complementaryMergeCombinesActionAndInteractionConfigurations() throws {
        let scope = try Self.scopedSettings("complementary-combined-config")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.hid)
        let custom = RemoteButtonInteractionSettings(doubleClickMilliseconds: 240)
        settings.interactionSettings = custom
        settings.selectRemoteProfile(pair.ble)
        let shortcut = CustomKeyboardShortcut(
            keyCode: 40,
            modifierFlags: [.command, .shift],
            keyLabel: "K"
        )
        let applicationProfileID = UUID()
        settings.setAction(.customShortcut, for: .menu)
        settings.setShortcut(shortcut, for: .menu)
        settings.setApplicationProfileID(applicationProfileID, for: .menu, trigger: .singleClick)
        settings.setAllowsRapidPress(true, for: .menu)
        settings.selectRemoteProfile(pair.hid)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        let merged = try #require(settings.remoteDeviceProfiles.first)
        #expect(merged.mappings.parsedButtonBindings[.menu] == .customShortcut)
        #expect(merged.mappings.parsedButtonShortcuts[.menu] == shortcut)
        #expect(merged.mappings.parsedButtonApplicationProfileIDs[.menu] == applicationProfileID)
        #expect(merged.mappings.parsedButtonRapidPressEnabled[.menu] == true)
        #expect(merged.mappings.interactionSettings == custom)
        #expect(settings.action(for: .menu) == .customShortcut)
        #expect(settings.buttonShortcuts[.menu] == shortcut)
    }

    @Test func complementaryMergePreservesMigratedModesWhenAdoptingCustomTiming() throws {
        let scope = try Self.scopedSettings("complementary-migrated-modes")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.hid)
        settings.interactionSettings = RemoteButtonInteractionSettings(
            modes: ["up": RemoteButtonHoldMode.repeatSingle.rawValue],
            migratedRepeatButtons: ["up"]
        )
        settings.selectRemoteProfile(pair.ble)
        let custom = RemoteButtonInteractionSettings(longPressMilliseconds: 480)
        settings.interactionSettings = custom
        settings.selectRemoteProfile(pair.hid)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        let merged = try #require(settings.remoteDeviceProfiles.first)
        #expect(merged.mappings.interactionSettings?.longPressMilliseconds == 480)
        #expect(merged.mappings.interactionSettings?.modes["up"]
            == RemoteButtonHoldMode.repeatSingle.rawValue)
        #expect(merged.mappings.interactionSettings?.migratedRepeatButtons?.contains("up") == true)
    }

    @Test func complementaryMergeReloadsMappingsForTheKeptSelectedProfile() throws {
        let scope = try Self.scopedSettings("complementary-reload-selected")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.ble)
        settings.setAction(.openCodex, for: .menu)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        #expect(settings.selectedRemoteProfileID == pair.hid)
        // 合并写入存储后，当前执行/编辑内存态也必须立即刷新。
        #expect(settings.action(for: .menu) == .openCodex)
    }

    @Test func nonNilDefaultInteractionSettingsDoNotBlockComplementaryMerge() throws {
        let scope = try Self.scopedSettings("complementary-default-interaction")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.hid)
        settings.interactionSettings = RemoteButtonInteractionSettings()
        settings.selectRemoteProfile(pair.ble)
        let custom = RemoteButtonInteractionSettings(longPressMilliseconds: 480)
        settings.interactionSettings = custom
        settings.selectRemoteProfile(pair.hid)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        #expect(settings.remoteDeviceProfiles.first?.mappings.interactionSettings == custom)
    }

    @Test func unidentifiedComplementaryProfilesStaySeparate() throws {
        let scope = try Self.scopedSettings("complementary-unidentified")
        defer { scope.tearDown() }
        let mappings = RemoteDeviceMappings(
            buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
        let hid = RemoteDeviceProfile(model: .rc003, hidFingerprint: "hid-rc003", mappings: mappings)
        let ble = RemoteDeviceProfile(model: .rc003, bluetoothIdentifier: UUID(), mappings: mappings)
        scope.defaults.set(try JSONEncoder().encode([hid, ble]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(hid.id.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)
        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ble.id],
            activeHIDProfileIDs: [hid.id]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func transientDisplaySelectionIsNotPersistedWhenItsProfileIsMerged() throws {
        let scope = try Self.scopedSettings("transient-selection-merge")
        defer { scope.tearDown() }
        let settings = scope.settings
        let preferred = settings.registerHIDRemote(fingerprint: "preferred-rc001")
        settings.updateRemoteProfileModel(preferred, model: .rc001)
        settings.selectRemoteProfile(preferred)

        let pair = Self.registerComplementaryPair(in: settings, identity: "TESTSERIAL-TRANSIENT")
        settings.selectRemoteProfile(pair.ble, persistSelection: false)
        #expect(settings.selectedRemoteProfileID == pair.ble)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        #expect(settings.selectedRemoteProfileID == pair.hid)
        #expect(scope.defaults.string(
            forKey: "selectedRemoteProfileID"
        ) == preferred.uuidString)

        let afterRestart = AppSettings(defaults: scope.defaults)
        #expect(afterRestart.selectedRemoteProfileID == preferred)
    }

    @Test func persistedSelectionIsRemappedWhenItsProfileIsMergedDuringTransientDisplay() throws {
        let scope = try Self.scopedSettings("persisted-selection-remap")
        defer { scope.tearDown() }
        let settings = scope.settings
        let transient = settings.registerHIDRemote(fingerprint: "transient-rc001")
        settings.updateRemoteProfileModel(transient, model: .rc001)
        let pair = Self.registerComplementaryPair(in: settings, identity: "TESTSERIAL-REMAP")
        settings.selectRemoteProfile(pair.ble)
        settings.selectRemoteProfile(transient, persistSelection: false)
        #expect(settings.selectedRemoteProfileID == transient)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements[pair.ble] == pair.hid)
        #expect(scope.defaults.string(
            forKey: "selectedRemoteProfileID"
        ) == pair.hid.uuidString)

        let afterRestart = AppSettings(defaults: scope.defaults)
        #expect(afterRestart.selectedRemoteProfileID == pair.hid)
    }

    @Test func mergeBackupCanBeRestored() throws {
        let scope = try Self.scopedSettings("merge-backup-restore")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings, identity: "TESTSERIAL-RESTORE")
        settings.selectRemoteProfile(pair.hid)
        settings.setAction(.openCodex, for: .menu)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )
        #expect(replacements[pair.ble] == pair.hid)
        #expect(settings.remoteDeviceProfiles.count == 1)

        #expect(settings.restoreMergedRemoteProfilesBackup())
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(settings.selectedRemoteProfileID == pair.hid)
        #expect(settings.action(for: .menu) == .openCodex)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == pair.ble })?
            .mappings.parsedButtonBindings == AppSettings.defaultBindings)
    }

    @Test func complementaryProfilesOfDifferentModelsStaySeparate() throws {
        let scope = try Self.scopedSettings("complementary-models")
        defer { scope.tearDown() }
        let hid = RemoteDeviceProfile(
            model: .rc003,
            hidFingerprint: "hid-rc003",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let ble = RemoteDeviceProfile(
            model: .rc001,
            bluetoothIdentifier: UUID(),
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([hid, ble]), forKey: "remoteDeviceProfiles")

        let settings = AppSettings(defaults: scope.defaults)
        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ble.id],
            activeHIDProfileIDs: [hid.id]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func ambiguousComplementaryProfilesStaySeparate() throws {
        let scope = try Self.scopedSettings("complementary-ambiguous")
        defer { scope.tearDown() }
        let mappings = RemoteDeviceMappings(
            buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:],
            secondaryButtonBindings: [:]
        )
        let profiles = [
            RemoteDeviceProfile(model: .rc003, hidFingerprint: "hid-a", mappings: mappings),
            RemoteDeviceProfile(model: .rc003, hidFingerprint: "hid-b", mappings: mappings),
            RemoteDeviceProfile(model: .rc003, bluetoothIdentifier: UUID(), mappings: mappings),
            RemoteDeviceProfile(model: .rc003, bluetoothIdentifier: UUID(), mappings: mappings),
        ]
        scope.defaults.set(try JSONEncoder().encode(profiles), forKey: "remoteDeviceProfiles")

        let settings = AppSettings(defaults: scope.defaults)
        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: Set(profiles.filter { $0.bluetoothIdentifier != nil }.map(\.id)),
            activeHIDProfileIDs: Set(profiles.filter { $0.hidFingerprint != nil }.map(\.id))
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 4)
    }

    @Test func newSameModelRemoteStartsWithIndependentMappings() throws {
        let scope = try Self.scopedSettings("same-model-independent")
        defer { scope.tearDown() }
        let selectedID = UUID()
        var selectedBindings = AppSettings.defaultBindings
        selectedBindings[.menu] = .openCodex
        let selected = RemoteDeviceProfile(
            id: selectedID,
            model: .rc003,
            hidFingerprint: "selected-rc003",
            mappings: RemoteDeviceMappings(
                buttonBindings: selectedBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([selected]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(selectedID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)
        let newID = settings.registerBluetoothRemote(identifier: UUID())
        settings.updateRemoteProfileModel(newID, model: .rc003)

        let newProfile = try #require(settings.remoteDeviceProfiles.first(where: { $0.id == newID }))
        #expect(newProfile.mappings.parsedButtonBindings == AppSettings.defaultBindings)
        #expect(newProfile.mappings.parsedButtonShortcuts.isEmpty)
        let original = try #require(settings.remoteDeviceProfiles.first(where: { $0.id == selectedID }))
        #expect(original.mappings.parsedButtonBindings[.menu] == .openCodex)
        #expect(original.mappings.parsedButtonBindings == selectedBindings)
    }

    @Test func newSameModelAppleRemoteStartsWithDefaults() throws {
        let scope = try Self.scopedSettings("same-model-apple")
        defer { scope.tearDown() }
        let settings = scope.settings
        let firstID = settings.registerAppleSiriRemote(fingerprint: "apple-first")
        settings.selectRemoteProfile(firstID)
        settings.setAction(.openCodex, for: .menu)

        let secondID = settings.registerAppleSiriRemote(fingerprint: "apple-second")
        let second = try #require(settings.remoteDeviceProfiles.first(where: { $0.id == secondID }))
        #expect(second.mappings.parsedButtonBindings == AppSettings.defaultBindings)
        #expect(second.mappings.parsedButtonShortcuts.isEmpty)
        let first = try #require(settings.remoteDeviceProfiles.first(where: { $0.id == firstID }))
        #expect(first.mappings.parsedButtonBindings[.menu] == .openCodex)
    }

    @Test func bleRegistrationKeepsTheMatchingHIDFirstProfileAndItsMappings() throws {
        let scope = try Self.scopedSettings("ble-hid-first-verified")
        defer { scope.tearDown() }
        let settings = scope.settings
        let identifier = UUID()
        let hid = settings.registerHIDRemote(
            fingerprint: RemoteIdentityFingerprint.fingerprint(for: identifier)
        )
        settings.selectRemoteProfile(hid)
        settings.setAction(.openCodex, for: .menu)

        let ble = settings.registerBluetoothRemote(identifier: identifier)
        settings.updateRemoteProfileModel(ble, model: .rc003)

        #expect(ble == hid)
        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.selectedRemoteProfile?.model == .rc003)
        #expect(settings.action(for: .menu) == .openCodex)
        #expect(settings.registerBluetoothRemote(identifier: identifier) == hid)
    }

    @Test func splitUnknownHIDProfileUsesTheLiveMatchingBLEModel() throws {
        let scope = try Self.scopedSettings("hid-first-existing-split")
        defer { scope.tearDown() }
        let identifier = UUID()
        let hid = RemoteDeviceProfile(
            hidFingerprint: RemoteIdentityFingerprint.fingerprint(for: identifier),
            mappings: RemoteDeviceMappings(buttonBindings: [.menu: .openCodex],
                                           buttonShortcuts: [:], secondaryButtonBindings: [:])
        )
        let ble = RemoteDeviceProfile(
            model: .rc003,
            bluetoothIdentifier: identifier,
            mappings: RemoteDeviceMappings(buttonBindings: AppSettings.defaultBindings,
                                           buttonShortcuts: [:], secondaryButtonBindings: [:])
        )
        scope.defaults.set(try JSONEncoder().encode([hid, ble]), forKey: "remoteDeviceProfiles")
        let settings = AppSettings(defaults: scope.defaults)
        settings.selectRemoteProfile(hid.id)

        #expect(settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [ble.id], activeHIDProfileIDs: [hid.id]
        )[ble.id] == hid.id)
        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.selectedRemoteProfile?.model == .rc003)
        #expect(settings.action(for: .menu) == .openCodex)
        #expect(settings.restoreMergedRemoteProfilesBackup())
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func hidRegistrationUsesVerifiedBLEIdentityInsteadOfTheSelectedRemote() throws {
        let scope = try Self.scopedSettings("hid-matches-ble")
        defer { scope.tearDown() }
        let settings = scope.settings
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        let first = settings.registerBluetoothRemote(identifier: firstIdentifier)
        let second = settings.registerBluetoothRemote(identifier: secondIdentifier)
        settings.selectRemoteProfile(first)
        settings.setAction(.openCodex, for: .menu)

        let secondFingerprint = RemoteIdentityFingerprint.fingerprint(for: secondIdentifier)
        let resolved = settings.registerHIDRemote(fingerprint: secondFingerprint)
        #expect(resolved == second)
        #expect(settings.selectedRemoteProfileID == first)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == first })?.hidFingerprint == nil)
        #expect(settings.action(for: .menu, profileID: second) != .openCodex)

        let unknown = settings.registerHIDRemote(fingerprint: "unrelated")
        #expect(unknown != first && unknown != second)
        #expect(settings.remoteDeviceProfiles.count == 3)
    }

    @Test func startupDedupKeepsTheOwnerOfEveryScopedBinding() throws {
        let scope = try Self.scopedSettings("scoped-binding-dedup")
        defer { scope.tearDown() }
        let mappings = RemoteDeviceMappings(buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:], secondaryButtonBindings: [:])
        let owner = RemoteDeviceProfile(model: .appleSiriRemoteA2854, hidFingerprint: "older",
            hardwareIdentity: "same", mappings: mappings)
        let selected = RemoteDeviceProfile(model: .appleSiriRemoteA2854, hidFingerprint: "newer",
            hardwareIdentity: "same", mappings: mappings)
        let bindings = [RemoteMic.RemoteButton.menu, .back].map { button in
            UnifiedButtonBinding(remoteProfileID: owner.id, button: button, trigger: .singleClick,
                configured: ConfiguredButtonAction(action: .openCodex, shortcut: nil))
        }
        scope.defaults.set(try JSONEncoder().encode([owner, selected]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(try JSONEncoder().encode(bindings), forKey: "unifiedBaseBindings")
        scope.defaults.set(selected.id.uuidString, forKey: "selectedRemoteProfileID")

        for _ in 1...2 {
            let settings = AppSettings(defaults: scope.defaults)
            #expect(settings.remoteDeviceProfiles.map(\.id) == [owner.id])
            #expect(settings.selectedRemoteProfileID == owner.id)
            #expect(settings.unifiedBaseBindings == bindings)
            for binding in bindings {
                #expect(settings.configuredAction(for: binding.button, trigger: .singleClick,
                                                  profileID: owner.id).action == .openCodex)
            }
        }
    }

    @Test func unreadableScopedBindingStoragePreservesAllCandidateProfiles() throws {
        let scope = try Self.scopedSettings("unreadable-scoped-bindings")
        defer { scope.tearDown() }
        let mappings = RemoteDeviceMappings(buttonBindings: AppSettings.defaultBindings,
            buttonShortcuts: [:], secondaryButtonBindings: [:])
        let first = RemoteDeviceProfile(model: .rc003, hidFingerprint: "same", mappings: mappings)
        let second = RemoteDeviceProfile(model: .rc003, hidFingerprint: "same", mappings: mappings)
        let raw = Data("unreadable binding fixture".utf8)
        scope.defaults.set(try JSONEncoder().encode([first, second]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(raw, forKey: "unifiedBaseBindings")

        let settings = AppSettings(defaults: scope.defaults)
        let replacements = settings.collapseDuplicateRemoteProfiles()
        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.map(\.id) == [first.id, second.id])
        #expect(settings.corruptedSettingKeys.contains("unifiedBaseBindings"))
        #expect(scope.defaults.data(forKey: "unifiedBaseBindings") == raw)
        #expect(scope.defaults.data(forKey: "unifiedBaseBindings.corrupt") == raw)
    }

    @Test func bleRegistrationDoesNotAdoptAnotherRemotesHIDProfile() throws {
        let scope = try Self.scopedSettings("ble-hid-adoption")
        defer { scope.tearDown() }
        let settings = scope.settings
        let hid = settings.registerHIDRemote(fingerprint: "hid-one")
        settings.setAction(.openCodex, for: .menu)

        let ble = settings.registerBluetoothRemote(identifier: UUID())

        #expect(ble != hid)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == hid })?
            .bluetoothIdentifier == nil)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == ble })?
            .mappings.parsedButtonBindings[.menu] == AppSettings.defaultBindings[.menu])
    }

    @Test func hidRegistrationDoesNotAdoptUnselectedBLEProfile() throws {
        let scope = try Self.scopedSettings("hid-ble-adoption")
        defer { scope.tearDown() }
        let settings = scope.settings
        let selectedHID = settings.registerHIDRemote(fingerprint: "selected-hid")
        settings.updateRemoteProfileModel(selectedHID, model: .rc003)
        let unselectedBLE = settings.registerBluetoothRemote(identifier: UUID())

        let newHID = settings.registerHIDRemote(fingerprint: "new-hid")

        #expect(newHID != unselectedBLE)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == unselectedBLE })?
            .hidFingerprint == nil)
    }

    @Test func deduplicationReloadsMappingsForSelectedDefaultProfile() throws {
        let scope = try Self.scopedSettings("dedup-reload-selected")
        defer { scope.tearDown() }
        var customBindings = AppSettings.defaultBindings
        customBindings[.menu] = .openCodex
        let selected = RemoteDeviceProfile(
            model: .appleSiriRemoteA2854,
            hidFingerprint: "dedup-reload",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let custom = RemoteDeviceProfile(
            model: .appleSiriRemoteA2854,
            hidFingerprint: "dedup-reload",
            mappings: RemoteDeviceMappings(
                buttonBindings: customBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([selected, custom]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(selected.id.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.selectedRemoteProfileID == selected.id)
        #expect(settings.action(for: .menu) == .openCodex)
    }

    @Test func legacyProfilePayloadKeepsCustomMappingsAfterUpgrade() throws {
        let scope = try Self.scopedSettings("legacy-upgrade")
        defer { scope.tearDown() }
        let profileID = UUID()
        var bindings = AppSettings.defaultBindings
        bindings[.menu] = .openCodex
        let profile = RemoteDeviceProfile(
            id: profileID,
            model: .rc003,
            hidFingerprint: "legacy-upgrade",
            mappings: RemoteDeviceMappings(
                buttonBindings: bindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        var payload = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([profile]))
                as? [[String: Any]]
        )
        payload[0].removeValue(forKey: "hardwareIdentity")
        payload[0].removeValue(forKey: "lastKnownBluetoothName")
        payload[0].removeValue(forKey: "bluetoothIdentifier")
        scope.defaults.set(
            try JSONSerialization.data(withJSONObject: payload),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(profileID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.selectedRemoteProfileID == profileID)
        #expect(settings.selectedRemoteProfile?.mappings.parsedButtonBindings[.menu]
            == .openCodex)
    }

    @Test func automaticProfileDisplayDoesNotOverwritePersistedPreference() throws {
        let scope = try Self.scopedSettings("display-selection")
        defer { scope.tearDown() }
        let xiaomiID = UUID()
        let appleID = UUID()
        var xiaomiBindings = AppSettings.defaultBindings
        xiaomiBindings[.menu] = .openCodex
        let xiaomi = RemoteDeviceProfile(
            id: xiaomiID,
            model: .rc003,
            hidFingerprint: "xiaomi-selection",
            mappings: RemoteDeviceMappings(
                buttonBindings: xiaomiBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let apple = RemoteDeviceProfile(
            id: appleID,
            model: .appleSiriRemoteA2854,
            hidFingerprint: "apple-selection",
            mappings: RemoteDeviceMappings(
                buttonBindings: AppSettings.defaultBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([xiaomi, apple]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(xiaomiID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)
        settings.selectRemoteProfile(appleID, persistSelection: false)

        #expect(settings.selectedRemoteProfileID == appleID)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == xiaomiID })?
            .mappings.parsedButtonBindings == xiaomi.mappings.parsedButtonBindings)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == appleID })?
            .mappings.parsedButtonBindings == apple.mappings.parsedButtonBindings)

        let afterRestart = AppSettings(defaults: scope.defaults)
        #expect(afterRestart.selectedRemoteProfileID == xiaomiID)

        settings.selectRemoteProfile(appleID)
        let afterManualSelection = AppSettings(defaults: scope.defaults)
        #expect(afterManualSelection.selectedRemoteProfileID == appleID)
    }

    @Test func reselectingCurrentProfileDoesNotCancelButtonInteractions() throws {
        let scope = try Self.scopedSettings("reselect-current-profile")
        defer { scope.tearDown() }
        let settings = AppSettings(defaults: scope.defaults)
        let profile = settings.registerHIDRemote(fingerprint: "reselect-current-profile")
        settings.selectRemoteProfile(profile, persistSelection: false)
        var cancellations = 0
        settings.onInteractionModeChanged = { _ in cancellations += 1 }

        settings.selectRemoteProfile(profile)
        settings.selectRemoteProfile(profile)

        #expect(cancellations == 0)
        #expect(AppSettings(defaults: scope.defaults).selectedRemoteProfileID == profile)
    }

    @Test func conflictingDuplicateMappingsAreNotMerged() throws {
        let scope = try Self.scopedSettings("conflicting-duplicates")
        defer { scope.tearDown() }
        let firstID = UUID()
        let secondID = UUID()
        var firstBindings = AppSettings.defaultBindings
        firstBindings[.menu] = .openCodex
        var secondBindings = AppSettings.defaultBindings
        secondBindings[.menu] = .openWeChat
        let first = RemoteDeviceProfile(
            id: firstID,
            model: .appleSiriRemoteA2854,
            hidFingerprint: "shared-fingerprint",
            mappings: RemoteDeviceMappings(
                buttonBindings: firstBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let second = RemoteDeviceProfile(
            id: secondID,
            model: .appleSiriRemoteA2854,
            hidFingerprint: "shared-fingerprint",
            mappings: RemoteDeviceMappings(
                buttonBindings: secondBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let third = RemoteDeviceProfile(
            model: .appleSiriRemoteA2854,
            hidFingerprint: "shared-fingerprint",
            mappings: first.mappings
        )
        scope.defaults.set(
            try JSONEncoder().encode([first, second, third]),
            forKey: "remoteDeviceProfiles"
        )
        scope.defaults.set(secondID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)

        // 同一身份一旦出现冲突，后续同身份档案也不得再并进其中一条。
        #expect(settings.remoteDeviceProfiles.count == 3)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == firstID })?
            .mappings.parsedButtonBindings == first.mappings.parsedButtonBindings)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == secondID })?
            .mappings.parsedButtonBindings == second.mappings.parsedButtonBindings)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == third.id }) != nil)
        // 冲突档案保留多条相同指纹时，按键查找必须跟随用户当前选中的那张。
        #expect(settings.profileID(forHIDFingerprint: "shared-fingerprint") == secondID)
    }

    @Test func semanticallyEqualPartialBindingsDoNotBlockDeduplication() throws {
        let scope = try Self.scopedSettings("partial-default-bindings")
        defer { scope.tearDown() }
        let firstID = UUID()
        var fullBindings = AppSettings.defaultBindings
        fullBindings[.menu] = .openCodex
        let first = RemoteDeviceProfile(
            id: firstID,
            model: .appleSiriRemoteA2854,
            hidFingerprint: "partial-fingerprint",
            mappings: RemoteDeviceMappings(
                buttonBindings: [.menu: .openCodex],
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        let second = RemoteDeviceProfile(
            model: .appleSiriRemoteA2854,
            hidFingerprint: "partial-fingerprint",
            mappings: RemoteDeviceMappings(
                buttonBindings: fullBindings,
                buttonShortcuts: [:],
                secondaryButtonBindings: [:]
            )
        )
        scope.defaults.set(try JSONEncoder().encode([first, second]), forKey: "remoteDeviceProfiles")
        scope.defaults.set(firstID.uuidString, forKey: "selectedRemoteProfileID")

        let settings = AppSettings(defaults: scope.defaults)

        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.action(for: .menu) == .openCodex)
    }

    @Test func conflictingComplementaryMappingsAreNotMerged() throws {
        let scope = try Self.scopedSettings("conflicting-complementary")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings)
        settings.selectRemoteProfile(pair.hid)
        settings.setAction(.openCodex, for: .menu)
        settings.selectRemoteProfile(pair.ble)
        settings.setAction(.openWeChat, for: .menu)
        settings.selectRemoteProfile(pair.hid)

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == pair.hid })?
            .mappings.parsedButtonBindings[.menu] == .openCodex)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == pair.ble })?
            .mappings.parsedButtonBindings[.menu] == .openWeChat)
    }

    @Test func complementaryProfilesWithDifferentNamesStaySeparate() throws {
        let scope = try Self.scopedSettings("complementary-names")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings, identity: "TESTSERIAL-NAMES")
        settings.updateRemoteProfile(pair.hid, model: .rc003, customName: "书房")
        settings.updateRemoteProfile(pair.ble, model: .rc003, customName: "客厅")

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [pair.ble],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    @Test func complementaryProfilesRequireBothSidesToBeLive() throws {
        let scope = try Self.scopedSettings("complementary-live")
        defer { scope.tearDown() }
        let settings = scope.settings
        let pair = Self.registerComplementaryPair(in: settings, identity: "TESTSERIAL-LIVE")

        let replacements = settings.reconcileComplementaryRemoteProfiles(
            connectedProfileIDs: [],
            activeHIDProfileIDs: [pair.hid]
        )

        #expect(replacements.isEmpty)
        #expect(settings.remoteDeviceProfiles.count == 2)
    }

    /// A bridge whose `deviceIdentifier` is known without CoreBluetooth: with no peripheral
    /// attached it reports its target identifier, which is what the model keys profiles by.
    @MainActor
    private static func bridge(
        _ identifier: UUID,
        settings: AppSettings,
        delegate: BridgeAppModel
    ) -> XiaomiBluetoothBridge {
        XiaomiBluetoothBridge(delegate: delegate, targetIdentifier: identifier)
    }

    /// The regression test for the reported defect.
    ///
    /// The first profile slot has to be occupied first, because `registerBluetoothRemote` adopts
    /// an unbound slot rather than appending to it — with a virgin settings store the ghost would
    /// silently take over the migrated profile instead of adding a card, and the count would not
    /// move either way.
    ///
    /// Before the fix, the battery read alone persisted a second profile, and the model read gave
    /// it the `unknown` fallback name the user saw.
    @MainActor
    @Test func aPeripheralThatNeverCompletesTheHandshakeLeavesNoDeviceProfileBehind() throws {
        let scope = try Self.scopedSettings("ghost")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let realRemote = UUID()
        let strayAdvertiser = UUID()

        settings.registerBluetoothRemote(identifier: realRemote)
        #expect(settings.remoteDeviceProfiles.count == 1)

        // The stray peripheral gets as far as answering every read the app issues on connect,
        // then goes away. `MI RC` is on the name whitelist, so the discovery bridge does connect.
        let stray = Self.bridge(strayAdvertiser, settings: settings, delegate: model)
        model.bluetoothBridge(stray, didUpdateBatteryLevel: 73)
        model.bluetoothBridge(stray, didUpdatePowerState: .onBattery)
        model.bluetoothBridge(stray, didIdentifyRemoteModel: .rc001)
        model.bluetoothBridge(stray, didChange: .failed(LocalizedMessage("test.stray_gone")))

        #expect(settings.remoteDeviceProfiles.count == 1)
        #expect(settings.profileID(forBluetoothIdentifier: strayAdvertiser) == nil)
    }

    /// The positive control, without which the fix could be "never register anything".
    ///
    /// Same reads in the same order as the real remote produces on connect — the runtime log has
    /// battery and model both landing before `BLE READY` — followed by the handshake completing.
    /// The profile has to appear, and it has to carry the readings that arrived before it
    /// existed, or a first-ever remote would sit on "—" and the `unknown` fallback name until it
    /// happened to notify again.
    @MainActor
    @Test func aRemoteThatCompletesTheHandshakeKeepsTheReadingsThatArrivedFirst() throws {
        let scope = try Self.scopedSettings("ready")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let firstRemote = UUID()
        let secondRemote = UUID()

        settings.registerBluetoothRemote(identifier: firstRemote)
        #expect(settings.remoteDeviceProfiles.count == 1)

        let remote = Self.bridge(secondRemote, settings: settings, delegate: model)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: 73)
        model.bluetoothBridge(remote, didUpdatePowerState: .charging)
        model.bluetoothBridge(remote, didIdentifyRemoteModel: .rc003)

        // Nothing is persisted yet: the handshake is what earns a card.
        #expect(settings.remoteDeviceProfiles.count == 1)

        model.bluetoothBridge(remote, didChange: .ready("小米蓝牙语音遥控器"))

        let profileID = try #require(settings.profileID(forBluetoothIdentifier: secondRemote))
        #expect(settings.remoteDeviceProfiles.count == 2)
        #expect(model.batteryLevel(for: profileID) == 73)
        #expect(model.powerState(for: profileID) == .charging)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == profileID })?.model == .rc003)
    }

    /// Buffering the readings creates a way for them to go stale, which this pins shut.
    ///
    /// A peripheral answers its reads, fails the handshake, and only succeeds much later — by
    /// which time the buffered battery level describes a battery that has since been used. The
    /// card must start empty and wait for the new connection's own reads rather than inherit the
    /// abandoned attempt's.
    @MainActor
    @Test func readingsFromAnAbandonedAttemptAreNotReplayedOntoALaterConnection() throws {
        let scope = try Self.scopedSettings("stale")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let firstRemote = UUID()
        let lateRemote = UUID()

        settings.registerBluetoothRemote(identifier: firstRemote)

        let remote = Self.bridge(lateRemote, settings: settings, delegate: model)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: 4)
        model.bluetoothBridge(remote, didUpdatePowerState: .onBattery)
        model.bluetoothBridge(remote, didIdentifyRemoteModel: .rc001)
        model.bluetoothBridge(remote, didChange: .failed(LocalizedMessage("test.init_failed")))

        model.bluetoothBridge(remote, didChange: .ready("小米蓝牙语音遥控器"))

        let profileID = try #require(settings.profileID(forBluetoothIdentifier: lateRemote))
        #expect(model.batteryLevel(for: profileID) == nil)
        #expect(model.powerState(for: profileID) == nil)
        #expect(settings.remoteDeviceProfiles.first(where: { $0.id == profileID })?.model == .unknown)
    }

    /// A failed read reports `nil`, and that has to invalidate the buffered value rather than
    /// leave the last successful one to be replayed as if it were current.
    @MainActor
    @Test func aFailedReadInvalidatesTheBufferedValue() throws {
        let scope = try Self.scopedSettings("invalidate")
        defer { scope.tearDown() }
        let settings = scope.settings
        let model = BridgeAppModel(settings: settings)
        let firstRemote = UUID()
        let secondRemote = UUID()

        settings.registerBluetoothRemote(identifier: firstRemote)

        let remote = Self.bridge(secondRemote, settings: settings, delegate: model)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: 73)
        model.bluetoothBridge(remote, didUpdatePowerState: .charging)
        model.bluetoothBridge(remote, didUpdateBatteryLevel: nil)
        model.bluetoothBridge(remote, didUpdatePowerState: nil)

        model.bluetoothBridge(remote, didChange: .ready("小米蓝牙语音遥控器"))

        let profileID = try #require(settings.profileID(forBluetoothIdentifier: secondRemote))
        #expect(model.batteryLevel(for: profileID) == nil)
        #expect(model.powerState(for: profileID) == nil)
    }

    /// An older build cannot decode models or actions that a newer build added. It must not
    /// replace the whole stored array with one fallback profile just because the load failed.
    @Test func unreadableStoredProfilesArePreservedUntilAFutureSave() throws {
        let scope = try Self.scopedSettings("unreadable")
        defer { scope.tearDown() }
        let raw = Data("{\"unexpected\":\"profile array\"}".utf8)
        scope.defaults.set(raw, forKey: "remoteDeviceProfiles")

        let settings = AppSettings(defaults: scope.defaults)

        #expect(scope.defaults.data(forKey: "remoteDeviceProfiles") == raw)
        #expect(settings.remoteDeviceProfiles.count == 1)

        settings.registerBluetoothRemote(identifier: UUID())

        #expect(scope.defaults.data(forKey: AppSettings.unreadableRemoteProfilesBackupKey) == raw)
        #expect(scope.defaults.data(forKey: "remoteDeviceProfiles") != raw)
    }
}
