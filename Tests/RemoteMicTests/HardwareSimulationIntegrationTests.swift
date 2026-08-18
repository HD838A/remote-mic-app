#if canImport(HardwareSimulation) && canImport(XiaomiVoiceRemoteSimulation)
import AppKit
import CoreGraphics
import Foundation
import HardwareSimulation
import Testing
import XiaomiVoiceRemoteSimulation
@testable import RemoteMic

enum SimulatedVoiceRemoteModel: CaseIterable {
    case rc001
    case rc003

    var scenario: HardwareScenario {
        get throws {
            switch self {
            case .rc001: try XiaomiVoiceRemoteFixture.rc001ShortVoiceScenario()
            case .rc003: try XiaomiVoiceRemoteFixture.directStreamScenario()
            }
        }
    }
}

@Suite("Hardware simulation integration")
struct HardwareSimulationIntegrationTests {
    @Test(arguments: SimulatedVoiceRemoteModel.allCases)
    func simulatedDirectStreamsPreserveDecodedAudioThroughRemoteStop(
        _ model: SimulatedVoiceRemoteModel
    ) throws {
        let profile = try XiaomiVoiceRemoteFixture.profile()
        let catalog = try HardwareCatalog(profiles: [profile])
        let runner = try HardwareScenarioRunner(
            scenario: try model.scenario,
            catalog: catalog
        )

        var capabilities: ATVVCapabilities?
        var accumulator = FrameAccumulator()
        let decoder = IMAADPCMDecoder()
        var streaming = false
        var decodedSamples: [Int16] = []
        var queuedSamples: [Int16] = []

        while let signal = runner.nextSignal() {
            if signal.kind == XiaomiVoiceRemoteSignalKind.notificationState,
               signal.payload["characteristicUUID"]?.stringValue == XiaomiVoiceRemoteFixture.controlUUID,
               signal.payload["enabled"] == .bool(true) {
                let command = XiaomiVoiceRemoteFixture.getCapabilitiesCommand()
                #expect(command.payload["valueHex"]?.stringValue == ATVVProtocol.getCapabilitiesV10.hexString)
                #expect(try runner.receive(command) == ["respond-to-atvv-capabilities-request"])
                continue
            }

            guard let value = BLEGATTValue(signal: signal) else { continue }
            if value.characteristicUUID == XiaomiVoiceRemoteFixture.controlUUID {
                switch value.value.first {
                case 0x0B:
                    guard let parsed = ATVVCapabilities.parse(value.value) else {
                        Issue.record("模拟硬件返回了无效的 ATVV 能力包")
                        continue
                    }
                    capabilities = parsed
                case 0x04:
                    let activeCapabilities = try #require(capabilities)
                    #expect(ATVVProtocol.supportsAudio(sampleRate: activeCapabilities.sampleRate))
                    streaming = true
                    accumulator.reset()
                    decoder.reset()
                case 0x00:
                    streaming = false
                    if BluetoothVoiceStopPolicy.shouldFlushAudio(handledByFnTapMode: false) {
                        queuedSamples.removeAll()
                    }
                default:
                    break
                }
            } else if value.characteristicUUID == XiaomiVoiceRemoteFixture.audioUUID {
                let activeCapabilities = try #require(capabilities)
                #expect(streaming)
                for frame in accumulator.append(value.value, frameSize: activeCapabilities.frameSize) {
                    let samples = PCMPostprocessor.process(
                        decoder.decode(frame),
                        gainDB: 0
                    )
                    decodedSamples.append(contentsOf: samples)
                    queuedSamples.append(contentsOf: samples)
                }
            }
        }

        #expect(capabilities?.version == 0x0100)
        #expect(capabilities?.frameSize == 120)
        #expect(decodedSamples.count == 240)
        #expect(decodedSamples.prefix(3) == [1, 2, 3])
        #expect(queuedSamples == decodedSamples)
        #expect(!streaming)
        #expect(accumulator.pending.isEmpty)
    }

    @Test(arguments: SimulatedVoiceRemoteModel.allCases)
    func firstSimulatedVoiceStreamWaitsForTheNewTargetAndReplaysCompletely(
        _ model: SimulatedVoiceRemoteModel
    ) throws {
        let runner = try HardwareScenarioRunner(
            scenario: try model.scenario,
            catalog: HardwareCatalog(profiles: [try XiaomiVoiceRemoteFixture.profile()])
        )
        let scheduler = VoiceInputManualScheduler()
        var destination = voiceInputTestSnapshot(
            bundleIdentifier: "com.example.previous",
            role: "AXWindow",
            editable: false
        )
        var functionKeyEvents: [Bool] = []
        var queuedSamples: [Int16] = []
        var drainCompletions: [() -> Void] = []
        let coordinator = VoiceInputDestinationCoordinator(
            schedule: scheduler.schedule,
            snapshot: { destination }
        )
        let controller = VoiceFnTapSessionController(
            schedule: scheduler.schedule,
            destinationReadiness: coordinator.waitUntilReady,
            setFunctionKeyPressed: {
                functionKeyEvents.append($0)
                return true
            },
            enqueueAudio: { queuedSamples.append(contentsOf: $0) },
            drainAudio: { drainCompletions.append($0) },
            onFailure: { Issue.record("Fn tap unexpectedly failed: \($0.rawValue)") }
        )
        controller.setEnabled(true)
        coordinator.beginTargetSwitch(
            intent: .application(bundleIdentifier: "com.example.target")
        )

        var capabilities: ATVVCapabilities?
        var accumulator = FrameAccumulator()
        let decoder = IMAADPCMDecoder()
        var decodedSamples: [Int16] = []
        while let signal = runner.nextSignal() {
            if signal.kind == XiaomiVoiceRemoteSignalKind.notificationState,
               signal.payload["characteristicUUID"]?.stringValue == XiaomiVoiceRemoteFixture.controlUUID,
               signal.payload["enabled"] == .bool(true) {
                _ = try runner.receive(XiaomiVoiceRemoteFixture.getCapabilitiesCommand())
                continue
            }
            guard let value = BLEGATTValue(signal: signal) else { continue }
            if value.characteristicUUID == XiaomiVoiceRemoteFixture.controlUUID {
                switch value.value.first {
                case 0x0B:
                    capabilities = ATVVCapabilities.parse(value.value)
                case 0x04:
                    accumulator.reset()
                    decoder.reset()
                    #expect(controller.startVoice())
                case 0x00:
                    #expect(controller.stopVoice())
                default:
                    break
                }
            } else if value.characteristicUUID == XiaomiVoiceRemoteFixture.audioUUID {
                let activeCapabilities = try #require(capabilities)
                for frame in accumulator.append(value.value, frameSize: activeCapabilities.frameSize) {
                    let samples = PCMPostprocessor.process(decoder.decode(frame), gainDB: 0)
                    decodedSamples.append(contentsOf: samples)
                    #expect(controller.receive(samples))
                }
            }
        }

        #expect(decodedSamples.count == 240)
        #expect(functionKeyEvents.isEmpty)
        #expect(queuedSamples.isEmpty)

        destination = voiceInputTestSnapshot(bundleIdentifier: "com.example.target")
        scheduler.advance(by: 0.05)
        scheduler.advance(by: 0.12)
        #expect(functionKeyEvents == [true, false])
        #expect(queuedSamples == decodedSamples)
        #expect(drainCompletions.count == 1)

        drainCompletions.removeFirst()()
        scheduler.advance(by: 0.12)
        #expect(functionKeyEvents == [true, false, true, false])
        #expect(controller.phase == .idle)
    }

    @Test func simulatedHIDReportsDriveProductionParser() throws {
        let catalog = try HardwareCatalog(profiles: [XiaomiVoiceRemoteFixture.profile()])
        let runner = try HardwareScenarioRunner(
            scenario: try XiaomiVoiceRemoteFixture.hidButtonScenario(),
            catalog: catalog
        )
        var usages: [Set<UInt16>] = []

        runner.runUntilIdle { signal in
            guard let report = HIDInputReport(signal: signal),
                  let parsed = RemoteHIDReportParser.usages(
                      reportID: report.reportID,
                      data: report.data
                  )
            else { return }
            usages.append(parsed)
        }

        #expect(usages == [Set([UInt16(0x28)]), Set<UInt16>()])
        #expect(RemoteButton.buttons(for: usages[0]) == [.ok])
    }

    @Test(arguments: XiaomiVoiceRemoteButton.allCases)
    func allTwelveRawButtonsDriveTheProductionParser(
        _ simulatedButton: XiaomiVoiceRemoteButton
    ) throws {
        let parsed = try #require(RemoteHIDReportParser.usages(
            reportID: simulatedButton.report.reportID,
            data: simulatedButton.report.data
        ))
        let remoteButton = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        #expect(parsed == [simulatedButton.usage])
        #expect(RemoteButton.buttons(for: parsed) == [remoteButton])
    }

    @Test(
        arguments: XiaomiVoiceRemoteButton.allCases,
        XiaomiVoiceRemoteGesture.allCases
    )
    func allThirtySixGesturesDriveProductionHIDTiming(
        _ simulatedButton: XiaomiVoiceRemoteButton,
        _ simulatedGesture: XiaomiVoiceRemoteGesture
    ) throws {
        let button = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        let trigger = try #require(ButtonTrigger(rawValue: simulatedGesture.rawValue))
        let result = try driveHIDScenario(
            XiaomiVoiceRemoteFixture.hidButtonScenario(
                button: simulatedButton,
                gesture: simulatedGesture
            ),
            configure: { settings in
                settings.setAction(.escape, for: button, trigger: .singleClick)
                settings.setAction(.appSwitcher, for: button, trigger: .doubleClick)
                settings.setAction(.openCodex, for: button, trigger: .longPress)
            }
        )

        let expectedAction: ButtonAction = switch trigger {
        case .singleClick: .escape
        case .doubleClick: .appSwitcher
        case .longPress: .openCodex
        }
        #expect(result.events == [
            HIDPerformedAction(button: button, trigger: trigger, action: expectedAction)
        ])
    }

    @Test(arguments: XiaomiVoiceRemoteButton.allCases.filter(\.isRepeatable))
    func allSevenRepeatableButtonsRepeatAndStopOnRelease(
        _ simulatedButton: XiaomiVoiceRemoteButton
    ) throws {
        let button = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        let scenario = XiaomiVoiceRemoteFixture.hidRepeatScenario(button: simulatedButton)
        let result = try driveHIDScenario(scenario) { settings in
            settings.setAction(.volumeDown, for: button, trigger: .singleClick)
            settings.setAction(.disabled, for: button, trigger: .doubleClick)
            settings.setAction(.disabled, for: button, trigger: .longPress)
        }
        let interval = try #require(HIDRemoteTiming.repeatIntervalMilliseconds(for: button))
        let firstRepeatAt = 10 + HIDRemoteTiming.repeatStartMilliseconds
        let releaseAt: UInt64 = 760
        let repeatCount = Int((releaseAt - firstRepeatAt) / interval) + 1
        #expect(result.events.count == 1 + repeatCount)
        #expect(result.events.allSatisfy {
            $0 == HIDPerformedAction(
                button: button,
                trigger: .singleClick,
                action: .volumeDown
            )
        })
        #expect(result.scheduler.pendingTaskCount == 0)
    }

    @Test(arguments: [XiaomiVoiceRemoteButton.left, .right])
    func leftAndRightRepeatTheirArrowActionsWithoutSecondaryGestures(
        _ simulatedButton: XiaomiVoiceRemoteButton
    ) throws {
        let button = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        let action: ButtonAction = button == .left ? .arrowLeft : .arrowRight
        let result = try driveHIDScenario(
            XiaomiVoiceRemoteFixture.hidRepeatScenario(button: simulatedButton)
        ) { settings in
            settings.setAction(action, for: button, trigger: .singleClick)
            settings.setAction(.disabled, for: button, trigger: .doubleClick)
            settings.setAction(.disabled, for: button, trigger: .longPress)
        }
        let interval = try #require(HIDRemoteTiming.repeatIntervalMilliseconds(for: button))
        let firstRepeatAt = 10 + HIDRemoteTiming.repeatStartMilliseconds
        let releaseAt: UInt64 = 760
        let repeatCount = Int((releaseAt - firstRepeatAt) / interval) + 1

        #expect(result.events.count == 1 + repeatCount)
        #expect(result.events.allSatisfy {
            $0 == HIDPerformedAction(
                button: button,
                trigger: .singleClick,
                action: action
            )
        })
        #expect(result.scheduler.pendingTaskCount == 0)
    }

    @Test(arguments: [XiaomiVoiceRemoteButton.left, .right])
    func monitoredLeftAndRightUseNativeAutorepeatWhenTheirActionsMatch(
        _ simulatedButton: XiaomiVoiceRemoteButton
    ) throws {
        let button = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        let action: ButtonAction = button == .left ? .arrowLeft : .arrowRight
        let result = try driveHIDScenario(
            XiaomiVoiceRemoteFixture.hidRepeatScenario(button: simulatedButton),
            isSeized: false
        ) { settings in
            settings.setAction(action, for: button, trigger: .singleClick)
            settings.setAction(.disabled, for: button, trigger: .doubleClick)
            settings.setAction(.disabled, for: button, trigger: .longPress)
        }
        let keyCode: CGKeyCode = button == .left ? 123 : 124
        let nativeKeyDown = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ))

        #expect(result.events.isEmpty)
        #expect(!result.eventSuppressor.handle(type: .keyDown, event: nativeKeyDown))
        #expect(result.scheduler.pendingTaskCount == 0)
    }

    @Test(arguments: [XiaomiVoiceRemoteButton.left, .right])
    func monitoredDirectionsKeepCustomRepeatWithoutLeavingNativeKeysSuppressed(
        _ simulatedButton: XiaomiVoiceRemoteButton
    ) throws {
        let button = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        let result = try driveHIDScenario(
            XiaomiVoiceRemoteFixture.hidRepeatScenario(button: simulatedButton),
            isSeized: false
        ) { settings in
            settings.setAction(.volumeDown, for: button, trigger: .singleClick)
            settings.setAction(.disabled, for: button, trigger: .doubleClick)
            settings.setAction(.disabled, for: button, trigger: .longPress)
        }
        let keyCode: CGKeyCode = button == .left ? 123 : 124
        let nativeKeyDown = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ))

        #expect(result.events.count == 6)
        #expect(result.events.allSatisfy { $0.action == .volumeDown })
        #expect(!result.eventSuppressor.handle(type: .keyDown, event: nativeKeyDown))
        #expect(result.scheduler.pendingTaskCount == 0)
    }

    @Test func monitoredLeftStillUsesAppPolicyWhenRemoteMicIsFrontmost() throws {
        let result = try driveHIDScenario(
            XiaomiVoiceRemoteFixture.hidRepeatScenario(button: .left),
            isSeized: false,
            frontmostBundleIdentifier: PresetApplication.remoteMic.bundleIdentifier
        ) { settings in
            settings.setAction(.arrowLeft, for: .left, trigger: .singleClick)
            settings.setAction(.disabled, for: .left, trigger: .doubleClick)
            settings.setAction(.disabled, for: .left, trigger: .longPress)
        }

        #expect(result.events == [
            HIDPerformedAction(button: .left, trigger: .singleClick, action: .arrowLeft)
        ])
        #expect(result.scheduler.pendingTaskCount == 0)
    }

    @Test func malformedReportsAreIgnoredAndDisconnectCancelsPendingGestures() throws {
        for scenario in XiaomiVoiceRemoteFixture.hidMalformedReportScenarios() {
            let result = try driveHIDScenario(scenario) { _ in }
            #expect(result.events.isEmpty)
        }

        let button = XiaomiVoiceRemoteButton.ok
        var scenario = XiaomiVoiceRemoteFixture.hidButtonScenario(
            button: button,
            gesture: .singleClick
        )
        scenario = HardwareScenario(
            id: scenario.id + ".disconnect-before-timeout",
            seed: scenario.seed,
            devices: scenario.devices,
            timeline: scenario.timeline.filter {
                $0.kind != XiaomiVoiceRemoteSignalKind.hidRemoved
            } + [
                .init(
                    atMilliseconds: 100,
                    deviceID: XiaomiVoiceRemoteFixture.deviceID,
                    transport: XiaomiVoiceRemoteTransport.hid,
                    kind: XiaomiVoiceRemoteSignalKind.hidRemoved,
                    payload: .object([:])
                )
            ],
            durationMilliseconds: 500
        )
        let result = try driveHIDScenario(scenario) { settings in
            settings.setAction(.escape, for: .ok, trigger: .singleClick)
            settings.setAction(.appSwitcher, for: .ok, trigger: .doubleClick)
        }
        #expect(result.events.isEmpty)
        #expect(result.scheduler.pendingTaskCount == 0)
    }

    @Test func duplicateAndCombinedHIDReportsDoNotInventExtraPresses() throws {
        let suiteName = "HardwareSimulationIntegrationTests.combined.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.escape, for: .ok)
        settings.setAction(.appSwitcher, for: .tv)
        let profileID = try #require(settings.selectedRemoteProfileID)
        let scheduler = TestHIDRemoteScheduler()
        let recorder = HIDActionRecorder()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { button, trigger, configured in
                recorder.events.append(.init(
                    button: button,
                    trigger: trigger,
                    action: configured.action
                ))
                return true
            },
            frontmostBundleIdentifier: { PresetApplication.codex.bundleIdentifier }
        )
        monitor.connectSimulatedDevice(fingerprint: "combined", profileID: profileID)
        let combined = Data([0x28, 0, 0x35, 0, 0, 0])
        monitor.handleSimulatedReport(reportID: 1, data: combined)
        monitor.handleSimulatedReport(reportID: 1, data: combined)
        monitor.handleSimulatedReport(reportID: 1, data: Data([0x35, 0, 0, 0, 0, 0]))
        monitor.handleSimulatedReport(reportID: 1, data: Data([0, 0, 0, 0, 0, 0]))
        monitor.disconnectSimulatedDevice()

        #expect(recorder.events == [
            .init(button: .ok, trigger: .singleClick, action: .escape),
            .init(button: .tv, trigger: .singleClick, action: .appSwitcher),
        ])
        #expect(scheduler.pendingTaskCount == 0)
    }

    @Test func HIDDiagnosticsTraceReportsEdgesGesturesAndActionsWithoutRawPayloads() throws {
        let suiteName = "HardwareSimulationIntegrationTests.hidDiagnostics.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.returnKey, for: .ok)
        let profileID = try #require(settings.selectedRemoteProfileID)
        var diagnostics: [String] = []
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            ownsEventSuppressor: false,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            diagnosticLogger: { diagnostics.append($0) }
        )
        monitor.connectSimulatedDevice(fingerprint: "diagnostic", profileID: profileID)
        monitor.handleSimulatedReport(
            reportID: 1,
            data: Data([0x28, 0, 0, 0, 0, 0])
        )
        monitor.handleSimulatedReport(
            reportID: 1,
            data: Data([0, 0, 0, 0, 0, 0])
        )

        #expect(diagnostics.contains { $0.contains("HID REPORT accepted source=simulated") })
        #expect(diagnostics.contains { $0.contains("HID EDGE pressed=ok") })
        #expect(diagnostics.contains { $0.contains("HID GESTURE button=ok") })
        #expect(!diagnostics.contains { $0.contains("0x28") || $0.contains("diagnostic") })
    }

    @Test func privateMacroBindingCanOwnDisabledDoubleClickWithoutStoppingHID() throws {
        let suiteName = "HardwareSimulationIntegrationTests.privateMacro.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.disabled, for: .menu, trigger: .doubleClick)
        let profileID = try #require(settings.selectedRemoteProfileID)
        let scheduler = TestHIDRemoteScheduler()
        var privateEvents: [(RemoteButton, ButtonTrigger)] = []
        var publicActionCount = 0
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in
                publicActionCount += 1
                return true
            },
            overrideActionPerformer: { _, button, trigger in
                privateEvents.append((button, trigger))
                return true
            },
            hasOverrideBinding: { _, button, trigger in
                button == .menu && trigger == .doubleClick
            },
            frontmostBundleIdentifier: { PresetApplication.codex.bundleIdentifier }
        )
        monitor.connectSimulatedDevice(fingerprint: "private-macro", profileID: profileID)
        let report = XiaomiVoiceRemoteButton.menu.report
        let release = Data(repeating: 0, count: report.data.count)

        monitor.handleSimulatedReport(reportID: report.reportID, data: report.data)
        monitor.handleSimulatedReport(reportID: report.reportID, data: release)
        scheduler.advance(toMilliseconds: 100)
        monitor.handleSimulatedReport(reportID: report.reportID, data: report.data)
        monitor.handleSimulatedReport(reportID: report.reportID, data: release)
        scheduler.advance(toMilliseconds: 700)

        #expect(privateEvents.count == 1)
        #expect(privateEvents.first?.0 == .menu)
        #expect(privateEvents.first?.1 == .doubleClick)
        #expect(publicActionCount == 0)
        #expect(monitor.status != LocalizedMessage("button_mapping.permission.accessibility_expired"))
    }

    @Test(arguments: XiaomiVoiceRemoteButton.allCases.filter { $0 != .back })
    func monitoredNativeButtonsReleaseSuppressionAfterReleaseAndDisconnect(
        _ simulatedButton: XiaomiVoiceRemoteButton
    ) throws {
        let button = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        let suiteName = "HardwareSimulationIntegrationTests.nativeRelease.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.volumeDown, for: button)
        let profileID = try #require(settings.selectedRemoteProfileID)
        let scheduler = TestHIDRemoteScheduler()
        let suppressor = KeyboardEventSuppressor()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            eventSuppressor: suppressor,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            frontmostBundleIdentifier: { PresetApplication.codex.bundleIdentifier }
        )
        let down = try nativeEvent(for: button, edge: .down)
        let up = try nativeEvent(for: button, edge: .up)
        let press = simulatedButton.report
        let release = Data(repeating: 0, count: press.data.count)

        monitor.connectSimulatedDevice(
            fingerprint: "monitored-repeat",
            profileID: profileID,
            isSeized: false
        )
        monitor.handleSimulatedReport(reportID: press.reportID, data: press.data)
        scheduler.advance(toMilliseconds: 650)
        #expect(suppressor.handle(type: down.type, event: down.event))
        monitor.handleSimulatedReport(reportID: press.reportID, data: release)
        #expect(suppressor.handle(type: up.type, event: up.event))
        #expect(!suppressor.handle(type: down.type, event: down.event))

        monitor.handleSimulatedReport(reportID: press.reportID, data: press.data)
        monitor.disconnectSimulatedDevice()
        #expect(suppressor.handle(type: up.type, event: up.event))
        #expect(!suppressor.handle(type: down.type, event: down.event))
    }

    @Test(arguments: XiaomiVoiceRemoteButton.allCases.filter { $0 != .back })
    func twoMonitoredRemotesReleaseOnlyTheirOwnNativeSuppression(
        _ simulatedButton: XiaomiVoiceRemoteButton
    ) throws {
        let button = try #require(RemoteButton(rawValue: simulatedButton.rawValue))
        let suiteName = "HardwareSimulationIntegrationTests.sharedNativeRelease.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.volumeDown, for: button)
        let profileID = try #require(settings.selectedRemoteProfileID)
        let scheduler = TestHIDRemoteScheduler()
        let suppressor = KeyboardEventSuppressor()
        let down = try nativeEvent(for: button, edge: .down)
        let press = simulatedButton.report

        let firstMonitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            eventSuppressor: suppressor,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            frontmostBundleIdentifier: { PresetApplication.codex.bundleIdentifier }
        )
        let secondMonitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            eventSuppressor: suppressor,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            frontmostBundleIdentifier: { PresetApplication.codex.bundleIdentifier }
        )

        firstMonitor.connectSimulatedDevice(
            fingerprint: "monitored-a",
            profileID: profileID,
            isSeized: false
        )
        secondMonitor.connectSimulatedDevice(
            fingerprint: "monitored-b",
            profileID: profileID,
            isSeized: false
        )
        firstMonitor.handleSimulatedReport(reportID: press.reportID, data: press.data)
        secondMonitor.handleSimulatedReport(reportID: press.reportID, data: press.data)
        firstMonitor.disconnectSimulatedDevice()
        #expect(suppressor.handle(type: down.type, event: down.event))
        secondMonitor.disconnectSimulatedDevice()
        #expect(!suppressor.handle(type: down.type, event: down.event))
    }

    @Test func monitoredBackButtonNeverArmsNativeKeyboardSuppression() throws {
        let suiteName = "HardwareSimulationIntegrationTests.backHasNoNativeEvent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        settings.setAction(.deleteBackward, for: .back)
        let profileID = try #require(settings.selectedRemoteProfileID)
        let scheduler = TestHIDRemoteScheduler()
        let suppressor = KeyboardEventSuppressor()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            eventSuppressor: suppressor,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { _, _, _ in true },
            frontmostBundleIdentifier: { PresetApplication.codex.bundleIdentifier }
        )
        let deleteDown = try #require(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 51,
            keyDown: true
        ))
        let press = XiaomiVoiceRemoteButton.back.report

        #expect(RemoteButton.back.nativeEvent == nil)
        monitor.connectSimulatedDevice(
            fingerprint: "monitored-back",
            profileID: profileID,
            isSeized: false
        )
        monitor.handleSimulatedReport(reportID: press.reportID, data: press.data)
        scheduler.advance(toMilliseconds: 650)
        #expect(!suppressor.handle(type: .keyDown, event: deleteDown))
        monitor.disconnectSimulatedDevice()
        #expect(!suppressor.handle(type: .keyDown, event: deleteDown))
    }

    @Test func simulatedMultiFrameRemainderDrivesProductionAccumulator() throws {
        let scenario = XiaomiVoiceRemoteFixture.bleScenario(.multipleFramesWithRemainder)
        let runner = try HardwareScenarioRunner(
            scenario: scenario,
            catalog: HardwareCatalog(profiles: [XiaomiVoiceRemoteFixture.profile()])
        )
        var accumulator = FrameAccumulator()
        var frameCount = 0
        runner.runToScenarioEnd { signal in
            guard let value = BLEGATTValue(signal: signal),
                  value.characteristicUUID == XiaomiVoiceRemoteFixture.audioUUID
            else { return }
            frameCount += accumulator.append(value.value, frameSize: 120).count
        }
        #expect(frameCount == 3)
        #expect(accumulator.pending.isEmpty)
    }

    @Test func simulatedSyncPacketResetsTheProductionDecoderBeforeTheNextFrame() throws {
        let scenario = XiaomiVoiceRemoteFixture.bleScenario(.syncReset)
        let runner = try HardwareScenarioRunner(
            scenario: scenario,
            catalog: HardwareCatalog(profiles: [XiaomiVoiceRemoteFixture.profile()])
        )
        var accumulator = FrameAccumulator()
        let decoder = IMAADPCMDecoder()
        var pendingSync: (predictor: Int, stepIndex: Int)?
        var firstSample: Int16?
        runner.runToScenarioEnd { signal in
            guard let value = BLEGATTValue(signal: signal) else { return }
            if value.characteristicUUID == XiaomiVoiceRemoteFixture.controlUUID,
               value.value.first == 0x0A,
               value.value.count >= 7 {
                let predictorBits = UInt16(value.value[4]) << 8 | UInt16(value.value[5])
                pendingSync = (Int(Int16(bitPattern: predictorBits)), Int(value.value[6]))
                accumulator.reset()
            } else if value.characteristicUUID == XiaomiVoiceRemoteFixture.audioUUID {
                for frame in accumulator.append(value.value, frameSize: 120) {
                    if let sync = pendingSync {
                        decoder.reset(
                            predictor: sync.predictor,
                            stepIndex: sync.stepIndex
                        )
                        pendingSync = nil
                    }
                    firstSample = decoder.decode(frame).first
                }
            }
        }
        let synchronizedSample = try #require(firstSample)
        #expect(synchronizedSample > 1_000)
        #expect(pendingSync == nil)
    }

    @Test func unsupportedAndMalformedCapabilitiesFailTheProductionAudioGate() throws {
        let unsupported = try firstControlValue(in: .unsupportedSampleRate)
        let capabilities = try #require(ATVVCapabilities.parse(unsupported))
        #expect(capabilities.sampleRate == 8_000)
        #expect(!ATVVProtocol.supportsAudio(sampleRate: capabilities.sampleRate))

        let malformed = try firstControlValue(in: .malformedCapabilities)
        #expect(ATVVCapabilities.parse(malformed) == nil)
    }

    @Test func reconnectStaleCallbackAndTwoDevicesPreserveProductionGenerationIsolation() throws {
        let staleScenario = XiaomiVoiceRemoteFixture.bleScenario(.staleCallback)
        let staleRunner = try HardwareScenarioRunner(
            scenario: staleScenario,
            catalog: HardwareCatalog(profiles: [XiaomiVoiceRemoteFixture.profile()])
        )
        var staleGeneration: UInt64?
        staleRunner.runToScenarioEnd { signal in
            if signal.kind == XiaomiVoiceRemoteSignalKind.characteristicValue,
               let generation = signal.payload["generation"]?.integerValue {
                staleGeneration = UInt64(generation)
            }
        }
        #expect(staleGeneration == 1)
        #expect(!BluetoothLifecyclePhase.ready(2).acceptsProtocolData(generation: 1))
        #expect(BluetoothLifecyclePhase.ready(2).acceptsProtocolData(generation: 2))

        let twoDevices = XiaomiVoiceRemoteFixture.bleScenario(.twoDevices)
        let runner = try HardwareScenarioRunner(
            scenario: twoDevices,
            catalog: HardwareCatalog(profiles: [XiaomiVoiceRemoteFixture.profile()])
        )
        var sessions: [String: UInt8] = [:]
        runner.runToScenarioEnd { signal in
            guard let value = BLEGATTValue(signal: signal),
                  value.characteristicUUID == XiaomiVoiceRemoteFixture.controlUUID,
                  value.value.first == 0x04,
                  value.value.count >= 4
            else { return }
            sessions[signal.deviceID] = value.value[3]
        }
        #expect(sessions == [
            "xiaomi-voice-remote-1": 1,
            "xiaomi-voice-remote-2": 2,
        ])
    }

    private func firstControlValue(
        in kind: XiaomiVoiceRemoteBLEScenario
    ) throws -> Data {
        let runner = try HardwareScenarioRunner(
            scenario: XiaomiVoiceRemoteFixture.bleScenario(kind),
            catalog: HardwareCatalog(profiles: [XiaomiVoiceRemoteFixture.profile()])
        )
        while let signal = runner.nextSignal() {
            if let value = BLEGATTValue(signal: signal),
               value.characteristicUUID == XiaomiVoiceRemoteFixture.controlUUID {
                return value.value
            }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func nativeEvent(
        for button: RemoteButton,
        edge: RemoteEventEdge
    ) throws -> (type: CGEventType, event: CGEvent) {
        switch try #require(button.nativeEvent) {
        case let .keyboard(keyCode):
            let isDown = edge == .down
            let event = try #require(CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: isDown
            ))
            return (isDown ? .keyDown : .keyUp, event)
        case let .systemKey(systemKeyType):
            let keyState: Int32 = edge == .down ? 0xA : 0xB
            let data1 = Int((systemKeyType << 16) | (keyState << 8))
            let event = try #require(NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent)
            return (try #require(CGEventType(rawValue: 14)), event)
        }
    }

    private func driveHIDScenario(
        _ scenario: HardwareScenario,
        isSeized: Bool = true,
        frontmostBundleIdentifier: String = PresetApplication.codex.bundleIdentifier,
        configure: (AppSettings) -> Void
    ) throws -> HIDScenarioResult {
        let suiteName = "HardwareSimulationIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        configure(settings)
        let profileID = try #require(settings.selectedRemoteProfileID)
        let scheduler = TestHIDRemoteScheduler()
        let recorder = HIDActionRecorder()
        let eventSuppressor = KeyboardEventSuppressor()
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            eventSuppressor: eventSuppressor,
            ownsEventSuppressor: false,
            scheduler: scheduler,
            runtimePermissions: { true },
            actionPerformer: { button, trigger, configured in
                recorder.events.append(HIDPerformedAction(
                    button: button,
                    trigger: trigger,
                    action: configured.action
                ))
                return true
            },
            frontmostBundleIdentifier: { frontmostBundleIdentifier }
        )
        monitor.connectSimulatedDevice(
            fingerprint: "fixture-device-1",
            profileID: profileID,
            isSeized: isSeized
        )

        let runner = try HardwareScenarioRunner(
            scenario: scenario,
            catalog: HardwareCatalog(profiles: [XiaomiVoiceRemoteFixture.profile()])
        )
        while let signal = runner.nextSignal() {
            scheduler.advance(toMilliseconds: signal.atMilliseconds)
            if let report = HIDInputReport(signal: signal) {
                monitor.handleSimulatedReport(reportID: report.reportID, data: report.data)
            } else if signal.kind == XiaomiVoiceRemoteSignalKind.hidRemoved {
                monitor.disconnectSimulatedDevice()
            }
        }
        scheduler.advance(toMilliseconds: scenario.durationMilliseconds ?? runner.currentTimeMilliseconds)
        return HIDScenarioResult(
            events: recorder.events,
            scheduler: scheduler,
            eventSuppressor: eventSuppressor
        )
    }
}

private struct HIDPerformedAction: Equatable {
    let button: RemoteButton
    let trigger: ButtonTrigger
    let action: ButtonAction
}

private struct HIDScenarioResult {
    let events: [HIDPerformedAction]
    let scheduler: TestHIDRemoteScheduler
    let eventSuppressor: KeyboardEventSuppressor
}

private final class HIDActionRecorder {
    var events: [HIDPerformedAction] = []
}

private final class TestHIDRemoteScheduler: HIDRemoteScheduling {
    private final class Task: HIDRemoteScheduledTask {
        var deadlineMilliseconds: UInt64
        let repeatingEveryMilliseconds: UInt64?
        let order: UInt64
        let action: () -> Void
        var isCancelled = false

        init(
            deadlineMilliseconds: UInt64,
            repeatingEveryMilliseconds: UInt64?,
            order: UInt64,
            action: @escaping () -> Void
        ) {
            self.deadlineMilliseconds = deadlineMilliseconds
            self.repeatingEveryMilliseconds = repeatingEveryMilliseconds
            self.order = order
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private var currentTimeMilliseconds: UInt64 = 0
    private var nextOrder: UInt64 = 0
    private var tasks: [Task] = []

    var pendingTaskCount: Int {
        tasks.lazy.filter { !$0.isCancelled }.count
    }

    func schedule(
        afterMilliseconds: UInt64,
        repeatingEveryMilliseconds: UInt64?,
        _ action: @escaping () -> Void
    ) -> HIDRemoteScheduledTask {
        let task = Task(
            deadlineMilliseconds: currentTimeMilliseconds + afterMilliseconds,
            repeatingEveryMilliseconds: repeatingEveryMilliseconds,
            order: nextOrder,
            action: action
        )
        nextOrder += 1
        tasks.append(task)
        return task
    }

    func advance(toMilliseconds target: UInt64) {
        precondition(target >= currentTimeMilliseconds)
        while let task = tasks
            .filter({ !$0.isCancelled && $0.deadlineMilliseconds <= target })
            .min(by: {
                ($0.deadlineMilliseconds, $0.order) < ($1.deadlineMilliseconds, $1.order)
            }) {
            currentTimeMilliseconds = task.deadlineMilliseconds
            if task.repeatingEveryMilliseconds == nil {
                task.isCancelled = true
            }
            task.action()
            if !task.isCancelled, let interval = task.repeatingEveryMilliseconds {
                task.deadlineMilliseconds += interval
            }
        }
        currentTimeMilliseconds = target
        tasks.removeAll(where: \.isCancelled)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
#endif
