import Foundation
import Testing
@testable import RemoteMic

@Suite("Preferred input source monitor", .serialized)
struct PreferredInputSourceMonitorTests {
    @Test func productionRuntimeStartsOnlyWithInputMonitoringFnBindingAndStopsCleanly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )

        #expect(source.contains("let permissionSnapshot = HIDPermissionSnapshot.current"))
        #expect(source.contains("if started, permissionSnapshot.inputMonitoringGranted,"))
        #expect(source.contains(
            "settings.voiceKeyMode == .function {\n" +
                "            preferredInputSourceMonitor.start()"
        ))
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
        var inputSourceLookupCount = 0
        var logs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { tool in
                preparedTools.append(tool)
                return .selected
            },
            currentInputSourceID: {
                inputSourceLookupCount += 1
                return nil
            },
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
        #expect(inputSourceLookupCount == 2)
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

    @Test func cancellingExplicitVoiceDuringActivationStopsWaitingAndRestores() {
        var monitor: PreferredInputSourceMonitor!
        var logs: [String] = []
        var restoredInputSourceIDs: [String] = []
        monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { "com.apple.keylayout.ABC" },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                return .selected
            },
            waitForInputSourceActivation: { _, _, _ in
                monitor.endVoiceSession()
                return false
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { logs.append($0) }
        )

        #expect(!monitor.beginVoiceSession())
        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
        #expect(logs.contains { $0.contains("result=activation_cancelled") })
        #expect(!logs.contains { $0.contains("result=activation_timeout") })
    }

    @Test func stoppingDuringExplicitVoiceActivationCancelsThePendingSession() {
        var monitor: PreferredInputSourceMonitor!
        var logs: [String] = []
        var restoredInputSourceIDs: [String] = []
        monitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { "com.apple.keylayout.ABC" },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                return .selected
            },
            waitForInputSourceActivation: { _, _, _ in
                monitor.stop()
                return false
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { logs.append($0) }
        )

        monitor.start()
        #expect(!monitor.beginVoiceSession())
        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
        #expect(logs.contains { $0.contains("result=activation_cancelled") })
    }

    @Test func pendingCommandActivationKeepsAReentrantFunctionOwnerUntilFunctionUp() {
        var monitor: PreferredInputSourceMonitor!
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoredInputSourceIDs: [String] = []
        monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                currentInputSourceID = sourceID
                return .selected
            },
            waitForInputSourceActivation: { target, _, shouldContinue in
                monitor.handleFunctionKeyPressed(true)
                currentInputSourceID = target
                return shouldContinue()
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { _ in }
        )

        #expect(monitor.beginVoiceSession())
        monitor.endVoiceSession()
        #expect(restoredInputSourceIDs.isEmpty)

        monitor.handleFunctionKeyPressed(false)
        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
    }

    @Test func managedSessionRejectsADifferentVoiceToolOwner() {
        var selectedTool = OnboardingVoiceTool.doubao
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoredInputSourceIDs: [String] = []
        var logs: [String] = []
        var pendingRestores: [() -> Void] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { selectedTool },
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
            scheduleRestore: { _, work in pendingRestores.append(work) },
            logger: { logs.append($0) }
        )

        #expect(monitor.beginVoiceSession())
        selectedTool = .weixin
        monitor.handleFunctionKeyPressed(true)
        monitor.endVoiceSession()
        #expect(restoredInputSourceIDs.isEmpty)
        pendingRestores.forEach { $0() }

        #expect(restoredInputSourceIDs == ["com.apple.keylayout.ABC"])
        #expect(logs.contains { $0.contains("reason=target_changed") })
    }

    @Test func managedSessionRejectsAFunctionOwnerAfterTheUserChangesSource() {
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoredInputSourceIDs: [String] = []
        var logs: [String] = []
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
            logger: { logs.append($0) }
        )

        #expect(monitor.beginVoiceSession())
        currentInputSourceID = "com.apple.keylayout.US"
        monitor.handleFunctionKeyPressed(true)
        monitor.endVoiceSession()

        #expect(restoredInputSourceIDs.isEmpty)
        #expect(currentInputSourceID == "com.apple.keylayout.US")
        #expect(logs.contains { $0.contains("reason=source_changed") })
    }

    @Test func activationCancellationDoesNotOverrideAThirdInputSource() {
        var monitor: PreferredInputSourceMonitor!
        var currentInputSourceID: String? = "com.apple.keylayout.ABC"
        var restoredInputSourceIDs: [String] = []
        var logs: [String] = []
        monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { currentInputSourceID },
            restoreInputSource: { sourceID in
                restoredInputSourceIDs.append(sourceID)
                currentInputSourceID = sourceID
                return .selected
            },
            waitForInputSourceActivation: { _, _, _ in
                currentInputSourceID = "com.apple.keylayout.US"
                monitor.handleFunctionKeyPressed(true)
                monitor.endVoiceSession()
                return false
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { logs.append($0) }
        )

        #expect(!monitor.beginVoiceSession())
        #expect(restoredInputSourceIDs.isEmpty)
        #expect(currentInputSourceID == "com.apple.keylayout.US")
        #expect(logs.contains { $0.contains("reason=source_changed") })
    }

    /// 现场 2026-11-19：豆包在采集停止后 160–550 ms 才提交文字；SayAll 松键后 13 ms 就切回
    /// 原输入法时，豆包从未 `Inserting text`，识别结果停在组合态。恢复必须延迟。
    @Test func explicitVoiceEndDefersRestoreUntilTheVoiceToolCanCommit() {
        var current: String? = "com.sogou.inputmethod.pinyin"
        var restored: [String] = []
        var scheduled: [(TimeInterval, () -> Void)] = []
        var logs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                current = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { current },
            restoreInputSource: { restored.append($0); current = $0; return .selected },
            waitForInputSourceActivation: { _, _, _ in true },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            scheduleRestore: { delay, work in scheduled.append((delay, work)) },
            logger: { logs.append($0) }
        )

        #expect(monitor.beginVoiceSession())
        monitor.endVoiceSession()

        #expect(restored.isEmpty)
        #expect(current == "com.bytedance.inputmethod.doubaoime.pinyin")
        #expect(scheduled.count == 1)
        #expect(scheduled[0].0 == PreferredInputSourceMonitor.explicitRestoreDelay)
        #expect(PreferredInputSourceMonitor.explicitRestoreDelay >= 1.0)
        #expect(logs.contains { $0.contains("source_restore phase=deferred") })

        scheduled[0].1()
        #expect(restored == ["com.sogou.inputmethod.pinyin"])
        #expect(current == "com.sogou.inputmethod.pinyin")
        // 再触发同一个回调不会重复恢复。
        scheduled[0].1()
        #expect(restored.count == 1)
    }

    @Test func newVoiceSessionDuringDeferredRestoreKeepsTheVoiceInputSource() {
        var current: String? = "com.sogou.inputmethod.pinyin"
        var prepareCount = 0
        var restored: [String] = []
        var scheduled: [() -> Void] = []
        var logs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                prepareCount += 1
                current = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { current },
            restoreInputSource: { restored.append($0); current = $0; return .selected },
            waitForInputSourceActivation: { _, _, _ in true },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            scheduleRestore: { _, work in scheduled.append(work) },
            logger: { logs.append($0) }
        )

        #expect(monitor.beginVoiceSession())
        monitor.endVoiceSession()
        // 连续会话：等待期间再次按下，不再切走又切回。
        #expect(monitor.beginVoiceSession())
        #expect(prepareCount == 1)
        #expect(logs.contains { $0.contains("phase=cancelled reason=new_voice_session") })
        scheduled.forEach { $0() }
        #expect(restored.isEmpty)
        #expect(current == "com.bytedance.inputmethod.doubaoime.pinyin")

        monitor.endVoiceSession()
        scheduled.last?()
        // 最后一次会话结束后只恢复到最初的输入源一次。
        #expect(restored == ["com.sogou.inputmethod.pinyin"])
    }

    @Test func deferredRestoreDoesNotOverrideASourceChosenWhileWaiting() {
        var current: String? = "com.sogou.inputmethod.pinyin"
        var restored: [String] = []
        var scheduled: [() -> Void] = []
        var logs: [String] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                current = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { current },
            restoreInputSource: { restored.append($0); current = $0; return .selected },
            waitForInputSourceActivation: { _, _, _ in true },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            scheduleRestore: { _, work in scheduled.append(work) },
            logger: { logs.append($0) }
        )

        #expect(monitor.beginVoiceSession())
        monitor.endVoiceSession()
        current = "com.apple.keylayout.ABC"
        scheduled.forEach { $0() }

        #expect(restored.isEmpty)
        #expect(current == "com.apple.keylayout.ABC")
        #expect(logs.contains { $0.contains("source_restore skipped reason=user_changed") })
    }

    @Test func stopDuringDeferredRestoreRestoresImmediatelyOnce() {
        var current: String? = "com.sogou.inputmethod.pinyin"
        var restored: [String] = []
        var scheduled: [() -> Void] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                current = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { current },
            restoreInputSource: { restored.append($0); current = $0; return .selected },
            waitForInputSourceActivation: { _, _, _ in true },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            scheduleRestore: { _, work in scheduled.append(work) },
            logger: { _ in }
        )

        #expect(monitor.beginVoiceSession())
        monitor.endVoiceSession()
        // 保留显式会话的 stop（例如权限变化重新应用设置）不提前切走。
        monitor.stop(preservingExplicitVoiceSession: true)
        #expect(restored.isEmpty)
        // App 退出等完整 stop 立即恢复，之后到期的回调不再重复恢复。
        monitor.stop()
        #expect(restored == ["com.sogou.inputmethod.pinyin"])
        scheduled.forEach { $0() }
        #expect(restored.count == 1)
    }

    @Test func cancelledActivationStillRestoresImmediately() {
        var current: String? = "com.sogou.inputmethod.pinyin"
        var restored: [String] = []
        var scheduledCount = 0
        var monitor: PreferredInputSourceMonitor!
        monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { current },
            restoreInputSource: { restored.append($0); current = $0; return .selected },
            waitForInputSourceActivation: { _, _, _ in
                // 触发键尚未发出就取消：语音工具没有要提交的文字，直接恢复。
                monitor.endVoiceSession()
                return false
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            scheduleRestore: { _, _ in scheduledCount += 1 },
            logger: { _ in }
        )

        #expect(!monitor.beginVoiceSession())
        #expect(restored == ["com.sogou.inputmethod.pinyin"])
        #expect(scheduledCount == 0)
    }

    @Test func fnKeyReleaseKeepsImmediateRestore() {
        var handler: ((Bool) -> Void)?
        var current: String? = "com.sogou.inputmethod.pinyin"
        var restored: [String] = []
        var scheduledCount = 0
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                current = "com.bytedance.inputmethod.doubaoime.pinyin"
                return .selected
            },
            currentInputSourceID: { current },
            restoreInputSource: { restored.append($0); current = $0; return .selected },
            installMonitor: { callback in handler = callback; return "monitor" },
            removeMonitor: { _ in },
            scheduleRestore: { _, _ in scheduledCount += 1 },
            logger: { _ in }
        )

        monitor.start()
        handler?(true)
        handler?(false)

        // Fn 绑定路径保持原有即时恢复，不受本次修复影响。
        #expect(restored == ["com.sogou.inputmethod.pinyin"])
        #expect(scheduledCount == 0)
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
        var pendingRestores: [() -> Void] = []
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
            scheduleRestore: { _, work in pendingRestores.append(work) },
            logger: { _ in }
        )

        monitor.handleFunctionKeyPressed(true)
        monitor.beginVoiceSession()
        monitor.handleFunctionKeyPressed(false)

        #expect(preparationCount == 1)
        #expect(restoredInputSourceIDs.isEmpty)
        #expect(currentInputSourceID == "com.tencent.inputmethod.wetype.pinyin")

        monitor.endVoiceSession()
        // 显式 owner 最后结束时延迟恢复，给语音工具提交文字的时间。
        #expect(restoredInputSourceIDs.isEmpty)
        pendingRestores.forEach { $0() }

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
        var pendingRestores: [() -> Void] = []
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
            scheduleRestore: { _, work in pendingRestores.append(work) },
            logger: { _ in }
        )

        monitor.beginVoiceSession()
        monitor.handleFunctionKeyPressed(true)
        monitor.stop(preservingExplicitVoiceSession: true)

        #expect(restoredInputSourceIDs.isEmpty)
        #expect(currentInputSourceID == "com.bytedance.inputmethod.doubaoime.pinyin")
        #expect(!monitor.functionKeyIsPressedForDiagnostics)

        monitor.endVoiceSession()
        #expect(restoredInputSourceIDs.isEmpty)
        pendingRestores.forEach { $0() }

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

    @Test @MainActor func productionWaiterProcessesDelayedActivationAcrossConsecutiveSessions() {
        let state = ActivationState()
        defer { state.monitor.stop(); state.monitor = nil }
        var activationTimer: Timer?
        defer { activationTimer?.invalidate() }
        var pendingRestores: [() -> Void] = []
        state.monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                activationTimer = Timer(timeInterval: 0.04, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        // Physical Fn edges can arrive while the explicit owner is waiting.
                        state.monitor.handleFunctionKeyPressed(true)
                        state.monitor.handleFunctionKeyPressed(false)
                        state.current = state.target
                    }
                }
                RunLoop.main.add(activationTimer!, forMode: .common)
                return .selected
            },
            currentInputSourceID: { state.queries += 1; return state.current },
            restoreInputSource: {
                state.restored.append($0)
                state.current = $0
                return .selected
            },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            scheduleRestore: { _, work in pendingRestores.append(work) },
            logger: { _ in }
        )

        for _ in 0..<3 {
            state.queries = 0
            #expect(state.monitor.beginVoiceSession())
            #expect(state.current == state.target)
            // Check work, rather than CPU timing, so slower CI machines remain valid.
            #expect(state.queries < 100)
            #expect(!state.monitor.functionKeyIsPressedForDiagnostics)
            state.monitor.endVoiceSession()
            activationTimer?.invalidate()
            pendingRestores.forEach { $0() }
            pendingRestores.removeAll()
            #expect(state.current == state.original)
        }
        #expect(state.restored == Array(repeating: state.original, count: 3))
    }

    @Test(arguments: [false, true]) @MainActor
    func productionWaiterProcessesCancellationWhileActivationIsPending(stopMonitor: Bool) {
        let state = ActivationState()
        defer { state.monitor.stop(); state.monitor = nil }
        var didPrepare = false
        var didRequestCancellation = false
        state.monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in
                didPrepare = true
                return .selected
            },
            currentInputSourceID: {
                // 生产 waiter 在 prepare 之后、等待循环内读取当前输入源。
                // 在这里触发取消，避免测试依赖真实 timer 与 0.5 秒超时赛跑。
                if didPrepare, !didRequestCancellation {
                    didRequestCancellation = true
                    if stopMonitor { state.monitor.stop() } else { state.monitor.endVoiceSession() }
                }
                return state.original
            },
            restoreInputSource: { state.restored.append($0); return .selected },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { state.logs.append($0) }
        )
        state.monitor.start()

        #expect(!state.monitor.beginVoiceSession())
        #expect(state.restored == [state.original])
        #expect(state.logs.contains { $0.contains("result=activation_cancelled") })
        #expect(!state.logs.contains { $0.contains("result=activation_timeout") })
        state.monitor.endVoiceSession()
        #expect(state.restored.count == 1)
    }

    @Test @MainActor func productionWaiterTimesOutWithoutBusyPollingAndRestoresOnce() {
        var queries = 0
        var restores = 0
        var logs: [String] = []
        let timer = Timer(timeInterval: 2, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin },
            prepareInputSource: { _ in .selected },
            currentInputSourceID: { queries += 1; return "com.apple.keylayout.ABC" },
            restoreInputSource: { _ in restores += 1; return .selected },
            installMonitor: { _ in "monitor" },
            removeMonitor: { _ in },
            logger: { logs.append($0) }
        )

        let started = ProcessInfo.processInfo.systemUptime
        #expect(!monitor.beginVoiceSession())
        #expect(ProcessInfo.processInfo.systemUptime - started >= 0.5)
        #expect(queries < 100)
        #expect(logs.contains { $0.contains("result=activation_timeout") })
        monitor.endVoiceSession()
        #expect(restores == 1)
    }
}

@MainActor private final class ActivationState {
    let original = "com.apple.keylayout.ABC"
    let target = "com.bytedance.inputmethod.doubaoime.pinyin"
    var current = "com.apple.keylayout.ABC"
    var queries = 0
    var restored: [String] = []
    var logs: [String] = []
    var monitor: PreferredInputSourceMonitor!
}
