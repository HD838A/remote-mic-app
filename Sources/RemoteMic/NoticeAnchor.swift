import SwiftUI

/// 锚点标识。
///
/// 用 `RawRepresentable` 而不是枚举，业务侧可以按需扩展，不必回来改组件：
/// `NoticeAnchorID(rawValue: "settings.language")`。
struct NoticeAnchorID: Hashable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let voiceKey = NoticeAnchorID(rawValue: "mapping.voice-key")
    static let inputMonitoring = NoticeAnchorID(rawValue: "permission.input-monitoring")
    static let phraseField = NoticeAnchorID(rawValue: "common-phrases.field")
}

/// 子视图把自身 bounds 上报给窗口根，供气泡定位。
struct NoticeAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [NoticeAnchorID: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [NoticeAnchorID: Anchor<CGRect>],
        nextValue: () -> [NoticeAnchorID: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 把一个视图标记为可锚定的目标。
    func noticeAnchor(_ id: NoticeAnchorID) -> some View {
        anchorPreference(key: NoticeAnchorPreferenceKey.self, value: .bounds) {
            [id: $0]
        }
    }

    /// 在窗口根挂一次，负责把气泡放到当前锚点上。
    func noticeHost(center: NoticeCenter = .shared) -> some View {
        overlayPreferenceValue(NoticeAnchorPreferenceKey.self) { anchors in
            GeometryReader { proxy in
                NoticeHostLayer(anchors: anchors, proxy: proxy, center: center)
            }
        }
    }
}

/// 摆放结果：尾巴朝哪、气泡左上角在哪。
///
/// 抽成纯函数，方便单测覆盖四个方向和翻转，不必起 UI。
enum NoticePlacement {
    struct Result: Equatable {
        let edge: NoticeTail.Edge
        let origin: CGPoint
    }

    /// 间距 8pt，尾巴另占 10pt；贴边留 12pt。
    static let gap: CGFloat = 8
    static let margin: CGFloat = 12

    /// 没有锚点时的落点：顶部 / 正中 / 底部，左右始终居中。
    static func centeredOrigin(
        position: NoticePosition,
        container: CGRect,
        bubbleSize: CGSize
    ) -> CGPoint {
        let x = max(
            container.minX + margin,
            (container.width - bubbleSize.width) / 2
        )
        let y: CGFloat
        switch position {
        case .top:
            y = container.minY + margin
        case .center:
            y = (container.height - bubbleSize.height) / 2
        case .bottom:
            y = container.maxY - bubbleSize.height - margin
        }
        return CGPoint(x: x, y: max(container.minY + margin, y))
    }

    static func resolve(
        anchor: CGRect,
        container: CGRect,
        bubbleSize: CGSize
    ) -> Result {
        let spaceTrailing = container.maxX - anchor.maxX
        let spaceLeading = anchor.minX - container.minX
        let spaceBelow = container.maxY - anchor.maxY
        let spaceAbove = anchor.minY - container.minY
        let neededWidth = bubbleSize.width + gap + margin
        let neededHeight = bubbleSize.height + gap + margin

        let edge: NoticeTail.Edge
        if spaceTrailing >= neededWidth {
            edge = .leading
        } else if spaceLeading >= neededWidth {
            edge = .trailing
        } else if spaceBelow >= neededHeight {
            edge = .top
        } else if spaceAbove >= neededHeight {
            edge = .bottom
        } else {
            // 四周都放不下：选空间更大的一侧，再靠夹取保证不出界。
            edge = spaceBelow >= spaceAbove ? .top : .bottom
        }

        var origin: CGPoint
        switch edge {
        case .leading:
            origin = CGPoint(
                x: anchor.maxX + gap,
                y: anchor.midY - bubbleSize.height / 2
            )
        case .trailing:
            origin = CGPoint(
                x: anchor.minX - bubbleSize.width - gap,
                y: anchor.midY - bubbleSize.height / 2
            )
        case .top:
            origin = CGPoint(
                x: anchor.midX - bubbleSize.width / 2,
                y: anchor.maxY + gap
            )
        case .bottom:
            origin = CGPoint(
                x: anchor.midX - bubbleSize.width / 2,
                y: anchor.minY - bubbleSize.height - gap
            )
        }

        origin.x = max(
            container.minX + margin,
            min(origin.x, container.maxX - bubbleSize.width - margin)
        )
        origin.y = max(
            container.minY + margin,
            min(origin.y, container.maxY - bubbleSize.height - margin)
        )
        return Result(edge: edge, origin: origin)
    }
}

/// 气泡的宿主层：读 `NoticeCenter` 的当前提示，按锚点或居中摆放。
struct NoticeHostLayer: View {
    let anchors: [NoticeAnchorID: Anchor<CGRect>]
    let proxy: GeometryProxy
    @ObservedObject var center: NoticeCenter

    @State private var measured: CGSize = .zero

    /// 第一帧尺寸未知时先按设计稿上限估算，避免先跳到左上角再回位。
    private var bubbleSize: CGSize {
        measured == .zero ? CGSize(width: 320, height: 84) : measured
    }

    var body: some View {
        if let notice = center.current {
            bubble(for: notice)
        }
    }

    @ViewBuilder
    private func bubble(for notice: Notice) -> some View {
        let container = CGRect(origin: .zero, size: proxy.size)

        if let id = notice.anchor, let anchor = anchors[id] {
            let rect = proxy[anchor]
            let placement = NoticePlacement.resolve(
                anchor: rect,
                container: container,
                bubbleSize: bubbleSize
            )
            view(for: notice, tail: NoticeTail(edge: placement.edge))
                .background(NoticeSizeReader { measured = $0 })
                .offset(x: placement.origin.x, y: placement.origin.y)
                // 尺寸测到之前不显示，避免第一帧错位被看到。
                .opacity(measured == .zero ? 0 : 1)
        } else {
            let origin = NoticePlacement.centeredOrigin(
                position: notice.position,
                container: container,
                bubbleSize: bubbleSize
            )
            view(for: notice, tail: nil)
                .background(NoticeSizeReader { measured = $0 })
                .offset(x: origin.x, y: origin.y)
                .opacity(measured == .zero ? 0 : 1)
        }
    }

    private func view(for notice: Notice, tail: NoticeTail?) -> some View {
        NoticeBubble(
            tier: notice.tier,
            title: notice.title,
            text: notice.text,
            action: notice.action,
            tail: tail,
            onClose: notice.dismissible ? { center.dismiss(notice.id) } : nil
        )
    }
}

/// 上报气泡实际尺寸，供第二帧精确定位。
private struct NoticeSizeReader: View {
    let onChange: (CGSize) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: NoticeSizePreferenceKey.self, value: proxy.size)
        }
        .onPreferenceChange(NoticeSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            onChange(size)
        }
    }
}

private struct NoticeSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
