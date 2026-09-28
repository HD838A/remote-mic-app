import Foundation
import Testing
@testable import RemoteMic

@Suite("Remote device names")
struct RemoteDeviceNamePolicyTests {
    @Test func missingOrBlankObservationPreservesCachedName() {
        for name: String? in [nil, "", " \t\r\n ", "\u{00A0}"] {
            #expect(RemoteDeviceNamePolicy.customName(from: name, model: .rc001) == nil)
        }
    }

    @Test func xiaomiFactoryAliasesExplicitlyClearCachedName() {
        let names = [
            "MI RC", "Xiaomi Bluetooth Remote 2", "Xiaomi Bluetooth Remote 2 Pro",
            "小米蓝牙语音遥控器", "小米蓝牙遥控器2", "小米蓝牙遥控器2 Pro", "ARN9",
            "小米蓝牙遥控器 2", "小米蓝牙遥控器 2 Pro",
        ]
        for model in [XiaomiRemoteModel.rc001, .rc003] {
            for name in names {
                #expect(RemoteDeviceNamePolicy.customName(from: " \(name) \n", model: model) == "")
            }
        }
    }

    @Test func appleFactoryAliasesExplicitlyClearCachedName() {
        for model in [XiaomiRemoteModel.appleSiriRemoteA2854, .appleSiriRemoteA2540] {
            for name in ["Siri Remote", "Apple TV Remote", "Apple Remote"] {
                #expect(RemoteDeviceNamePolicy.customName(from: name, model: model) == "")
            }
        }
        #expect(RemoteDeviceNamePolicy.customName(from: "苹果遥控器 Type-C", model: .appleSiriRemoteA2854) == "")
        #expect(RemoteDeviceNamePolicy.customName(from: "Apple Remote Type-C", model: .appleSiriRemoteA2854) == "")
        #expect(RemoteDeviceNamePolicy.customName(from: "苹果遥控器 Lightning", model: .appleSiriRemoteA2540) == "")
        #expect(RemoteDeviceNamePolicy.customName(from: "Apple Remote Lightning", model: .appleSiriRemoteA2540) == "")
    }

    @Test func chromecastDisplayNamesAreFactoryAliases() {
        for name in ["Chromecast Remote", "Chromecast 遥控器"] {
            #expect(RemoteDeviceNamePolicy.customName(from: name, model: .chromecastVoiceRemote) == "")
        }
    }

    @Test func unknownModelRecognizesExistingDiscoveryAliases() {
        #expect(RemoteDeviceNamePolicy.customName(from: "MI RC", model: .unknown) == "")
        #expect(RemoteDeviceNamePolicy.customName(from: "客厅遥控器", model: .unknown) == "客厅遥控器")
    }

    @Test func factoryMatchingDoesNotConsumeUserPrefixesOrSuffixes() {
        for name in ["MI RC 2", "我的 MI RC", "Xiaomi Bluetooth Remote 2 工作", "ARN9-2"] {
            #expect(RemoteDeviceNamePolicy.customName(from: name, model: .rc001) == name)
        }
        #expect(RemoteDeviceNamePolicy.customName(from: "Siri Remote", model: .rc001) == "Siri Remote")
    }

    @Test func userNamesPreserveCaseAndNumericSuffixes() {
        #expect(RemoteDeviceNamePolicy.customName(from: "  Desk Remote 2  ", model: .rc001) == "Desk Remote 2")
        #expect(RemoteDeviceNamePolicy.customName(from: "desk REMOTE", model: .rc001) == "desk REMOTE")
    }

    @Test func userNamesNormalizeUnicodeAndFlattenLineBreaks() {
        let normalized = RemoteDeviceNamePolicy.customName(from: "  Cafe\u{301}\t遥控器\n办公\r区域  ", model: .rc001)
        #expect(normalized == "Café 遥控器 办公 区域")
        #expect(normalized?.unicodeScalars.contains("\u{0301}") == false)
        #expect(RemoteDeviceNamePolicy.customName(from: "客厅\u{2028}遥控器", model: .rc001) == "客厅 遥控器")
    }

    @Test func observedSystemNameKeepsFactoryAndSerialNamesForTheConnectedCard() {
        #expect(RemoteDeviceNamePolicy.observedSystemName(from: "  MI RC\n") == "MI RC")
        #expect(RemoteDeviceNamePolicy.observedSystemName(from: "TESTSERIAL001") == "TESTSERIAL001")
        #expect(RemoteDeviceNamePolicy.observedSystemName(from: " \t\n") == nil)
    }

    @Test func cardOrderUsesModelPinyinBeforeSystemName() {
        let xiaomi = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            model: .rc003,
            name: "阿姨"
        )
        let apple = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            model: .appleSiriRemoteA2854,
            name: "客厅"
        )
        let chromecast = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            model: .chromecastVoiceRemote,
            name: "Bedroom"
        )

        let sorted = RemoteDeviceNamePolicy.sortedForCards(
            [xiaomi, apple, chromecast],
            modelName: { profile in
                switch profile.model {
                case .appleSiriRemoteA2854: return "苹果遥控器 Type-C"
                case .chromecastVoiceRemote: return "Chromecast 遥控器"
                case .rc003: return "小米蓝牙遥控器 2 Pro"
                default: return "未知"
                }
            },
            systemName: { $0.customName }
        )

        #expect(sorted.map(\.id) == [chromecast.id, apple.id, xiaomi.id])
    }

    @Test func cardOrderUsesSystemNamePinyinThenStableIDForTheSameModel() {
        let laterID = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "北京"
        )
        let earlierID = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "北京"
        )
        let aName = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "阿姨"
        )
        let missingName = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        )

        let sorted = RemoteDeviceNamePolicy.sortedForCards(
            [missingName, laterID, aName, earlierID],
            modelName: { _ in "小米蓝牙遥控器 2" },
            systemName: { $0.customName.isEmpty ? nil : $0.customName }
        )

        #expect(sorted.map(\.id) == [aName.id, earlierID.id, laterID.id, missingName.id])
    }

    @Test func soleUnnamedProfileUsesLocalizedDefault() {
        let profile = makeProfile()
        #expect(display(profile, among: [profile]) == "小米蓝牙遥控器 2")
    }

    @Test func unnamedProfilesKeepSavedModelOrderIncludingRenamedHistory() {
        let first = makeProfile()
        let renamed = makeProfile(name: "办公")
        let third = makeProfile()
        let otherModel = makeProfile(model: .rc003)
        let profiles = [first, otherModel, renamed, third]
        #expect(display(first, among: profiles) == "小米蓝牙遥控器 2 1")
        #expect(display(third, among: profiles) == "小米蓝牙遥控器 2 3")
        #expect(display(renamed, among: profiles) == "办公")
    }

    @Test func uniqueCustomNameHasNoSuffix() {
        let profile = makeProfile(name: "客厅 2")
        #expect(display(profile, among: [profile]) == "客厅 2")
    }

    @Test func duplicateCustomNamesNumberEveryHistoricalProfileAcrossModels() {
        let first = makeProfile(name: "办公")
        let second = makeProfile(model: .appleSiriRemoteA2854, name: "办公")
        let third = makeProfile(model: .rc003, name: "办公")
        // 档案列表包含离线历史设备；命名不接收在线状态，也不筛掉历史档案。
        let history = [first, second, third]
        #expect(display(first, among: history) == "办公 1")
        #expect(display(second, among: history) == "办公 2")
        #expect(display(third, among: history) == "办公 3")
    }

    @Test func renamingLeavesPreviousGroupAndRenumbersRemainingMembers() {
        let first = makeProfile(name: "办公")
        var second = makeProfile(name: "办公")
        #expect(display(first, among: [first, second]) == "办公 1")
        second.customName = "客厅"
        #expect(display(first, among: [first, second]) == "办公")
        #expect(display(second, among: [first, second]) == "客厅")
    }

    @Test func customGroupsAreCaseSensitiveAndUnicodeCanonical() {
        let upper = makeProfile(name: "Desk")
        let lower = makeProfile(name: "desk")
        let composed = makeProfile(name: "Café")
        let decomposed = makeProfile(name: " Cafe\u{301} ")
        let profiles = [upper, lower, composed, decomposed]
        #expect(display(upper, among: profiles) == "Desk")
        #expect(display(lower, among: profiles) == "desk")
        #expect(display(composed, among: profiles) == "Café 1")
        #expect(display(decomposed, among: profiles) == "Café 2")
    }

    @Test func persistedWhitespaceNameUsesDefault() {
        let profile = makeProfile(name: " \t\n ")
        #expect(display(profile, among: [profile]) == "小米蓝牙遥控器 2")
    }

    @Test func persistedMultilineNamesShareTheSingleLineDisplayGroup() {
        let first = makeProfile(name: "办公\n遥控器")
        let second = makeProfile(name: "办公 遥控器")
        #expect(display(first, among: [first, second]) == "办公 遥控器 1")
        #expect(display(second, among: [first, second]) == "办公 遥控器 2")
        #expect(first.customName == "办公\n遥控器")
    }

    @Test func numericSuffixRemainsPartOfCustomGroup() {
        let first = makeProfile(name: "办公 2")
        let second = makeProfile(name: "办公 2")
        let other = makeProfile(name: "办公")
        #expect(display(first, among: [first, second, other]) == "办公 2 1")
        #expect(display(second, among: [first, second, other]) == "办公 2 2")
        #expect(display(other, among: [first, second, other]) == "办公")
    }

    @Test func unlistedProfileDoesNotReceiveInventedOrdinal() {
        let profile = makeProfile(name: "办公")
        #expect(display(profile, among: [makeProfile(name: "办公"), makeProfile(name: "办公")]) == "办公")
        let unnamed = makeProfile()
        #expect(display(unnamed, among: [makeProfile(), makeProfile()]) == "小米蓝牙遥控器 2")
    }

    @Test func appleSerialNumberNameUsesDefaultOnlyOnAnExactMatch() {
        let serial = "TESTSERIAL001"
        for model in [XiaomiRemoteModel.appleSiriRemoteA2854, .appleSiriRemoteA2540] {
            #expect(RemoteDeviceNamePolicy.customName(from: serial, model: model, serialNumber: serial) == "")
            for name in ["testserial001", "TESTSERIAL001 2", " TESTSERIAL001 ", "Office"] {
                #expect(RemoteDeviceNamePolicy.customName(from: name, model: model, serialNumber: serial)
                    == name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    @Test func missingSerialDoesNotGuessWhetherANameIsASerialNumber() {
        for serial: String? in [nil, "", "OTHER-SERIAL"] {
            #expect(RemoteDeviceNamePolicy.customName(
                from: "TESTSERIAL001", model: .appleSiriRemoteA2854, serialNumber: serial
            ) == "TESTSERIAL001")
        }
        #expect(RemoteDeviceNamePolicy.customName(
            from: nil, model: .appleSiriRemoteA2854, serialNumber: "TESTSERIAL001"
        ) == nil)
        #expect(RemoteDeviceNamePolicy.customName(
            from: " ", model: .appleSiriRemoteA2854, serialNumber: " "
        ) == nil)
    }

    @Test func serialNameRuleDoesNotChangeOtherRemoteModels() {
        for model in [XiaomiRemoteModel.rc001, .rc003, .unknown, .chromecastVoiceRemote] {
            #expect(RemoteDeviceNamePolicy.customName(
                from: "TESTSERIAL001", model: model, serialNumber: "TESTSERIAL001"
            ) == "TESTSERIAL001")
        }
    }

    private func makeProfile(
        id: UUID = UUID(),
        model: XiaomiRemoteModel = .rc001,
        name: String = ""
    ) -> RemoteDeviceProfile {
        RemoteDeviceProfile(
            id: id,
            model: model,
            customName: name,
            mappings: RemoteDeviceMappings(buttonBindings: [:], buttonShortcuts: [:], secondaryButtonBindings: [:])
        )
    }

    private func display(_ profile: RemoteDeviceProfile, among profiles: [RemoteDeviceProfile]) -> String {
        RemoteDeviceNamePolicy.displayName(for: profile, among: profiles, defaultName: "小米蓝牙遥控器 2")
    }
}
