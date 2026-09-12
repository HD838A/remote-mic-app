import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Siri Remote cursor feedback")
struct SiriRemoteCursorFeedbackTests {
    @Test func pointerScaleIsBoundedAndGrowsWithSpeed() {
        let slow = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: 0)
        let medium = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: 30)
        let fast = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: 500)

        #expect(slow == 1.0)
        #expect(slow < medium)
        #expect(medium < fast)
        #expect(abs(Double(fast) - 2.2) < 0.0001)
    }

    @Test func pointerAndScrollUseTheSameSpeedScaleAndBaseSize() {
        let speed = 12.0
        let scale = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: speed)

        #expect(SiriRemoteCursorFeedbackState.presentation(
            for: .pointerMoved(deltaX: speed, deltaY: 0, speed: speed)
        ) == .pointer(scale: scale))
        #expect(SiriRemoteCursorFeedbackState.presentation(
            for: .scrolled(
                pixels: 4,
                speed: speed,
                physicalDirection: .counterClockwise
            )
        ) == .scroll(direction: .up, arrowCount: 2, scale: scale))
        #expect(SiriRemoteCursorFeedbackState.baseIndicatorDiameter == 36)
    }

    @Test func hoverClickRejectsAnElementAfterTheCursorMovesAway() {
        #expect(SiriRemoteCursorFeedbackState.cursorRemainsAtTarget(
            current: CGPoint(x: 101, y: 99),
            target: CGPoint(x: 100, y: 100)
        ))
        #expect(!SiriRemoteCursorFeedbackState.cursorRemainsAtTarget(
            current: CGPoint(x: 104, y: 100),
            target: CGPoint(x: 100, y: 100)
        ))
    }

    @Test func scrollFeedbackUsesPageIndicatorDirectionAndCanReverseOnlyTheCue() {
        let speed = 12.0
        let scale = SiriRemoteCursorFeedbackState.indicatorScale(forSpeed: speed)
        #expect(SiriRemoteCursorFeedbackState.presentation(for: .scrolled(
            pixels: 4,
            speed: speed,
            physicalDirection: .counterClockwise
        )) == .scroll(direction: .up, arrowCount: 2, scale: scale))
        #expect(SiriRemoteCursorFeedbackState.presentation(for: .scrolled(
            pixels: 4,
            speed: speed,
            physicalDirection: .clockwise
        )) == .scroll(direction: .up, arrowCount: 2, scale: scale))
        #expect(SiriRemoteCursorFeedbackState.presentation(
            for: .scrolled(
                pixels: 4,
                speed: speed,
                physicalDirection: .counterClockwise
            ),
            scrollArrowReversed: true
        ) == .scroll(direction: .down, arrowCount: 2, scale: scale))
        #expect(SiriRemoteCursorFeedbackState.presentation(for: .scrolled(
            pixels: -4,
            speed: speed,
            physicalDirection: .clockwise
        )) == .scroll(direction: .down, arrowCount: 2, scale: scale))
    }

    @Test func scrollArrowCountIsBoundedAndMonotonicWithSpeed() {
        #expect(SiriRemoteCursorFeedbackState.arrowCount(forSpeed: 0) == 1)
        #expect(SiriRemoteCursorFeedbackState.arrowCount(forSpeed: 7.99) == 1)
        #expect(SiriRemoteCursorFeedbackState.arrowCount(forSpeed: 8) == 2)
        #expect(SiriRemoteCursorFeedbackState.arrowCount(forSpeed: 23.99) == 2)
        #expect(SiriRemoteCursorFeedbackState.arrowCount(forSpeed: 24) == 3)
        #expect(SiriRemoteCursorFeedbackState.arrowCount(forSpeed: 500) == 3)
    }

    @Test func scrollArrowDirectionPreferenceDefaultsToMatchAndPersists() throws {
        let suiteName = "RemoteMicTests.SiriRemoteScrollArrow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.siriRemoteScrollArrowReversed)
        settings.siriRemoteScrollArrowReversed = true
        #expect(AppSettings(defaults: defaults).siriRemoteScrollArrowReversed)
    }

    @Test func scrollArrowSettingHasCompleteLocalizedCopy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for localization in ["zh-Hans", "en"] {
            let contents = try String(
                contentsOf: root.appendingPathComponent(
                    "Resources/\(localization).lproj/Localizable.strings"
                ),
                encoding: .utf8
            )
            for key in [
                "siri_remote.scroll_arrow.reverse.title",
                "siri_remote.scroll_arrow.reverse.detail",
                "siri_remote.scroll_arrow.reverse.help",
            ] {
                #expect(contents.contains("\"\(key)\" ="))
            }
        }
    }

    @Test func feedbackFrameCentersOnTheVisibleCursorBody() {
        let point = CGPoint(x: 400, y: 300)
        let layout = SiriRemoteCursorFeedbackLayout.layout(
            for: point,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let cursorCenter = SiriRemoteCursorFeedbackLayout.cursorBodyCenter(for: point)

        #expect(layout.placement == .centeredOnCursor)
        #expect(layout.frame.midX == cursorCenter.x)
        #expect(layout.frame.midY == cursorCenter.y)
        #expect(layout.frame.contains(point))
    }

    @Test func clickablePointerTargetExtendsVisibilityAndConsumesOnlyOneOKPress() {
        var interaction = SiriRemoteCursorFeedbackInteractionState()

        #expect(interaction.pointerBecameIdle(hasClickableTarget: false) == .hide)
        let unavailableConsumed = interaction.consumeOK()
        #expect(!unavailableConsumed)
        #expect(interaction.pointerBecameIdle(hasClickableTarget: true) == .holdForClick(
            SiriRemoteCursorFeedbackInteractionState.clickableTargetHoldDelay
        ))
        #expect(SiriRemoteCursorFeedbackInteractionState.clickableTargetHoldDelay == 2.0)
        let firstConsumed = interaction.consumeOK()
        let duplicateConsumed = interaction.consumeOK()
        #expect(firstConsumed)
        #expect(!duplicateConsumed)

        _ = interaction.pointerBecameIdle(hasClickableTarget: true)
        interaction.scrolled()
        let consumedAfterScroll = interaction.consumeOK()
        #expect(!consumedAfterScroll)
    }

    @Test func clickableTargetResolverChecksOnlyTheBoundedAncestorChain() {
        let parents = [10: 20, 20: 30, 30: 40, 40: 50, 50: 60]

        let direct = SiriRemotePressableTargetResolver.resolve(
            startingAt: 10,
            supportsPress: { $0 == 10 },
            parent: { parents[$0] }
        )
        #expect(direct?.element == 10)
        #expect(direct?.depth == 0)

        let ancestor = SiriRemotePressableTargetResolver.resolve(
            startingAt: 10,
            supportsPress: { $0 == 40 },
            parent: { parents[$0] }
        )
        #expect(ancestor?.element == 40)
        #expect(ancestor?.depth == 3)

        let beyondLimit = SiriRemotePressableTargetResolver.resolve(
            startingAt: 10,
            supportsPress: { $0 == 60 },
            parent: { parents[$0] }
        )
        #expect(beyondLimit == nil)
    }

    @Test func feedbackStaysCenteredAtScreenEdgesInsteadOfDriftingAway() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        for point in [
            CGPoint(x: 998, y: 2),
            CGPoint(x: 998, y: 798),
            CGPoint(x: 2, y: 2),
        ] {
            let layout = SiriRemoteCursorFeedbackLayout.layout(
                for: point,
                visibleFrame: screen
            )
            let cursorCenter = SiriRemoteCursorFeedbackLayout.cursorBodyCenter(for: point)
            #expect(layout.frame.midX == cursorCenter.x)
            #expect(layout.frame.midY == cursorCenter.y)
        }
    }

    @Test func hostWiresPrivateTouchFeedbackIntoTheVisibleController() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integration = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/SiriRemoteFeatureIntegration.swift"
            ),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let renderer = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/SettingsScreenshotRenderer.swift"
            ),
            encoding: .utf8
        )
        let settingsView = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(integration.contains("feature.onTouchFeedback ="))
        #expect(integration.contains("feature.onCenterTapConfirmation ="))
        #expect(model.contains("siriRemoteFeature.onTouchFeedback ="))
        #expect(model.contains("siriRemoteFeature.onCenterTapConfirmation ="))
        #expect(model.contains("scrollArrowReversed: settings.siriRemoteScrollArrowReversed"))
        #expect(model.contains("siriRemoteCursorFeedback.stop()"))
        #expect(model.contains("siriRemoteCursorFeedback.activateHoveredElementIfAvailable()"))
        #expect(model.contains("appleRemoteHoverClickDevices.insert(event.device)"))
        #expect(model.contains("appleRemoteHoverClickDevices.remove(event.device)"))
        #expect(model.contains("siriRemoteCursorFeedback.cancelInteraction(reason: \"voice_started\")"))
        #expect(model.contains("siriRemoteCursorFeedback.cancelInteraction(reason: \"device_reset\")"))
        #expect(model.contains("APPLE REMOTE HOVER_CLICK phase=ended result=consumed"))
        #expect(renderer.contains("REMOTE_MIC_SETTINGS_SCREENSHOT_SIRI_REMOTE"))
        let directionToggle = try #require(settingsView.range(
            of: "Toggle(isOn: $settings.siriRemoteScrollArrowReversed)"
        ))
        let siriMappingPage = try #require(settingsView.range(of: "SiriRemoteMappingPage("))
        #expect(directionToggle.lowerBound < siriMappingPage.lowerBound)
        #expect(settingsView[directionToggle.lowerBound...].prefix(900).contains(
            ".font(.system(size: 12))"
        ))
    }

    @MainActor
    @Test func productionViewRendersReviewArtifactsWhenRequested() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment[
            "SAYALL_CURSOR_FEEDBACK_SCREENSHOT_DIR"
        ], !outputDirectory.isEmpty else { return }
        let presentations: [(String, SiriRemoteCursorFeedbackState.Presentation)] = [
            ("touch-halo", .pointer(scale: 1.0)),
            ("scroll-up-slow", .scroll(direction: .up, arrowCount: 1, scale: 1.0)),
            ("scroll-up-fast", .scroll(direction: .up, arrowCount: 3, scale: 2.2)),
            ("scroll-down-medium", .scroll(direction: .down, arrowCount: 2, scale: 1.4)),
        ]
        for appearance in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua),
        ] {
            for (name, presentation) in presentations {
                let view = SiriRemoteCursorFeedbackView(
                    frame: NSRect(x: 0, y: 0, width: 104, height: 104)
                )
                view.appearance = NSAppearance(named: appearance.1)
                view.presentation = presentation
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    Issue.record("Unable to allocate cursor feedback bitmap")
                    return
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    Issue.record("Unable to encode cursor feedback PNG")
                    return
                }
                let url = URL(fileURLWithPath: outputDirectory)
                    .appendingPathComponent("\(appearance.0)-\(name).png")
                try data.write(to: url, options: .atomic)
            }
        }
    }
}
