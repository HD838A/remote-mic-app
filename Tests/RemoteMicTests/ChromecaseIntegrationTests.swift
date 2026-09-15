import Foundation
import Testing
@testable import RemoteMic

@Suite("Chromecase integration")
struct ChromecaseIntegrationTests {
    // MARK: - 语音键隔离

    @Test func voiceKeyLatchKeepsHardwareOwnersIndependent() {
        var latch = VoiceFunctionKeyLatch()

        // Siri Remote 先按住。
        #expect(latch.transition(streaming: true, owner: .appleRemote) == .press)
        // Chromecase 同时按住：不得产生第二次按下，也不得取消 Siri。
        #expect(latch.transition(streaming: true, owner: .chromecase) == nil)
        #expect(latch.isHeld)
        // Siri 松手：Chromecase 仍按住，语音键不得抬起。
        #expect(latch.transition(streaming: false, owner: .appleRemote) == nil)
        #expect(latch.isHeld)
        // Chromecase 松手：此时才真正抬起。
        #expect(latch.transition(streaming: false, owner: .chromecase) == .release)
        #expect(!latch.isHeld)
    }

    @Test func chromecasePressesAndReleasesVoiceKeyOnItsOwn() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true, owner: .chromecase) == .press)
        #expect(latch.isHeld)
        #expect(latch.transition(streaming: false, owner: .chromecase) == .release)
        #expect(!latch.isHeld)
    }

    @Test func chromecaseOwnerIsDistinctFromEveryOtherHardware() {
        let owners: Set<VoiceFunctionKeyLatch.Owner> = [
            .bluetooth,
            .appleRemote,
            .chromecase,
            .mobile,
        ]
        #expect(owners.count == 4)
    }

    // MARK: - 产品默认值

    @Test func productDefaultVoiceModeIsToggle() {
        // 需求：toggle 为默认语音模式，hold 保留给用户可选切换。
        #expect(ChromecaseVoiceMode.productDefault == .toggle)
        #expect(ChromecaseVoiceMode.allCases == [.toggle, .hold])
    }

    @Test func everyLinkStatusHasALocalizationKey() {
        let statuses: [ChromecaseLinkStatus] = [
            .unavailable,
            .disabled,
            .searching,
            .connecting,
            .unauthorized,
            .unsupported(reason: "8 kHz"),
            .connected(displayName: "remote"),
            .disconnected,
        ]
        for status in statuses {
            #expect(status.localizationKey.hasPrefix("chromecase."))
        }
        #expect(ChromecaseLinkStatus.connected(displayName: "x").isConnected)
        #expect(ChromecaseLinkStatus.connected(displayName: "x").isActive)
        #expect(!ChromecaseLinkStatus.disabled.isActive)
    }

    @Test func voiceEndReasonsDistinguishNormalFromForced() {
        #expect(ChromecaseVoiceEndReason.holdRelease.isNormal)
        #expect(ChromecaseVoiceEndReason.toggleSecondTap.isNormal)
        #expect(!ChromecaseVoiceEndReason.hostStop.isNormal)
        #expect(!ChromecaseVoiceEndReason.cancelled("link_unavailable").isNormal)
    }

    // MARK: - 缺包时的退化行为

    @Test func integrationIsInertWhenPrivatePackageIsAbsent() {
        // 未编入私有包时，接入层必须完全惰性：不崩、不产生任何回调。
        guard !ChromecaseFeatureIntegration.isPackageIncluded else { return }
        let integration = ChromecaseFeatureIntegration()
        var eventCount = 0
        integration.onVoiceStart = { eventCount += 1 }
        integration.onVoiceSustain = { eventCount += 1 }
        integration.onVoiceStop = { _ in eventCount += 1 }
        integration.onSamples = { _, _ in eventCount += 1 }
        integration.onStatusChange = { _ in eventCount += 1 }
        integration.onControlEvent = { _ in eventCount += 1 }
        integration.onHIDPresenceChange = { _ in eventCount += 1 }

        integration.start()
        integration.setVoiceMode(.hold)
        integration.setControlMappingEnabled(true)
        integration.setControlMappingEnabled(false)
        integration.reconnect()
        integration.notifyHostVoiceSessionEnded()
        integration.stop()

        #expect(eventCount == 0)
        #expect(!integration.isHIDRemotePresent)
    }

    // MARK: - 打包与接线契约

    @Test func chromecasePackageStaysOptionalForHostBuilds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageSource = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(packageSource.contains("SAYALL_CHROMECASE_PACKAGE_PATH"))
        #expect(packageSource.contains("SAYALL_CHROMECASE_ENABLED"))
        #expect(packageSource.contains("SayAllChromecase"))
        #expect(buildSource.contains("SAYALL_CHROMECASE_INCLUDED=false"))
        #expect(buildSource.contains("SayAllChromecaseIncluded"))
        #expect(modelSource.contains("#if SAYALL_CHROMECASE_ENABLED"))
        #expect(modelSource.contains("owner: .chromecase"))
        #expect(modelSource.contains("receiveChromecaseAudio"))
        // 缺失私有包必须是普通的代码路径，不能是构建期 fatalError。
        #expect(!packageSource.contains("fatalError(\"SAYALL_CHROMECASE"))
    }

    @Test func chromecasePanelChangesReachTheRuntimeWithoutRestart() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        // 面板里开关与模式选择必须走同一条「立即作用于运行时」的入口。
        #expect(settingsView.contains("model.applyChromecaseSettings()"))
        // 模式推送必须真的发生在运行入口里，而不是只写偏好。
        #expect(modelSource.contains("chromecaseFeature.setVoiceMode(settings.chromecaseVoiceMode)"))
        #expect(modelSource.contains("func applyChromecaseSettings()"))
    }

    // MARK: - 按键页契约

    @Test func everyChromecaseControlMapsToItsOwnRemoteButton() {
        let expected: [ChromecaseRemoteControl: RemoteButton] = [
            .power: .power,
            .up: .up,
            .down: .down,
            .left: .left,
            .right: .right,
            .select: .ok,
            .back: .back,
            .home: .home,
            .mute: .mute,
            .youtube: .youtube,
            .netflix: .netflix,
            .input: .input,
            .volumeUp: .volumeUp,
            .volumeDown: .volumeDown,
        ]
        #expect(ChromecaseRemoteControl.allCases.count == expected.count)
        for control in ChromecaseRemoteControl.allCases {
            #expect(control.remoteButton == expected[control])
        }
        // 一控一键：两个控件映射到同一个键位会让其中一个的配置永远读不到。
        #expect(Set(ChromecaseRemoteControl.allCases.map(\.remoteButton)).count == expected.count)
    }

    @Test func chromecaseOnlyButtonsStayOutOfTheXiaomiLayout() {
        for button in [RemoteButton.youtube, .netflix, .input] {
            #expect(!RemoteButton.xiaomiCases.contains(button))
        }
        // 小米画布的锚点表按 xiaomiCases 生成，新增的键位不得改变它的规模。
        #expect(RemoteButton.xiaomiCases.count == 12)
    }

    @Test func chromecaseModelIsRoutedToItsOwnAdapter() {
        #expect(XiaomiRemoteModel.chromecaseVoiceRemote.isChromecaseRemote)
        #expect(!XiaomiRemoteModel.chromecaseVoiceRemote.isAppleSiriRemote)
        #expect(XiaomiRemoteModel.chromecaseVoiceRemote.usesPrivateAdapter)
        #expect(XiaomiRemoteModel.appleSiriRemoteA2854.usesPrivateAdapter)
        #expect(!XiaomiRemoteModel.rc003.usesPrivateAdapter)
        #expect(XiaomiRemoteModel.chromecaseVoiceRemote.stableHardwareModelID == "chromecast-voice-remote")
        #expect(XiaomiRemoteModel.chromecaseVoiceRemote.localizationKey.hasPrefix("remote.device.model."))
    }

    /// 该型号不宣告电池能力，界面不得显示一个永远是「未知」的电量位。
    @Test func chromecaseProfileNeverShowsBattery() {
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .chromecaseVoiceRemote,
            level: 42,
            powerState: .onBattery
        ))
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .chromecaseVoiceRemote,
            level: nil,
            powerState: .charging
        ))
        #expect(RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .rc003,
            level: 42,
            powerState: .onBattery
        ))
    }

    /// Chromecase 设备档案按型号识别并且可重复注册，否则每次连接都会新建一个档案、丢掉映射。
    @Test func chromecaseProfileRegistrationIsIdempotent() throws {
        let suiteName = "RemoteMicTests.ChromecaseProfile.(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        let first = settings.registerChromecaseRemote()
        let second = settings.registerChromecaseRemote()

        #expect(first == second)
        #expect(settings.selectedRemoteProfile?.model == .chromecaseVoiceRemote)
        let profile = try #require(settings.remoteDeviceProfiles.first(where: { $0.id == first }))
        #expect(profile.model == .chromecaseVoiceRemote)
        #expect(settings.remoteDeviceProfiles.filter { $0.model == .chromecaseVoiceRemote }.count == 1)
    }

    // MARK: - 按键页接线契约

    @Test func mappingPageRoutesChromecaseToItsOwnCanvas() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsView = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        // 按键页必须按型号分派到 Chromecase 画布，且整块受私有包门禁保护。
        #expect(settingsView.contains("chromecaseMappingPage"))
        #expect(settingsView.contains("canImport(SayAllChromecase)"))
        // 映射总开关必须真的推给 HID 通道：独占与否决定了按键是被宿主还是被系统消费。
        #expect(modelSource.contains(
            "chromecaseFeature.setControlMappingEnabled(settings.customMappingEnabled)"
        ))
        // 私有包档案不得被小米 HID 发现链路当成候选。
        #expect(modelSource.contains("!profile.model.usesPrivateAdapter"))
        // 按键事件必须接到执行链路上，而不是只更新界面状态。
        #expect(modelSource.contains("handleChromecaseControlEvent"))
        #expect(modelSource.contains("performChromecaseConfiguredAction"))
    }

    @Test func chromecaseNeverCapturesFromTheComputerMicrophone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        // 第一版只走遥控器麦克风到 MiRemoteV 2ch，不做混音、不回退电脑麦克风。
        #expect(modelSource.contains("route=MiRemoteV_2ch"))
        #expect(!modelSource.contains("chromecaseAudioMixer"))
    }
}
