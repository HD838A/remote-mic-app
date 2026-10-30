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
            strategy: .pixelWheel
        )
    }

    @Test func pageScrollKeepsTenPercentOverlap() {
        #expect(ScrollRegionRule.pageScrollPixels(regionHeight: 800) == 720)
        #expect(ScrollRegionRule.pageScrollPixels(regionHeight: 1000) == 900)
    }

    @Test func pageScrollNeverGoesBelowThreeLines() {
        #expect(ScrollRegionRule.pageScrollPixels(regionHeight: 10) == ScrollRegionRule.minimumPagePixels)
        #expect(ScrollRegionRule.pageScrollPixels(regionHeight: 0) == ScrollRegionRule.minimumPagePixels)
        #expect(ScrollRegionRule.pageScrollPixels(regionHeight: -100) == ScrollRegionRule.minimumPagePixels)
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

    @Test func pageActionsAreNotInTheHoldRepeatWhitelist() {
        #expect(ButtonAction.pageUp.allowsRepeat == false)
        #expect(ButtonAction.pageDown.allowsRepeat == false)
        #expect(ButtonAction.pageUp.category == .basicKeys)
        #expect(ButtonAction.pageDown.category == .basicKeys)
    }

    @Test func recordedAnonymousContainerFallsBackToRectangle() {
        #expect(ScrollRegionInjector.usesContainerMatching(role: "AXScrollArea"))
        #expect(ScrollRegionInjector.usesContainerMatching(role: "AXWebArea"))
        #expect(ScrollRegionInjector.usesContainerMatching(role: "AXGroup") == false)
        #expect(ScrollRegionInjector.usesContainerMatching(role: "") == false)
    }

    @Test func calibrationIsRequiredForAppsWithoutMeasuredStructure() {
        #expect(ScrollRegionPreset.rule(for: "com.cmuxterm.app") != nil)
        #expect(ScrollRegionPreset.rule(for: "com.tencent.workbuddy.mac") == nil)
        #expect(ScrollRegionPreset.rule(for: "com.tencent.xinWeChat") == nil)
    }
}
