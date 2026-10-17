import AppKit
import Combine
import Foundation
import SayAllMacRemoteCore
import Testing
@testable import RemoteMic

@Suite("Status item connection appearance")
struct StatusItemPresentationTests {
    private final class ConnectionFixture {
        @Published var physical = false
        @Published var phone = false
        @Published var watch = false
        @Published var web: WebRemoteSessionState = .disabled
        @Published var streaming = false
        @Published var warning: VoiceSessionWarningLevel = .none

        var presentation: AnyPublisher<StatusItemPresentation, Never> {
            StatusItemPresentation.publisher(
                physicalConnected: $physical.eraseToAnyPublisher(),
                phoneConnected: $phone.eraseToAnyPublisher(),
                watchConnected: $watch.eraseToAnyPublisher(),
                webState: $web.eraseToAnyPublisher(),
                isStreaming: $streaming.eraseToAnyPublisher(),
                voiceWarningLevel: $warning.eraseToAnyPublisher()
            )
        }

        func setConnected(_ connected: Bool, source: Int) {
            switch source {
            case 0: physical = connected
            case 1: phone = connected
            case 2: watch = connected
            default: web = connected ? .connected(deviceName: "Test device") : .disabled
            }
        }
    }

    @Test(arguments: 0..<4)
    func eachSourceRefreshesWithoutOpeningTheMenu(source: Int) {
        let fixture = ConnectionFixture()
        var observed: [StatusItemPresentation] = []
        let subscription = fixture.presentation.sink { observed.append($0) }
        defer { subscription.cancel() }

        fixture.setConnected(true, source: source)
        fixture.setConnected(false, source: source)
        fixture.setConnected(true, source: source)
        #expect(observed == [.disconnected, .connected, .disconnected, .connected])
    }

    @Test func publishedSnapshotDoesNotReadThePreviousModelValue() {
        let fixture = ConnectionFixture()
        var connectedWasPublishedBeforeStorageChanged = false
        let subscription = fixture.presentation.sink { state in
            if state == .connected {
                connectedWasPublishedBeforeStorageChanged = !fixture.phone
            }
        }
        defer { subscription.cancel() }
        fixture.phone = true
        #expect(connectedWasPublishedBeforeStorageChanged)
    }

    @Test func onlyAuthorizedWebConnectionCountsAndAssociatedDataDoesNotRefresh() {
        let fixture = ConnectionFixture()
        var observed: [StatusItemPresentation] = []
        let subscription = fixture.presentation.sink { observed.append($0) }
        defer { subscription.cancel() }
        let url = URL(string: "https://example.invalid/join")!
        let disconnectedStates: [WebRemoteSessionState] = [
            .disabled, .unavailable, .connecting,
            .waitingForPhone(joinURL: url, pairingCode: "00", expiresAt: nil),
            .awaitingApproval(joinURL: url, pairingCode: "00", deviceName: "Test device"),
            .failed("Test failure"),
        ]
        for state in disconnectedStates { fixture.web = state }
        #expect(observed == [.disconnected])
        fixture.web = .connected(deviceName: "Test device")
        fixture.web = .connected(deviceName: "Other test device")
        #expect(observed == [.disconnected, .connected])
        for state in disconnectedStates {
            fixture.web = state
            #expect(observed.last == .disconnected)
            fixture.web = .connected(deviceName: "Test device")
        }
        #expect(observed.count == 2 + disconnectedStates.count * 2)
    }

    @Test func partialDisconnectStaysConnectedUntilTheLastSourceLeaves() {
        let fixture = ConnectionFixture()
        var observed: [StatusItemPresentation] = []
        let subscription = fixture.presentation.sink { observed.append($0) }
        defer { subscription.cancel() }
        for source in 0..<4 { fixture.setConnected(true, source: source) }
        for source in 0..<3 { fixture.setConnected(false, source: source) }
        #expect(observed == [.disconnected, .connected])
        fixture.setConnected(false, source: 3)
        fixture.setConnected(false, source: 3)
        #expect(observed == [.disconnected, .connected, .disconnected])
    }

    @Test func streamingWinsDuringDisconnectAndRestoresCurrentConnectionState() {
        let fixture = ConnectionFixture()
        var observed: [StatusItemPresentation] = []
        let subscription = fixture.presentation.sink { observed.append($0) }
        defer { subscription.cancel() }
        fixture.physical = true
        fixture.streaming = true
        fixture.physical = false
        #expect(observed == [.disconnected, .connected, .streaming])
        fixture.streaming = false
        fixture.streaming = true
        fixture.phone = true
        fixture.streaming = false
        #expect(observed == [
            .disconnected, .connected, .streaming, .disconnected, .streaming, .connected,
        ])
    }

    @Test func subscriptionStartsWithExistingConnectionAndStreamingState() {
        let fixture = ConnectionFixture()
        fixture.watch = true
        var observed: [StatusItemPresentation] = []
        let first = fixture.presentation.sink { observed.append($0) }
        first.cancel()
        fixture.streaming = true
        let second = fixture.presentation.sink { observed.append($0) }
        second.cancel()
        #expect(observed == [.connected, .streaming])
    }

    @Test func warningLevelUsesOnlyRC001AndRC003Thresholds() {
        #expect(VoiceSessionWarningLevel.resolve(elapsed: 52.9, model: .rc001) == .none)
        #expect(VoiceSessionWarningLevel.resolve(elapsed: 53, model: .rc001) == .warning)
        #expect(VoiceSessionWarningLevel.resolve(elapsed: 56.9, model: .rc003) == .warning)
        #expect(VoiceSessionWarningLevel.resolve(elapsed: 57, model: .rc003) == .critical)
        #expect(VoiceSessionWarningLevel.resolve(elapsed: 90, model: .appleSiriRemoteA2854) == .none)
    }

    @Test func warningPresentationOnlyAppliesWhileStreaming() {
        let fixture = ConnectionFixture()
        var observed: [StatusItemPresentation] = []
        let subscription = fixture.presentation.sink { observed.append($0) }
        defer { subscription.cancel() }

        fixture.warning = .warning
        fixture.streaming = true
        fixture.warning = .critical
        fixture.streaming = false
        #expect(observed == [.disconnected, .streamingWarning, .streamingCritical, .disconnected])
    }

    @MainActor
    @Test func nativeDimmingPreservesActionsAndUpdatesAccessibleDescription() throws {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        let target = NSObject()
        let action = NSSelectorFromString("openSettings:")
        button.target = target
        button.action = action
        for state: StatusItemPresentation in [
            .disconnected, .connected, .streaming, .streamingWarning, .streamingCritical, .disconnected
        ] {
            state.apply(to: button, description: "SayAll: \(state.rawValue)")
            #expect(button.appearsDisabled == (state == .disconnected))
            #expect(button.isEnabled)
            #expect(button.target === target)
            #expect(button.action == action)
            #expect(button.alphaValue == 1)
            #expect(button.toolTip == "SayAll: \(state.rawValue)")
            #expect(button.accessibilityLabel() == button.toolTip)
            #expect(button.contentTintColor == nil)
            let image = try #require(button.image)
            if state == .streamingWarning || state == .streamingCritical {
                #expect(!image.isTemplate)
            } else {
                #expect(image.isTemplate)
            }
            #expect(image.size == NSSize(width: 18, height: 18))
        }
        StatusItemPresentation.disconnected.apply(to: button, description: "无线麦：未连接设备")
        #expect(button.toolTip == "无线麦：未连接设备")
        #expect(button.accessibilityLabel() == button.toolTip)
        #expect(button.appearsDisabled)
    }

    @Test func allStatesHaveBilingualProductDescriptions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["en", "zh-Hans"] {
            let data = try Data(contentsOf: root.appendingPathComponent(
                "Resources/\(language).lproj/Localizable.strings"
            ))
            let strings = try #require(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            )
            for state: StatusItemPresentation in [
                .disconnected, .connected, .streaming, .streamingWarning, .streamingCritical
            ] {
                let template = try #require(strings[state.descriptionKey])
                #expect(template.components(separatedBy: "%@").count == 2)
                #expect(!template.contains("Xiaomi"))
                #expect(!template.contains("小米"))
            }
        }
    }
}
