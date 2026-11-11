import CoreGraphics
import Foundation
import Testing
@testable import RemoteMic

@Suite("Notice placement")
struct NoticePlacementTests {
    private let container = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let bubble = CGSize(width: 320, height: 100)

    @Test func prefersRightSideWhenThereIsRoom() {
        let anchor = CGRect(x: 100, y: 250, width: 120, height: 32)
        let result = NoticePlacement.resolve(anchor: anchor, container: container, bubbleSize: bubble)
        #expect(result.edge == .leading)
        #expect(result.origin.x == anchor.maxX + NoticePlacement.gap)
        #expect(result.origin.y == anchor.midY - bubble.height / 2)
    }

    @Test func flipsToLeftWhenRightSideIsTight() {
        let anchor = CGRect(x: 640, y: 250, width: 120, height: 32)
        let result = NoticePlacement.resolve(anchor: anchor, container: container, bubbleSize: bubble)
        #expect(result.edge == .trailing)
        #expect(result.origin.x == anchor.minX - bubble.width - NoticePlacement.gap)
    }

    @Test func fallsBackToBelowThenAbove() {
        let wideBubble = CGSize(width: 700, height: 100)
        let centered = CGRect(x: 340, y: 240, width: 120, height: 32)

        let below = NoticePlacement.resolve(
            anchor: centered,
            container: container,
            bubbleSize: wideBubble
        )
        #expect(below.edge == .top)
        #expect(below.origin.y == centered.maxY + NoticePlacement.gap)

        let lowerAnchor = CGRect(x: 340, y: 520, width: 120, height: 32)
        let above = NoticePlacement.resolve(
            anchor: lowerAnchor,
            container: container,
            bubbleSize: wideBubble
        )
        #expect(above.edge == .bottom)
    }

    @Test func centeredOriginPlacesTopMiddleAndBottom() {
        let top = NoticePlacement.centeredOrigin(
            position: .top, container: container, bubbleSize: bubble
        )
        #expect(top.y == NoticePlacement.margin)
        #expect(top.x == (container.width - bubble.width) / 2)

        let middle = NoticePlacement.centeredOrigin(
            position: .center, container: container, bubbleSize: bubble
        )
        #expect(middle.y == (container.height - bubble.height) / 2)

        let bottom = NoticePlacement.centeredOrigin(
            position: .bottom, container: container, bubbleSize: bubble
        )
        #expect(bottom.y == container.maxY - bubble.height - NoticePlacement.margin)
    }

    @Test func centeredOriginClampsWhenBubbleIsTallerThanContainer() {
        let short = CGRect(x: 0, y: 0, width: 400, height: 120)
        let tallBubble = CGSize(width: 320, height: 200)
        let origin = NoticePlacement.centeredOrigin(
            position: .center, container: short, bubbleSize: tallBubble
        )
        #expect(origin.y == NoticePlacement.margin)
    }

    @Test func keepsBubbleInsideContainer() {
        let anchor = CGRect(x: 0, y: 0, width: 40, height: 40)
        let result = NoticePlacement.resolve(anchor: anchor, container: container, bubbleSize: bubble)
        #expect(result.origin.x >= NoticePlacement.margin)
        #expect(result.origin.y >= NoticePlacement.margin)
    }

    @Test func clampsWhenBubbleIsWiderThanContainer() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 200)
        let wideBubble = CGSize(width: 400, height: 80)
        let result = NoticePlacement.resolve(
            anchor: CGRect(x: 80, y: 80, width: 40, height: 40),
            container: narrow,
            bubbleSize: wideBubble
        )
        // 放不下时贴左，不出现负坐标。
        #expect(result.origin.x == NoticePlacement.margin)
    }
}

@Suite("Notice center", .serialized)
@MainActor
struct NoticeCenterTests {
    private func makeCenter() -> (NoticeCenter, UserDefaults, String) {
        let name = "NoticeCenterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (NoticeCenter(defaults: defaults), defaults, name)
    }

    @Test func errorReplacesTipButNotTheOtherWayRound() {
        let (center, defaults, name) = makeCenter()
        defer { defaults.removePersistentDomain(forName: name) }

        center.show(Notice(tier: .tip, title: "引导", dismissal: .manual))
        #expect(center.current?.tier == .tip)

        center.show(Notice(tier: .error, title: "失败", dismissal: .manual))
        #expect(center.current?.tier == .error)

        center.show(Notice(tier: .tip, title: "另一条引导", dismissal: .manual))
        #expect(center.current?.tier == .error)
        #expect(center.current?.title == "失败")
    }

    @Test func seenKeyShowsOnlyOnce() {
        let (center, defaults, name) = makeCenter()
        defer { defaults.removePersistentDomain(forName: name) }

        let key = "tip.test.v1"
        center.show(Notice(tier: .tip, title: "第一次", dismissal: .manual, seenKey: key))
        #expect(center.current?.title == "第一次")

        center.dismiss()
        center.show(Notice(tier: .tip, title: "第二次", dismissal: .manual, seenKey: key))
        #expect(center.current == nil)
        #expect(defaults.bool(forKey: key))
    }

    @Test func automaticDismissalClearsNotice() async throws {
        let (center, defaults, name) = makeCenter()
        defer { defaults.removePersistentDomain(forName: name) }

        center.show(Notice(tier: .tip, title: "自动消失", dismissal: .automatic(0.02)))
        #expect(center.current != nil)

        // CI 的 Task 调度可能比本地慢，轮询到上限而不是固定等一次。
        for _ in 0..<100 where center.current != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(center.current == nil)
    }

    @Test func manualDismissalSurvivesTimeout() async throws {
        let (center, defaults, name) = makeCenter()
        defer { defaults.removePersistentDomain(forName: name) }

        center.show(Notice(tier: .error, title: "必须手动关", dismissal: .manual))
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(center.current != nil)

        center.dismiss()
        #expect(center.current == nil)
    }

    @Test func staleDismissDoesNotKillNewerNotice() {
        let (center, defaults, name) = makeCenter()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = Notice(tier: .tip, title: "第一条", dismissal: .manual)
        center.show(first)
        center.show(Notice(tier: .tip, title: "第二条", dismissal: .manual))
        center.dismiss(first.id)
        #expect(center.current?.title == "第二条")
    }
}

@Suite("Notice action titles")
struct NoticeActionTests {
    @Test func standardActionsUseSharedKeys() {
        #expect(NoticeActionKind.reopenCommonPhrases.titleKey == "notice.action.reopen_common_phrases")
        #expect(NoticeActionKind.openSystemSettings.titleKey == "notice.action.open_system_settings")
        #expect(NoticeActionKind.retry.titleKey == "notice.action.retry")
        #expect(NoticeActionKind.dismiss.titleKey == "notice.action.dismiss")
    }

    @Test func noticeKeepsRequestedPosition() {
        #expect(Notice(tier: .tip, title: "居中").position == .center)
        #expect(Notice(tier: .tip, title: "顶部", position: .top).position == .top)
        #expect(Notice(tier: .error, title: "底部", position: .bottom).position == .bottom)
    }

    @Test func defaultDismissalFollowsTier() {
        #expect(Notice.defaultDismissal(for: .tip) == .automatic(2.4))
        #expect(Notice.defaultDismissal(for: .warning) == .automatic(4.0))
        #expect(Notice.defaultDismissal(for: .error) == .automatic(6.0))
    }
}

#if canImport(SayAllHostBridge)
import SayAllHostBridge

/// 私有桥到公开组件的映射：只在私有依赖存在时编译。
@Suite("Notice host bridge mapping")
struct NoticeHostBridgeMappingTests {
    @Test func everyToneMapsToTheSameTier() {
        #expect(HostNoticeRequest.Tone.tip.noticeTier == .tip)
        #expect(HostNoticeRequest.Tone.warning.noticeTier == .warning)
        #expect(HostNoticeRequest.Tone.error.noticeTier == .error)
    }
}
#endif
