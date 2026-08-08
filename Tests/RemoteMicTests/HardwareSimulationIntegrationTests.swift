#if canImport(HardwareSimulation) && canImport(XiaomiVoiceRemoteSimulation)
import Foundation
import HardwareSimulation
import Testing
import XiaomiVoiceRemoteSimulation
@testable import RemoteMic

@Suite("Hardware simulation integration")
struct HardwareSimulationIntegrationTests {
    @Test func simulatedDirectStreamDrivesProductionATVVDecoder() throws {
        let profile = try XiaomiVoiceRemoteFixture.profile()
        let catalog = try HardwareCatalog(profiles: [profile])
        let runner = try HardwareScenarioRunner(
            scenario: try XiaomiVoiceRemoteFixture.directStreamScenario(),
            catalog: catalog
        )

        var capabilities: ATVVCapabilities?
        var accumulator = FrameAccumulator()
        let decoder = IMAADPCMDecoder()
        var streaming = false
        var decodedSamples: [Int16] = []

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
                default:
                    break
                }
            } else if value.characteristicUUID == XiaomiVoiceRemoteFixture.audioUUID {
                let activeCapabilities = try #require(capabilities)
                #expect(streaming)
                for frame in accumulator.append(value.value, frameSize: activeCapabilities.frameSize) {
                    decodedSamples.append(contentsOf: PCMPostprocessor.process(
                        decoder.decode(frame),
                        gainDB: 0
                    ))
                }
            }
        }

        #expect(capabilities?.version == 0x0100)
        #expect(capabilities?.frameSize == 120)
        #expect(decodedSamples.count == 240)
        #expect(decodedSamples.prefix(3) == [1, 2, 3])
        #expect(!streaming)
        #expect(accumulator.pending.isEmpty)
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
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
#endif
