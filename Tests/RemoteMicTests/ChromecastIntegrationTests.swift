import Foundation
import Testing
@testable import RemoteMic

@Suite("Chromecast integration")
struct ChromecastIntegrationTests {
    // MARK: - 语音键隔离

    @Test func voiceKeyLatchKeepsHardwareOwnersIndependent() {
        var latch = VoiceFunctionKeyLatch()

        // Siri Remote 先按住。
        #expect(latch.transition(streaming: true, owner: .appleRemote) == .press)
        // Chromecast 同时按住：不得产生第二次按下，也不得取消 Siri。
        #expect(latch.transition(streaming: true, owner: .chromecast) == nil)
        #expect(latch.isHeld)
        // Siri 松手：Chromecast 仍按住，语音键不得抬起。
        #expect(latch.transition(streaming: false, owner: .appleRemote) == nil)
        #expect(latch.isHeld)
        // Chromecast 松手：此时才真正抬起。
        #expect(latch.transition(streaming: false, owner: .chromecast) == .release)
        #expect(!latch.isHeld)
    }

    @Test func chromecastPressesAndReleasesVoiceKeyOnItsOwn() {
        var latch = VoiceFunctionKeyLatch()

        #expect(latch.transition(streaming: true, owner: .chromecast) == .press)
        #expect(latch.isHeld)
        #expect(latch.transition(streaming: false, owner: .chromecast) == .release)
        #expect(!latch.isHeld)
    }

    @Test func chromecastOwnerIsDistinctFromEveryOtherHardware() {
        let owners: Set<VoiceFunctionKeyLatch.Owner> = [
            .bluetooth,
            .appleRemote,
            .chromecast,
            .mobile,
        ]
        #expect(owners.count == 4)
    }

    // MARK: - 产品默认值

    @Test func productDefaultVoiceModeIsToggle() {
        // 需求：toggle 为默认语音模式，hold 保留给用户可选切换。
        #expect(ChromecastVoiceMode.productDefault == .toggle)
        #expect(ChromecastVoiceMode.allCases == [.toggle, .hold])
    }

    @Test func everyLinkStatusHasALocalizationKey() {
        let statuses: [ChromecastLinkStatus] = [
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
            #expect(status.localizationKey.hasPrefix("chromecast."))
        }
        #expect(ChromecastLinkStatus.connected(displayName: "x").isConnected)
        #expect(ChromecastLinkStatus.connected(displayName: "x").isActive)
        #expect(!ChromecastLinkStatus.disabled.isActive)
    }

    @Test func voiceEndReasonsDistinguishNormalFromForced() {
        #expect(ChromecastVoiceEndReason.holdRelease.isNormal)
        #expect(ChromecastVoiceEndReason.toggleSecondTap.isNormal)
        #expect(!ChromecastVoiceEndReason.hostStop.isNormal)
        #expect(!ChromecastVoiceEndReason.cancelled("link_unavailable").isNormal)
    }

    // MARK: - 缺包时的退化行为

    @Test func integrationIsInertWhenPrivatePackageIsAbsent() {
        // 未编入私有包时，接入层必须完全惰性：不崩、不产生任何回调。
        guard !ChromecastFeatureIntegration.isPackageIncluded else { return }
        let integration = ChromecastFeatureIntegration()
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

    @Test func chromecastPackageStaysOptionalForHostBuilds() throws {
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

        #expect(packageSource.contains("SAYALL_CHROMECAST_PACKAGE_PATH"))
        #expect(packageSource.contains("SAYALL_CHROMECAST_ENABLED"))
        #expect(packageSource.contains("SayAllChromecast"))
        #expect(buildSource.contains("SAYALL_CHROMECAST_INCLUDED=false"))
        #expect(buildSource.contains("SayAllChromecastIncluded"))
        #expect(modelSource.contains("#if SAYALL_CHROMECAST_ENABLED"))
        #expect(modelSource.contains("owner: .chromecast"))
        #expect(modelSource.contains("receiveChromecastAudio"))
        // 缺失私有包必须是普通的代码路径，不能是构建期 fatalError。
        #expect(!packageSource.contains("fatalError(\"SAYALL_CHROMECAST"))
    }

    @Test func chromecastPanelChangesReachTheRuntimeWithoutRestart() throws {
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
        #expect(settingsView.contains("model.applyChromecastSettings()"))
        // 模式推送必须真的发生在运行入口里，而不是只写偏好；
        // 且推的是「生效模式」——设备自报不支持「按一次」时必须按「按住说话」执行。
        #expect(modelSource.contains("chromecastFeature.setVoiceMode(effectiveChromecastVoiceMode)"))
        #expect(modelSource.contains("var effectiveChromecastVoiceMode"))
        #expect(modelSource.contains("func applyChromecastSettings()"))
    }

    // MARK: - 按键页契约

    @Test func everyChromecastControlMapsToItsOwnRemoteButton() {
        let expected: [ChromecastRemoteControl: RemoteButton] = [
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
        #expect(ChromecastRemoteControl.allCases.count == expected.count)
        for control in ChromecastRemoteControl.allCases {
            #expect(control.remoteButton == expected[control])
        }
        // 一控一键：两个控件映射到同一个键位会让其中一个的配置永远读不到。
        #expect(Set(ChromecastRemoteControl.allCases.map(\.remoteButton)).count == expected.count)
    }

    // MARK: - 系统占用键豁免

    @Test func systemReservedKeysStayWithTheSystemByDefault() {
        for control in ChromecastRemoteControl.systemReservedControls {
            #expect(
                ChromecastRemoteControl.isSystemManaged(
                    control,
                    allowSystemReservedKeys: false
                )
            )
        }
        // 非系统占用键不受开关影响。
        #expect(
            !ChromecastRemoteControl.isSystemManaged(
                .volumeUp,
                allowSystemReservedKeys: false
            )
        )
    }

    @Test func exceptionsReleaseIndividualKeys() {
        // 按键级豁免：只放开的键由 App 接管，其余仍归系统（三键代价不同：左/右=播放时切歌，
        // OK=任何时候拉起音乐 App，需要能单独取舍）。
        let exceptions: Set<String> = ["left", "right"]
        #expect(!ChromecastRemoteControl.isSystemManaged(.left, allowSystemReservedKeys: false, exceptions: exceptions))
        #expect(!ChromecastRemoteControl.isSystemManaged(.right, allowSystemReservedKeys: false, exceptions: exceptions))
        #expect(ChromecastRemoteControl.isSystemManaged(.select, allowSystemReservedKeys: false, exceptions: exceptions))
        #expect(
            ChromecastRemoteControl.canvasReservedControlIDs(
                allowSystemReservedKeys: false,
                exceptions: exceptions
            ) == ["select"]
        )
        // 主开关仍然全放开（两者相加生效）。
        #expect(
            ChromecastRemoteControl.canvasReservedControlIDs(
                allowSystemReservedKeys: true,
                exceptions: exceptions
            ).isEmpty
        )
    }

    @Test func allowSystemReservedKeysReleasesAllThreeForTesting() {
        for control in ChromecastRemoteControl.systemReservedControls {
            #expect(
                !ChromecastRemoteControl.isSystemManaged(
                    control,
                    allowSystemReservedKeys: true
                )
            )
        }
    }

    @Test func chromecastOnlyButtonsStayOutOfTheXiaomiLayout() {
        for button in [RemoteButton.youtube, .netflix, .input] {
            #expect(!RemoteButton.xiaomiCases.contains(button))
        }
        // 小米画布的锚点表按 xiaomiCases 生成，新增的键位不得改变它的规模。
        #expect(RemoteButton.xiaomiCases.count == 12)
    }

    @Test func chromecastModelIsRoutedToItsOwnAdapter() {
        #expect(XiaomiRemoteModel.chromecastVoiceRemote.isChromecastRemote)
        #expect(!XiaomiRemoteModel.chromecastVoiceRemote.isAppleSiriRemote)
        #expect(XiaomiRemoteModel.chromecastVoiceRemote.usesPrivateAdapter)
        #expect(XiaomiRemoteModel.appleSiriRemoteA2854.usesPrivateAdapter)
        #expect(!XiaomiRemoteModel.rc003.usesPrivateAdapter)
        #expect(XiaomiRemoteModel.chromecastVoiceRemote.stableHardwareModelID == "chromecast-voice-remote")
        #expect(XiaomiRemoteModel.chromecastVoiceRemote.localizationKey.hasPrefix("remote.device.model."))
    }

    /// 该型号不宣告电池能力，界面不得显示一个永远是「未知」的电量位。
    @Test func chromecastProfileNeverShowsBattery() {
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .chromecastVoiceRemote,
            level: 42,
            powerState: .onBattery
        ))
        #expect(!RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .chromecastVoiceRemote,
            level: nil,
            powerState: .charging
        ))
        #expect(RemoteBatteryPresentationPolicy.shouldShowBattery(
            model: .rc003,
            level: 42,
            powerState: .onBattery
        ))
    }

    /// Chromecast 设备档案按型号识别并且可重复注册，否则每次连接都会新建一个档案、丢掉映射。
    @Test func chromecastProfileRegistrationIsIdempotent() throws {
        let suiteName = "RemoteMicTests.ChromecastProfile.(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        let first = settings.registerChromecastRemote()
        let second = settings.registerChromecastRemote()

        #expect(first == second)
        #expect(settings.selectedRemoteProfile?.model == .chromecastVoiceRemote)
        let profile = try #require(settings.remoteDeviceProfiles.first(where: { $0.id == first }))
        #expect(profile.model == .chromecastVoiceRemote)
        #expect(settings.remoteDeviceProfiles.filter { $0.model == .chromecastVoiceRemote }.count == 1)
    }

    // MARK: - 按键页接线契约

    @Test func mappingPageRoutesChromecastToItsOwnCanvas() throws {
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

        // 按键页必须按型号分派到 Chromecast 画布，且整块受私有包门禁保护。
        #expect(settingsView.contains("chromecastMappingPage"))
        #expect(settingsView.contains("canImport(SayAllChromecast)"))
        // 映射总开关必须真的推给 HID 通道：独占与否决定了按键是被宿主还是被系统消费。
        #expect(modelSource.contains(
            "chromecastFeature.setControlMappingEnabled(settings.customMappingEnabled)"
        ))
        // 私有包档案不得被小米 HID 发现链路当成候选。
        #expect(modelSource.contains("!profile.model.usesPrivateAdapter"))
        // 按键事件必须接到执行链路上，而不是只更新界面状态。
        #expect(modelSource.contains("handleChromecastControlEvent"))
        #expect(modelSource.contains("performChromecastConfiguredAction"))
    }

    @Test func chromecastNeverCapturesFromTheComputerMicrophone() throws {
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
        #expect(!modelSource.contains("chromecastAudioMixer"))
    }
}
