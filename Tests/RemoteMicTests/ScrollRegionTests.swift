import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Scroll region")
struct ScrollRegionTests {
    private func descriptor(
        role: String = "AXScrollArea",
        identifier: String = "",
        context: String = "",
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        window: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 700)
    ) -> ScrollRegionDescriptor {
        ScrollRegionDescriptor(
            role: role,
            identifier: identifier,
            context: context,
            frame: frame,
            windowFrame: window
        )
    }

    private func target(
        role: String = "AXScrollArea",
        identifier: String = "",
        windowTitle: String = "",
        context: String = "",
        frame: NormalizedAccessibilityFrame? = nil
    ) -> ScrollRegionTarget {
        ScrollRegionTarget(
            role: role,
            identifier: identifier,
            windowTitle: windowTitle,
            context: context,
            normalizedFrame: frame,
            source: .learned,
            strategy: .lineWheel
        )
    }

    @Test func queueAcknowledgementIsNotSuccess() {
        #expect(ScrollPageOutcome.queued.wasHandled)
        #expect(ScrollPageOutcome.queued.didScroll == false)
        #expect(ScrollPageOutcome.cancelled.wasHandled == false)
        #expect(ScrollPageOutcome.scrolledByPixelWheel.didScroll)
    }

    @Test func pageScrollUsesVisibleHeightAndSplitsLineChunks() {
        // 884 pt region: full page targets 0.9 × height, half page targets 0.5 × height.
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 884, step: .full) == 66)
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 884, step: .half) == 37)
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 10, step: .full) == 1)
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 0, step: .full) == 1)
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 100_000, step: .full) == ScrollRegionRule.maximumPageLines)

        // 29 lines = 20 + 9; 53 lines = 20 + 20 + 13.
        #expect(ScrollRegionRule.pageWheelChunks(totalLines: 29) == 2)
        #expect(ScrollRegionRule.pageWheelLines(totalLines: 29, index: 0) == 20)
        #expect(ScrollRegionRule.pageWheelLines(totalLines: 29, index: 1) == 9)
        #expect(ScrollRegionRule.pageWheelChunks(totalLines: 53) == 3)
        #expect(ScrollRegionRule.pageWheelLines(totalLines: 53, index: 2) == 13)
        #expect(ScrollRegionRule.pageWheelChunks(totalLines: 0) == 0)
        #expect(ScrollRegionRule.pageWheelLines(totalLines: 29, index: 2) == 0)
    }

    @Test func wheelDirectionKeepsExistingLineScrollConvention() {
        #expect(ScrollPageDirection.up.wheelSign == 1)
        #expect(ScrollPageDirection.down.wheelSign == -1)
    }

    @Test func presetPrefersContentAreaOverSidebar() {
        let sidebar = descriptor(frame: CGRect(x: 0, y: 0, width: 240, height: 600))
        let content = descriptor(frame: CGRect(x: 240, y: 0, width: 1240, height: 800))
        #expect(ScrollRegionRule.presetCandidateIndex(in: [sidebar, content]) == 1)
    }

    @Test func presetKeepsNarrowListWhenNothingElseExists() {
        let conversationList = descriptor(frame: CGRect(x: 0, y: 0, width: 286, height: 713))
        #expect(ScrollRegionRule.presetCandidateIndex(in: [conversationList]) == 0)
    }

    @Test func presetWithoutCandidatesReturnsNil() {
        #expect(ScrollRegionRule.presetCandidateIndex(in: []) == nil)
    }

    @Test func matchingRejectsDifferentRole() {
        let recorded = target(role: "AXScrollArea", identifier: "content")
        let candidate = descriptor(role: "AXWebArea", identifier: "content")
        #expect(ScrollRegionRule.matchScore(candidate: candidate, recorded: recorded) == nil)
    }

    @Test func matchingRequiresAVisibleFeature() {
        let recorded = target(role: "AXScrollArea")
        let candidate = descriptor(role: "AXScrollArea")
        #expect(ScrollRegionRule.matchScore(candidate: candidate, recorded: recorded) == nil)
    }

    @Test func matchingScoresIdentifierAboveFrameAlone() {
        let recorded = target(
            role: "AXScrollArea",
            identifier: "terminal-surface",
            frame: NormalizedAccessibilityFrame(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
        let sameIdentifier = descriptor(identifier: "terminal-surface", context: "AXGroup:content")
        let frameOnly = descriptor(
            identifier: "other",
            frame: CGRect(x: 100, y: 70, width: 800, height: 560)
        )
        let first = ScrollRegionRule.matchScore(candidate: sameIdentifier, recorded: recorded) ?? 0
        let second = ScrollRegionRule.matchScore(candidate: frameOnly, recorded: recorded) ?? 0
        #expect(first > second)
    }

    @Test func ambiguousCandidatesAreReportedInsteadOfGuessed() {
        let recorded = target(role: "AXScrollArea", context: "AXGroup:content")
        let first = descriptor(context: "AXGroup:content")
        let second = descriptor(context: "AXGroup:content")
        if case .failed(let outcome) = ScrollRegionRule.bestMatchIndex(in: [first, second], recorded: recorded) {
            #expect(outcome == .ambiguous)
        } else {
            Issue.record("expected ambiguous match")
        }
    }

    @Test func clearWinnerIsSelected() {
        let recorded = target(role: "AXScrollArea", identifier: "content")
        let winner = descriptor(identifier: "content", context: "AXGroup:content")
        let other = descriptor(identifier: "sidebar", context: "AXGroup:sidebar")
        if case .matched(let index) = ScrollRegionRule.bestMatchIndex(in: [other, winner], recorded: recorded) {
            #expect(index == 1)
        } else {
            Issue.record("expected a matched region")
        }
    }

    @Test func normalizedFrameIsRelativeToWindow() {
        let frame = ScrollRegionRule.normalizedFrame(
            elementFrame: CGRect(x: 100, y: 50, width: 400, height: 300),
            windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        #expect(frame?.x == 0.125)
        #expect(frame?.y == 50.0 / 600.0)
        #expect(frame?.width == 0.5)
        #expect(frame?.height == 0.5)
    }

    @Test func targetRoundTripsThroughJSON() throws {
        let original = target(role: "AXScrollArea", identifier: "content", windowTitle: "cmux")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScrollRegionTarget.self, from: data)
        #expect(decoded == original)
    }

    @Test func legacyProfileWithoutScrollRegionStillDecodes() throws {
        let legacy = """
        {"id":"6F1F0B4A-0E0C-4B43-9C77-1D2B7E6A3C11",
         "displayName":"Legacy","bundleIdentifier":"com.example.legacy",
         "applicationPath":"/Applications/Legacy.app",
         "focusStrategy":"none"}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(CustomApplicationProfile.self, from: legacy)
        #expect(profile.scrollRegionTarget == nil)
    }

    @Test func profileKeepsScrollRegionSeparateFromInputTarget() throws {
        let focusTarget = AccessibilityFocusTarget(
            role: "AXTextArea", identifier: "composer", title: "", description: "",
            help: "", placeholder: "", context: "", windowTitle: "", normalizedFrame: nil
        )
        let scrollTarget = target(role: "AXScrollArea", identifier: "content")
        let profile = CustomApplicationProfile(
            displayName: "App",
            bundleIdentifier: "com.example.app",
            applicationPath: "/Applications/App.app",
            focusStrategy: .recordedAccessibility,
            accessibilityTarget: focusTarget,
            scrollRegionTarget: scrollTarget
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(CustomApplicationProfile.self, from: data)
        #expect(decoded.accessibilityTarget == focusTarget)
        #expect(decoded.scrollRegionTarget == scrollTarget)
    }

    @Test func pageStepsScaleWithVisibleHeight() {
        // 700 pt 内容区：整页 0.9 屏 = 53 行，半页 0.5 屏 = 29 行。
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 700, step: .full) == 53)
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 700, step: .half) == 29)
        // 900 pt 内容区：整页 0.9 屏 = 68 行，半页 0.5 屏 = 38 行。
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 900, step: .full) == 68)
        #expect(ScrollRegionRule.pageScrollLines(regionHeight: 900, step: .half) == 38)
        let fullPoints = Double(ScrollRegionRule.pageScrollLines(regionHeight: 700, step: .full)) *
            ScrollRegionRule.pointsPerLine
        let halfPoints = Double(ScrollRegionRule.pageScrollLines(regionHeight: 700, step: .half)) *
            ScrollRegionRule.pointsPerLine
        #expect(fullPoints >= 600 && fullPoints <= 800, "整页应约为一屏，实际 \(fullPoints) pt")
        #expect(halfPoints >= 300 && halfPoints <= 400, "半页应约为半屏，实际 \(halfPoints) pt")
    }

    @Test func edgeActionsNeverRepeat() {
        #expect(!ButtonAction.scrollToTop.allowsRepeat)
        #expect(!ButtonAction.scrollToBottom.allowsRepeat)
        #expect(ButtonAction.scrollToTop.category == .basicKeys)
        #expect(ButtonAction.scrollToBottom.category == .basicKeys)
        #expect(ScrollPageOutcome.scrolledToEdge.wasHandled)
    }

    @Test func edgeScrollDeliversEnoughLines() {
        #expect(ScrollRegionRule.edgeScrollLines >= 400)
        #expect(ScrollRegionRule.edgeLinesPerChunk > 0)
        #expect(ScrollRegionRule.edgeLinesPerChunk <= ScrollRegionRule.edgeScrollLines)
    }

    /// 真机：需要前台 App 与辅助功能权限，默认跳过。
    /// `REMOTEMIC_LIVE_SCROLL_EDGE_TEST=1 swift test --filter liveEdgeScrollDeliversEvents`
    ///
    /// 只证明「事件已投递、没有报错」，**不证明内容真的移动**——投递成功但界面不动是这轮踩过的坑，
    /// 位移必须靠界面上「滚到顶部/滚到底部」按钮 + 截图确认。
    @Test func liveEdgeScrollDeliversEvents() async throws {
        guard ProcessInfo.processInfo.environment["REMOTEMIC_LIVE_SCROLL_EDGE_TEST"] == "1" else { return }
        let textEdit = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
        )
        textEdit.activate()
        try await Task.sleep(for: .milliseconds(700))

        let bottom = ScrollRegionInjector.scrollToEdge(.bottom)
        #expect(bottom.outcome == .scrolledToEdge, "滚到底部投递失败：\(bottom.outcome.rawValue)")
        try await Task.sleep(for: .milliseconds(400))
        let top = ScrollRegionInjector.scrollToEdge(.top)
        #expect(top.outcome == .scrolledToEdge, "滚到顶部投递失败：\(top.outcome.rawValue)")
    }

    @Test func pageActionsRepeatWhileHeld() {
        // 按住下键要能连续翻页，和行滚动一致；重复节奏由 HIDRemoteTiming 单独限速。
        for action in [ButtonAction.pageUp, .pageDown, .pageUpHalf, .pageDownHalf] {
            #expect(action.allowsRepeat)
            #expect(action.isPageScroll)
            #expect(action.category == .basicKeys)
        }
        #expect(!ButtonAction.scrollUp.isPageScroll)
    }

    @Test func pageRepeatsAreRateLimited() {
        let start = Date()
        #expect(HIDRemoteMonitor.repeatIsDue(
            lastFireAt: nil, now: start, minimumMilliseconds: 250
        ))
        #expect(!HIDRemoteMonitor.repeatIsDue(
            lastFireAt: start, now: start.addingTimeInterval(0.1), minimumMilliseconds: 250
        ))
        #expect(HIDRemoteMonitor.repeatIsDue(
            lastFireAt: start, now: start.addingTimeInterval(0.26), minimumMilliseconds: 250
        ))
        // 行滚动不受这个限速影响，仍按按钮自身间隔执行。
        #expect(HIDRemoteTiming.pageRepeatMinimumMilliseconds > 100)
        // 最长的整页队列为 6 块 × 60ms；连发不能早于它结束。
        let maximumQueueMilliseconds = UInt64(ScrollRegionRule.pageWheelChunks(
            totalLines: ScrollRegionRule.maximumPageLines
        ) - 1) * UInt64(ScrollRegionRule.chunkInterval * 1000)
        #expect(HIDRemoteTiming.pageRepeatMinimumMilliseconds >= maximumQueueMilliseconds)
    }

    @Test func fullWindowWebAreaIsNotTreatedAsARegion() {
        #expect(ScrollRegionRule.acceptsContainer(containerArea: 1_000, windowArea: 1_000) == false)
        #expect(ScrollRegionRule.acceptsContainer(containerArea: 950, windowArea: 1_000) == false)
        #expect(ScrollRegionRule.acceptsContainer(containerArea: 660, windowArea: 1_000))
        #expect(ScrollRegionRule.acceptsContainer(containerArea: 5, windowArea: 1_000) == false)
        #expect(ScrollRegionRule.acceptsContainer(containerArea: 0, windowArea: 1_000) == false)
    }

    @Test func recordedAnonymousContainerFallsBackToRectangle() {
        #expect(ScrollRegionInjector.usesContainerMatching(role: "AXScrollArea"))
        #expect(ScrollRegionInjector.usesContainerMatching(role: "AXWebArea"))
        #expect(ScrollRegionInjector.usesContainerMatching(role: "AXGroup") == false)
        #expect(ScrollRegionInjector.usesContainerMatching(role: "") == false)
    }

    @Test func everyPresetAppHasBuiltInRegion() {
        for preset in PresetApplication.allCases {
            #expect(ScrollRegionPreset.rule(for: preset.bundleIdentifier) != nil)
        }
        #expect(ScrollRegionPreset.rule(for: "com.example.unknown") == nil)
    }

    @Test func measuredContainersUseContainerPlacement() {
        #expect(ScrollRegionPreset.rule(for: "com.cmuxterm.app")?.placement == .container)
        #expect(ScrollRegionPreset.rule(for: "com.google.Chrome")?.placement == .container)
        // Whole-window web areas fall back to the window rectangle.
        #expect(ScrollRegionPreset.rule(for: "com.tencent.workbuddy.mac")?.placement == .windowRect)
        #expect(ScrollRegionPreset.rule(for: "com.apple.Safari")?.placement == .windowRect)
        // DimAgent 的学习记录本身就落在窗口矩形上，内置预设必须保持一致。
        #expect(ScrollRegionPreset.rule(for: "com.dimcode.app")?.placement == .windowRect)
        #expect(ScrollRegionPreset.rule(for: "com.dimcode.app")?.strategy == .lineWheel)
    }

    @Test func outOfRangeNormalizedFramesAreRejected() {
        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedAccessibilityFrame {
            NormalizedAccessibilityFrame(x: x, y: y, width: w, height: h)
        }
        #expect(ScrollRegionRule.isValid(normalizedFrame: frame(0.1, 0.1, 0.5, 0.5)))
        #expect(ScrollRegionRule.isValid(normalizedFrame: frame(-0.1, 0.1, 0.5, 0.5)) == false)
        #expect(ScrollRegionRule.isValid(normalizedFrame: frame(0.1, 0.1, 0, 0.5)) == false)
        #expect(ScrollRegionRule.isValid(normalizedFrame: frame(0.8, 0.1, 0.5, 0.5)) == false)
        #expect(ScrollRegionRule.isValid(normalizedFrame: frame(0.1, 0.1, 0.5, 1.2)) == false)
        #expect(ScrollRegionRule.isValid(normalizedFrame: frame(.nan, 0.1, 0.5, 0.5)) == false)
    }

    @Test func legacyPixelWheelRecordsStillDecode() throws {
        let legacy = """
        {"role":"AXScrollArea","identifier":"content","windowTitle":"cmux","context":"",
         "source":"learned","strategy":"pixelWheel"}
        """.data(using: .utf8)!
        let target = try JSONDecoder().decode(ScrollRegionTarget.self, from: legacy)
        #expect(target.strategy == .lineWheel)
    }
}
