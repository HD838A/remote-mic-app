import Foundation
import Testing
@testable import RemoteMic

@Suite("Preferred input source monitor")
struct PreferredInputSourceMonitorTests {
    @Test func productionRuntimeStartsOnlyWithInputMonitoringAndStopsCleanly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("if started, HIDRemoteMonitor.isInputMonitoringGranted"))
        #expect(source.contains("preferredInputSourceMonitor.start()"))
        #expect(source.contains("preferredInputSourceMonitor.stop()"))
    }

    @Test func functionKeyDownPreparesTheRememberedInputMethodOncePerPress() {
        var handler: ((Bool) -> Void)?
        var preparedTools: [OnboardingVoiceTool] = []
        var logs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { tool in
                preparedTools.append(tool)
                return .selected
            },
            installMonitor: { callback in
                handler = callback
                return "monitor"
            },
            removeMonitor: { _ in },
            logger: { logs.append($0) }
        )

        monitor.start()
        handler?(true)
        handler?(true)
        handler?(false)
        handler?(true)

        #expect(preparedTools == [.doubao, .doubao])
        #expect(logs.count == 2)
    }

    @Test func toolsWithoutAnInputSourceKeepTheExistingFnBehavior() {
        var selectedTool = OnboardingVoiceTool.typeless
        var preparationCount = 0
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { selectedTool },
            prepareInputSource: { _ in
                preparationCount += 1
                return .selected
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.handleFunctionKeyPressed(true)
        monitor.handleFunctionKeyPressed(false)
        selectedTool = .other
        monitor.handleFunctionKeyPressed(true)

        #expect(preparationCount == 0)
    }

    @Test func stopRemovesTheMonitorAndClearsThePressedLatch() {
        var handler: ((Bool) -> Void)?
        var removedTokens: [String] = []
        var preparationCount = 0
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin },
            prepareInputSource: { _ in
                preparationCount += 1
                return .failed
            },
            installMonitor: { callback in
                handler = callback
                return "monitor"
            },
            removeMonitor: { token in
                removedTokens.append(token as! String)
            },
            logger: { _ in }
        )

        monitor.start()
        handler?(true)
        monitor.stop()
        monitor.handleFunctionKeyPressed(true)

        #expect(removedTokens == ["monitor"])
        #expect(preparationCount == 2)
    }
}
