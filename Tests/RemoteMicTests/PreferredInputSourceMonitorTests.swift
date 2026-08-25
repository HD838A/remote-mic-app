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

        #expect(source.contains("let permissionSnapshot = HIDPermissionSnapshot.current"))
        #expect(source.contains("if started, permissionSnapshot.inputMonitoringGranted"))
        #expect(source.contains("preferredInputSourceMonitor.start()"))
        #expect(source.contains("preferredInputSourceMonitor.stop()"))

        let switcherSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/PreferredInputSourceMonitor.swift"),
            encoding: .utf8
        )
        #expect(switcherSource.contains(
            "OnboardingInputSourceSwitcher.prepareForVoiceSession"
        ))
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
            currentInputSourceID: { nil },
            restoreInputSource: { _ in .selected },
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
        #expect(logs.filter { $0.contains("source_prepare") }.count == 2)
        #expect(logs.filter { $0.contains("function_key edge=down") }.count == 2)
        #expect(logs.filter { $0.contains("function_key edge=up") }.count == 1)
        #expect(monitor.functionKeyIsPressedForDiagnostics)
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
            currentInputSourceID: { nil },
            restoreInputSource: { _ in .selected },
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
            currentInputSourceID: { nil },
            restoreInputSource: { _ in .selected },
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

    @Test func restoresTheInputSourceOwnedByTheVoiceSession() {
        var handler: ((Bool) -> Void)?
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoredInputSourceIDs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin },
            prepareInputSource: { _ in
                currentInputSourceID = "com.tencent.inputmethod.wetype.pinyin"
                return .selected
            },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                currentInputSourceID = sourceID
                return .selected
            },
            installMonitor: { callback in
                handler = callback
                return "monitor"
            },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.start()
        handler?(true)
        handler?(false)

        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
        #expect(currentInputSourceID == "com.apple.keylayout.ABC")
    }

    @Test func doesNotOverrideAnInputSourceChosenDuringVoiceSession() {
        var handler: ((Bool) -> Void)?
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoreCount = 0
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                currentInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { _ in
                restoreCount += 1
                return .selected
            },
            installMonitor: { callback in
                handler = callback
                return "monitor"
            },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.start()
        handler?(true)
        currentInputSourceID = "com.apple.keylayout.US"
        handler?(false)

        #expect(restoreCount == 0)
        #expect(currentInputSourceID == "com.apple.keylayout.US")
    }

    @Test func restoresWhenTheMonitorStopsWhileVoiceInputIsPressed() {
        var handler: ((Bool) -> Void)?
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoreCount = 0
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin },
            prepareInputSource: { _ in
                currentInputSourceID = "com.tencent.inputmethod.wetype.pinyin"
                return .selected
            },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoreCount += 1
                currentInputSourceID = sourceID
                return .selected
            },
            installMonitor: { callback in
                handler = callback
                return "monitor"
            },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.start()
        handler?(true)
        monitor.stop()

        #expect(restoreCount == 1)
        #expect(currentInputSourceID == "com.apple.keylayout.ABC")
    }

    @Test func overlappingFunctionKeyAndExplicitVoiceRestoreOnlyAfterLastOwnerEnds() {
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var preparationCount = 0
        var restoredInputSourceIDs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin },
            prepareInputSource: { _ in
                preparationCount += 1
                currentInputSourceID = "com.tencent.inputmethod.wetype.pinyin"
                return .selected
            },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                currentInputSourceID = sourceID
                return .selected
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.handleFunctionKeyPressed(true)
        monitor.beginVoiceSession()
        monitor.handleFunctionKeyPressed(false)

        #expect(preparationCount == 1)
        #expect(restoredInputSourceIDs.isEmpty)
        #expect(currentInputSourceID == "com.tencent.inputmethod.wetype.pinyin")

        monitor.endVoiceSession()

        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
        #expect(currentInputSourceID == "com.apple.keylayout.ABC")
    }

    @Test func overlappingExplicitVoiceAndFunctionKeyRestoreOnlyAfterLastOwnerEnds() {
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var preparationCount = 0
        var restoredInputSourceIDs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                preparationCount += 1
                currentInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                currentInputSourceID = sourceID
                return .selected
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.beginVoiceSession()
        monitor.handleFunctionKeyPressed(true)
        monitor.endVoiceSession()

        #expect(preparationCount == 1)
        #expect(restoredInputSourceIDs.isEmpty)
        #expect(currentInputSourceID == "com.bytedance.inputmethod.doubaoime.pinyin")

        monitor.handleFunctionKeyPressed(false)

        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
        #expect(currentInputSourceID == "com.apple.keylayout.ABC")
    }

    @Test func stopForcesOverlappingInputSourceOwnersToRestoreOnce() {
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoreCount = 0
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                currentInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoreCount += 1
                currentInputSourceID = sourceID
                return .selected
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.handleFunctionKeyPressed(true)
        monitor.beginVoiceSession()
        monitor.stop()
        monitor.endVoiceSession()

        #expect(restoreCount == 1)
        #expect(currentInputSourceID == "com.apple.keylayout.ABC")
    }

    @Test func stoppingFunctionMonitoringPreservesAnExplicitCommandVoiceSession() {
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoredInputSourceIDs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                currentInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                currentInputSourceID = sourceID
                return .selected
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.beginVoiceSession()
        monitor.handleFunctionKeyPressed(true)
        monitor.stop(preservingExplicitVoiceSession: true)

        #expect(restoredInputSourceIDs.isEmpty)
        #expect(currentInputSourceID == "com.bytedance.inputmethod.doubaoime.pinyin")
        #expect(!monitor.functionKeyIsPressedForDiagnostics)

        monitor.endVoiceSession()

        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
        #expect(currentInputSourceID == "com.apple.keylayout.ABC")
    }

    @Test func doesNotPrepareAnAlreadySelectedInputSource() {
        var preparationCount = 0
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                preparationCount += 1
                return .failed
            },
            currentInputSourceID: {
                "com.bytedance.inputmethod.doubaoime.pinyin"
            },
            restoreInputSource: { _ in .selected },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        monitor.handleFunctionKeyPressed(true)
        monitor.handleFunctionKeyPressed(false)

        #expect(preparationCount == 0)
    }
}
