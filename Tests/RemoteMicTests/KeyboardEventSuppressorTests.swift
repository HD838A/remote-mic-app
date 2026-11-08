import AppKit
import Foundation
import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("Keyboard event suppressor")
struct KeyboardEventSuppressorTests {
    @Test(arguments: [RemoteNativeEvent.systemKey(type: 0), .systemKey(type: 1), .systemKey(type: 16), .keyboard(keyCode: 115), .keyboard(keyCode: 36)])
    func delayedNativePairRemainsOwnedAfterRemoteRelease(_ native: RemoteNativeEvent) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.14
        #expect(suppressor.handle(type: down.type, event: down))
        now += 0.001
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func releasingRemoteDoesNotDiscardAnUnconsumedEarlyDown() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .systemKey(type: 0)
        let down = try nativeEvent(native, down: true)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.08
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.01
        #expect(suppressor.handle(type: down.type, event: down))
    }

    @Test func missingNativeEdgesExpireWithoutBlockingPhysicalInput() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .keyboard(keyCode: 115)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.501
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func overlappingClicksConsumeOnlyTheirExpectedEdges() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .systemKey(type: 1)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now = 10.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now = 10.29
        suppressor.arm(nativeEvents: [native], edge: .down)
        now = 10.30
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(suppressor.handle(type: up.type, event: up))
        now = 10.46
        suppressor.arm(nativeEvents: [native], edge: .up)
        now = 10.60
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test func nativeUpCanArriveBeforeDelayedDown() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .keyboard(keyCode: 115)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.17
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.14
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test(arguments: [RemoteNativeEvent.systemKey(type: 0), .systemKey(type: 1), .systemKey(type: 16), .keyboard(keyCode: 115)])
    func nativeReleaseBeforeHIDReleaseClosesOnlyTheOwnedPair(_ native: RemoteNativeEvent) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        now += 0.17
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: up.type, event: up))
        now += 0.013
        suppressor.arm(nativeEvents: [native], edge: .up)
        // The late raw release must not leave another native-up allowance.
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    @Test func unownedNativeReleaseIsNeverClaimedByRawHoldAlone() throws {
        let native: RemoteNativeEvent = .systemKey(type: 1)
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { _ in })
        suppressor.arm(nativeEvents: [native], edge: .down)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: up.type, event: up))
        let down = try nativeEvent(native, down: true)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.stop()
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func releasedOwnershipCannotClaimTheNextPressWithoutANativeDown() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native: RemoteNativeEvent = .systemKey(type: 1)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        now += 0.501
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func earlyDownDiagnosticDoesNotRetroactivelyConsumeInput() throws {
        var now: TimeInterval = 10
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        let down = try nativeEvent(.keyboard(keyCode: 115), down: true)
        #expect(!suppressor.handle(type: down.type, event: down))
        now += 0.079
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 115)], edge: .down)
        #expect(logs.contains { $0.contains("phase=arm_order") && $0.contains("source_correlation=timing_only") })
        logs.removeAll()
        now += 0.501
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 115)], edge: .down)
        #expect(!logs.contains { $0.contains("phase=arm_order") })
    }

    @Test(arguments: [Int32(0), Int32(1)], [false, true])
    func escapedVolumeDownKeepsItsReleaseAndDoesNotStealTheNextPress(
        _ keyType: Int32, _ nativeReleaseFirst: Bool
    ) throws {
        var now: TimeInterval = 10
        let native: RemoteNativeEvent = .systemKey(type: keyType)
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        // Replay the recorded native down -> HID down -> HID up -> native up.
        #expect(!suppressor.handle(type: down.type, event: down))
        now += 0.011
        suppressor.arm(nativeEvents: [native], edge: .down)
        now += 0.15
        if nativeReleaseFirst {
            #expect(!suppressor.handle(type: up.type, event: up))
            suppressor.arm(nativeEvents: [native], edge: .up)
        } else {
            suppressor.arm(nativeEvents: [native], edge: .up)
            #expect(!suppressor.handle(type: up.type, event: up))
        }
        #expect(logs.filter { $0.contains("phase=arm result=passthrough") }.count == 2)
        #expect(logs.contains { $0.contains("edge=up reason=escaped_native_pair") })
        // No stale expected down may consume the following physical volume key.
        now += 0.25
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func escapedVolumeHoldPassesRepeatsAndReleaseBeyondTheDeliveryWindow(_ keyType: Int32) throws {
        var now: TimeInterval = 10
        let native: RemoteNativeEvent = .systemKey(type: keyType)
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: down.type, event: down))
        now += 0.011
        suppressor.arm(nativeEvents: [native], edge: .down)
        for _ in 0..<5 {
            now += 0.2
            #expect(!suppressor.handle(type: down.type, event: down))
        }
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(!suppressor.handle(type: up.type, event: up))
        // Once the escaped pair closes, normally ordered remote input is filtered.
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [RemoteButton.volumeUp, .volumeDown, .tv], [false, true])
    func managedNativeKeysAreArmedBeforeReportDiagnosticsAndConfigurationCallbacks(
        _ button: RemoteButton, _ isSeized: Bool
    ) throws {
        let suite = "KeyboardEventSuppressorTests.earlyVolume.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.customShortcut, for: button)
        settings.setShortcut(CustomKeyboardShortcut(keyCode: 43, modifierFlags: [], keyLabel: ","), for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        let profile = try #require(settings.selectedRemoteProfileID)
        let native = try #require(button.nativeEvents.first)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var deliveredNativeDown = false
        var performed: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings, profileID: profile, eventSuppressor: suppressor,
            ownsEventSuppressor: false, runtimePermissions: { true },
            actionPerformer: { _, _, configured in performed.append(configured.action); return true },
            diagnosticLogger: { message in
                if message.contains("HID REPORT accepted"), !deliveredNativeDown {
                    deliveredNativeDown = true
                    #expect(suppressor.handle(type: down.type, event: down))
                }
            }
        )
        monitor.connectSimulatedDevice(fingerprint: "volume-early-arm", profileID: profile, isSeized: isSeized)
        defer { monitor.disconnectSimulatedDevice() }
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        #expect(deliveredNativeDown)
        #expect(performed == [.customShortcut])
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [
        RemoteButton.power, .up, .left, .ok, .right, .down, .back, .home, .menu,
    ], [false, true])
    func sourceNeutralizedKeysDoNotLeaveCreditsThatConsumePhysicalKeyboardInput(
        _ button: RemoteButton, _ disconnectWhileHeld: Bool
    ) throws {
        let suite = "KeyboardEventSuppressorTests.sourceNeutralized.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.customShortcut, for: button)
        settings.setShortcut(CustomKeyboardShortcut(keyCode: 43, modifierFlags: [], keyLabel: ","), for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        settings.setAllowsRapidPress(true, for: button)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var performed = 0
        let monitor = HIDRemoteMonitor(
            settings: settings, eventSuppressor: suppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in performed += 1; return true },
            diagnosticLogger: { _ in }, prepareNativeKeys: { true }
        )
        monitor.connectSimulatedDevice(
            fingerprint: "neutralized-remote", profileID: settings.selectedRemoteProfileID
        )
        for _ in 0..<10 {
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
            for native in button.nativeEvents {
                let down = try nativeEvent(native, down: true)
                #expect(!suppressor.handle(type: down.type, event: down))
            }
            monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
            for native in button.nativeEvents {
                let up = try nativeEvent(native, down: false)
                #expect(!suppressor.handle(type: up.type, event: up))
            }
        }
        #expect(performed == 10)
        if disconnectWhileHeld {
            monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        }
        monitor.disconnectSimulatedDevice()
        suppressor.stop()
        for native in button.nativeEvents {
            let up = try nativeEvent(native, down: false)
            #expect(!suppressor.handle(type: up.type, event: up))
        }
    }

    @Test(arguments: [RemoteButton.volumeUp, .volumeDown, .tv])
    func sourceMappingDoesNotDisableNativeSuppression(_ button: RemoteButton) throws {
        let suite = "KeyboardEventSuppressorTests.sourceMappingFallback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.customShortcut, for: button)
        settings.setShortcut(CustomKeyboardShortcut(keyCode: 43, modifierFlags: [], keyLabel: ","), for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        let monitor = HIDRemoteMonitor(
            settings: settings, eventSuppressor: suppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in true },
            diagnosticLogger: { _ in }, prepareNativeKeys: { true }
        )
        #expect(monitor.connectSimulatedDevice(
            fingerprint: "source-mapping-fallback", profileID: settings.selectedRemoteProfileID,
            isSeized: false
        ))
        let native: RemoteNativeEvent = button == .tv
            ? .keyboard(keyCode: 10)
            : try #require(button.nativeEvent)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        #expect(suppressor.handle(type: down.type, event: down))
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        #expect(suppressor.handle(type: up.type, event: up))
        monitor.disconnectSimulatedDevice()
    }

    @Test(arguments: [RemoteButton.left, .right])
    func sourceIsolatedDefaultArrowsAreExecutedInsteadOfWaitingForNativePassthrough(_ button: RemoteButton) throws {
        let suite = "KeyboardEventSuppressorTests.defaultArrows.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(button == .left ? .arrowLeft : .arrowRight, for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        var performed = 0
        let monitor = HIDRemoteMonitor(
            settings: settings, ownsEventSuppressor: false, runtimePermissions: { true },
            actionPerformer: { _, _, _ in performed += 1; return true },
            frontmostBundleIdentifier: { PresetApplication.safari.bundleIdentifier },
            diagnosticLogger: { _ in }, prepareNativeKeys: { true }
        )
        #expect(monitor.connectSimulatedDevice(fingerprint: "mapped", profileID: settings.selectedRemoteProfileID, isSeized: false))
        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        #expect(performed == 1)
        monitor.disconnectSimulatedDevice()
    }

    /// Intel 现场（2026-11-07）：独占打开失败后走 monitored，源头映射回读一致，
    /// 但系统仍会投递原生方向键；主线程登记晚于该事件约 200 ms，于是 App 自己
    /// 注入的一次移动 + 泄漏的一次移动 = 光标跳过两格。方向键必须和 TV、音量
    /// 一样保留事件级兜底。
    @Test(arguments: [RemoteButton.left, .right, .up, .down])
    func monitoredDirectionalPressOwnsItsLeakedNativeEvent(_ button: RemoteButton) throws {
        let suite = "KeyboardEventSuppressorTests.directionalLeak.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let action: ButtonAction = switch button {
        case .left: .arrowLeft
        case .right: .arrowRight
        case .up: .arrowUp
        default: .arrowDown
        }
        settings.setAction(action, for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        settings.setAllowsRapidPress(true, for: button)
        let native = try #require(button.nativeEvent)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var performed: [ButtonAction] = []
        let monitor = HIDRemoteMonitor(
            settings: settings, eventSuppressor: suppressor, ownsEventSuppressor: false,
            runtimePermissions: { true },
            actionPerformer: { _, _, configured in performed.append(configured.action); return true },
            frontmostBundleIdentifier: { PresetApplication.safari.bundleIdentifier },
            diagnosticLogger: { _ in }, prepareNativeKeys: { true },
            directionalNativeFallback: true
        )
        #expect(monitor.connectSimulatedDevice(
            fingerprint: "intel-monitored-directional",
            profileID: settings.selectedRemoteProfileID,
            isSeized: false
        ))
        defer { monitor.disconnectSimulatedDevice() }

        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        // 一次按下只允许一次移动：泄漏的原生按下必须被吞掉。
        #expect(suppressor.handle(type: down.type, event: down))
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        #expect(suppressor.handle(type: up.type, event: up))
        #expect(performed == [action])
    }

    /// 反向边界：源头映射未生效的 monitored 会话里，默认左右动作故意交给系统
    /// 原生事件执行。此时若抢先登记，唯一一次移动会被吞掉，按键完全没有反应。
    @Test func monitoredPassthroughKeepsTheNativeArrowAsTheOnlyMove() throws {
        let suite = "KeyboardEventSuppressorTests.directionalPassthrough.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.arrowLeft, for: .left)
        settings.setAction(.disabled, for: .left, trigger: .doubleClick)
        settings.setAction(.disabled, for: .left, trigger: .longPress)
        let native = try #require(RemoteButton.left.nativeEvent)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var performed = 0
        let monitor = HIDRemoteMonitor(
            settings: settings, eventSuppressor: suppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in performed += 1; return true },
            frontmostBundleIdentifier: { PresetApplication.safari.bundleIdentifier },
            diagnosticLogger: { _ in }
        )
        #expect(monitor.connectSimulatedDevice(
            fingerprint: "monitored-passthrough",
            profileID: settings.selectedRemoteProfileID,
            isSeized: false
        ))
        defer { monitor.disconnectSimulatedDevice() }

        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(RemoteButton.left.hidUsage), 0, 0, 0, 0, 0]))
        #expect(!suppressor.handle(type: down.type, event: down))
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        #expect(!suppressor.handle(type: up.type, event: up))
        #expect(performed == 0)
    }

    /// 反向边界：没有泄漏证据的构建（Apple Silicon 默认）不得为方向键开拦截窗口。
    /// 窗口内按下的实体键盘方向键会被吞掉一次，极端情况下只吞掉 keyUp，
    /// 系统会认为该键仍然按下并继续连发。
    @Test(arguments: [RemoteButton.left, .right, .up, .down])
    func directionalFallbackKeepsNonLeakingBuildsFreeOfSuppressionWindows(
        _ button: RemoteButton
    ) throws {
        let suite = "KeyboardEventSuppressorTests.directionalFallbackOff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        let action: ButtonAction = switch button {
        case .left: .arrowLeft
        case .right: .arrowRight
        case .up: .arrowUp
        default: .arrowDown
        }
        settings.setAction(action, for: button)
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        settings.setAllowsRapidPress(true, for: button)
        let native = try #require(button.nativeEvent)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var performed = 0
        let monitor = HIDRemoteMonitor(
            settings: settings, eventSuppressor: suppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in performed += 1; return true },
            frontmostBundleIdentifier: { PresetApplication.safari.bundleIdentifier },
            diagnosticLogger: { _ in }, prepareNativeKeys: { true },
            directionalNativeFallback: false
        )
        #expect(monitor.connectSimulatedDevice(
            fingerprint: "apple-silicon-directional",
            profileID: settings.selectedRemoteProfileID,
            isSeized: false
        ))
        defer { monitor.disconnectSimulatedDevice() }

        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        #expect(!suppressor.handle(type: down.type, event: down))
        monitor.handleSimulatedReport(reportID: 1, data: Data(repeating: 0, count: 6))
        #expect(!suppressor.handle(type: up.type, event: up))
        #expect(performed == 1)
    }

    /// 映射未生效（monitored、回读未通过）时方向键本来就没有源头隔离，登记是修复前
    /// 就有的行为。兜底开关只决定「映射已生效」那一段，不能把它一起关掉，
    /// 否则自定义快捷键会和泄漏的原生方向键同时生效。
    @Test(arguments: [RemoteButton.left, .right])
    func unneutralizedDirectionalKeepsItsArmingWithoutTheFallback(_ button: RemoteButton) throws {
        let suite = "KeyboardEventSuppressorTests.unneutralizedDirectional.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.customShortcut, for: button)
        settings.setShortcut(
            CustomKeyboardShortcut(keyCode: 43, modifierFlags: [], keyLabel: ","), for: button
        )
        settings.setAction(.disabled, for: button, trigger: .doubleClick)
        settings.setAction(.disabled, for: button, trigger: .longPress)
        settings.setAllowsRapidPress(true, for: button)
        let native = try #require(button.nativeEvent)
        let down = try nativeEvent(native, down: true)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        var performed = 0
        let monitor = HIDRemoteMonitor(
            settings: settings, eventSuppressor: suppressor, ownsEventSuppressor: false,
            runtimePermissions: { true }, actionPerformer: { _, _, _ in performed += 1; return true },
            frontmostBundleIdentifier: { PresetApplication.safari.bundleIdentifier },
            diagnosticLogger: { _ in },
            directionalNativeFallback: false
        )
        #expect(monitor.connectSimulatedDevice(
            fingerprint: "unneutralized-directional",
            profileID: settings.selectedRemoteProfileID,
            isSeized: false
        ))
        defer { monitor.disconnectSimulatedDevice() }

        monitor.handleSimulatedReport(reportID: 1, data: Data([UInt8(button.hidUsage), 0, 0, 0, 0, 0]))
        // 没有兜底开关也要拦：这条路径与修复前一致。
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(performed == 1)
    }

    @Test func directionalPrearmOnlyCoversSessionsWhereTheAppOwnsTheMove() {
        // 报告线程提前登记的范围：Intel 上映射回读一致、非独占时，原生方向键
        // 仍会先于主线程登记到达，必须提前拦。
        for button in [RemoteButton.up, .down, .left, .right] {
            #expect(HIDRemoteMonitor.prearmsNativeEvent(
                for: button, seized: false, neutralized: true, directionalFallback: true
            ), Comment(rawValue: button.rawValue))
        }
        // 映射未生效的 monitored 会话靠原生透传移动，不能抢先登记。
        #expect(!HIDRemoteMonitor.prearmsNativeEvent(
            for: .left, seized: false, neutralized: false, directionalFallback: true
        ))
        // 独占时系统收不到原生事件，不需要登记。
        #expect(!HIDRemoteMonitor.prearmsNativeEvent(
            for: .left, seized: true, neutralized: true, directionalFallback: true
        ))
        // Apple Silicon 等没有泄漏证据的构建不登记，避免开出吞掉键盘方向键的窗口。
        #expect(!HIDRemoteMonitor.prearmsNativeEvent(
            for: .left, seized: false, neutralized: true, directionalFallback: false
        ))
        // TV 与音量沿用原有范围：始终由 App 执行，与方向键开关无关。
        for button in [RemoteButton.tv, .volumeUp, .volumeDown] {
            #expect(HIDRemoteMonitor.prearmsNativeEvent(
                for: button, seized: false, neutralized: false, directionalFallback: false
            ), Comment(rawValue: button.rawValue))
            #expect(!HIDRemoteMonitor.prearmsNativeEvent(
                for: button, seized: true, neutralized: true, directionalFallback: true
            ), Comment(rawValue: button.rawValue))
        }
        // 其余普通键不提前登记，避免吞掉实体键盘的同码按键。
        #expect(!HIDRemoteMonitor.prearmsNativeEvent(
            for: .ok, seized: false, neutralized: true, directionalFallback: true
        ))
        #expect(!HIDRemoteMonitor.prearmsNativeEvent(
            for: .home, seized: false, neutralized: true, directionalFallback: true
        ))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func stoppingClearsEscapedVolumeOwnership(_ keyType: Int32) throws {
        let native: RemoteNativeEvent = .systemKey(type: keyType)
        let suppressor = KeyboardEventSuppressor(logger: { _ in })
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)
        #expect(!suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.stop()
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func prearmSuppressesANativeVolumeEventThatBeatsTheMainThreadArm(_ keyType: Int32) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: keyType)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)

        // 现场顺序：报告线程先登记，原生按下随即到达，此时主线程还没处理报告。
        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))

        // 主线程随后按报告登记同一次按下，不得追加会吞掉下一次实体按键的记录。
        now += 0.2
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))

        now += 0.6
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    /// 本 Bug 的真实顺序：报告线程的提前登记必须早于主线程的 `arm` 生效。
    /// 这里按现场顺序喂事件（prearm → 原生 down → 主线程 arm），确认方向键走的是
    /// 提前登记这条路径，而不是「有没有登记」这种主线程也能满足的判据。
    @Test func prearmedDirectionalDownBeatsTheMainThreadArm() throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(logger: { logs.append($0) })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.keyboard(keyCode: 123)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)

        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(logs.contains {
            $0.contains("HID FILTER suppressed") && $0.contains("armed_by=prearm")
        })

        // 主线程随后登记同一次按下/松开，不得留下会吞掉下一次实体键盘按键的记录。
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func prearmFollowedByMainThreadArmRegistersOneRecordOnly(_ keyType: Int32) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: keyType)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)

        // 另一种顺序：报告线程先登记，主线程在同一次按下的原生事件之前就完成 arm
        // （Apple Silicon 上常见，Intel 也会因抖动出现）。此时同一次按下只能留一条记录。
        suppressor.prearm(nativeEvents: [native])
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))

        now += 0.05
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))

        // 用户紧接着按实体键盘的音量键：提前登记那一条已被消费，
        // 主线程不得为同一次按下再留下一条会吞掉实体按键的记录。
        now += 0.1
        #expect(!suppressor.handle(type: down.type, event: down))
        #expect(!suppressor.handle(type: up.type, event: up))
    }

    @Test func suppressedLogDistinguishesPrearmFromMainThreadArm() throws {
        var now: TimeInterval = 10
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: 1)
        let down = try nativeEvent(native, down: true)

        // 现场复验靠这两行区分「报告线程提前登记命中」与「主线程登记命中」。
        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(logs.contains { $0.contains("HID FILTER suppressed") && $0.contains("armed_by=prearm") })

        now += 0.6
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        #expect(logs.contains { $0.contains("HID FILTER suppressed") && $0.contains("armed_by=arm") })
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func prearmWithoutNativeDeliveryExpiresWithoutBlockingPhysicalInput(_ keyType: Int32) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: keyType)
        let down = try nativeEvent(native, down: true)

        // 源头映射生效时系统不产生原生事件，提前登记的记录必须自然过期。
        suppressor.prearm(nativeEvents: [native])
        now += 0.501
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test func prearmKeepsNormalOrderedSuppressionWorking() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: 1)
        let down = try nativeEvent(native, down: true)
        let up = try nativeEvent(native, down: false)

        suppressor.prearm(nativeEvents: [native])
        now += 0.002
        suppressor.arm(nativeEvents: [native], edge: .down)
        #expect(suppressor.handle(type: down.type, event: down))
        now += 0.1
        suppressor.arm(nativeEvents: [native], edge: .up)
        #expect(suppressor.handle(type: up.type, event: up))
    }

    @Test func prearmAfterStopDoesNotRegisterPendingEvents() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: 0)
        let down = try nativeEvent(native, down: true)

        // 调用方读完 `acceptsPrearm` 之后、真正登记之前被 stop() 打断：
        // 停止后不得再写入待匹配记录，否则会吞掉之后的真实键盘音量键。
        suppressor.stop()
        suppressor.prearm(nativeEvents: [native])
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test func prearmIsIgnoredBeforeAnyActiveSession() throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        let native = RemoteNativeEvent.systemKey(type: 0)
        let down = try nativeEvent(native, down: true)

        suppressor.prearm(nativeEvents: [native])
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func twoNativeDownsBeforeMainThreadArmsKeepTheirOwnClaims(_ keyType: Int32) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: keyType)
        let down = try nativeEvent(native, down: true)

        // 快速连按两次，且两次原生按下都先于主线程处理报告到达：
        // 主线程此时持有两条各自独立的认领。
        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))

        // 主线程按报告顺序登记：down 1 / up 1 / down 2 / up 2。
        // 第一次松键不得动到第二次按下仍需的认领。
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.arm(nativeEvents: [native], edge: .up)
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.arm(nativeEvents: [native], edge: .up)

        // 用户紧接着按实体键盘的音量键：认领若在第一次松键时被整体清空，
        // 主线程会为第二次按下多留一条待匹配记录，这次真实按键就被吞掉。
        now += 0.1
        #expect(!suppressor.handle(type: down.type, event: down))
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func prearmStillSuppressesAfterPairedClaimsAreConsumed(_ keyType: Int32) throws {
        var now: TimeInterval = 10
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { _ in })
        suppressor.setPrearmActiveForTesting(true)
        let native = RemoteNativeEvent.systemKey(type: keyType)
        let down = try nativeEvent(native, down: true)

        // 连按两次并完成配对之后，第三次提前登记仍必须能吞掉原生按下：
        // 逐条配对不能把「认领已用完」误当成「会话已关闭」。
        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.arm(nativeEvents: [native], edge: .up)
        suppressor.arm(nativeEvents: [native], edge: .down)
        suppressor.arm(nativeEvents: [native], edge: .up)

        now += 0.2
        suppressor.prearm(nativeEvents: [native])
        #expect(suppressor.handle(type: down.type, event: down))
    }

    private func nativeEvent(_ native: RemoteNativeEvent, down: Bool) throws -> CGEvent {
        switch native {
        case let .keyboard(keyCode):
            return try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down))
        case let .systemKey(type):
            let data = Int((type << 16) | ((down ? 0xA : 0xB) << 8))
            let event = try #require(NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1
            ))
            return try #require(event.cgEvent)
        }
    }

    @Test func expiredWindowStopsOrdinaryMissLogsWithoutSuppressingInput() throws {
        var now: TimeInterval = 10
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { now }, logger: { logs.append($0) })
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        let ordinary = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: true))
        #expect(!suppressor.handle(type: .keyDown, event: ordinary))
        #expect(logs.filter { $0.contains("HID FILTER miss") }.count == 1)
        logs.removeAll()
        now = 11
        for _ in 0..<100 {
            #expect(!suppressor.handle(type: .keyDown, event: ordinary))
        }
        #expect(logs.isEmpty)
    }

    @Test func matchingEdgesAreFilteredAndStopClearsDiagnosticState() throws {
        var logs: [String] = []
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { logs.append($0) })
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: false))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        #expect(suppressor.handle(type: .keyDown, event: down))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .up)
        #expect(suppressor.handle(type: .keyUp, event: up))
        suppressor.stop()
        logs.removeAll()
        #expect(!suppressor.handle(type: .keyDown, event: down))
        #expect(logs.isEmpty)
    }

    @Test func syntheticInputBypassesFilterWithoutConsumingPendingEdge() throws {
        let suppressor = KeyboardEventSuppressor(uptime: { 10 }, logger: { _ in })
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        suppressor.arm(nativeEvents: [.keyboard(keyCode: 42)], edge: .down)
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.syntheticEventMarker)
        #expect(!suppressor.handle(type: .keyDown, event: event))
        let realEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true))
        #expect(suppressor.handle(type: .keyDown, event: realEvent))
    }

    @Test func activeArmWindowIncludesOnlyUnexpiredEntries() {
        let event: RemoteNativeEvent = .keyboard(keyCode: 42)

        #expect(
            KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 9.999
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 10
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [(event: event, until: 10)],
                now: 11
            )
        )
    }

    @Test func activeWindowIgnoresExpiredEntriesWhenAnotherEntryRemains() {
        let expired: RemoteNativeEvent = .keyboard(keyCode: 42)
        let active: RemoteNativeEvent = .systemKey(type: 2)

        #expect(
            KeyboardEventSuppressor.hasActiveArmedWindow(
                [
                    (event: expired, until: 10),
                    (event: active, until: 12),
                ],
                now: 11
            )
        )
        #expect(
            !KeyboardEventSuppressor.hasActiveArmedWindow(
                [
                    (event: expired, until: 10),
                    (event: active, until: 12),
                ],
                now: 12
            )
        )
    }
}
