import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// 生产 HUD 视图：常显的半透明监控面板。
///
/// 顶部是状态行（待命 / 需要注意 + 本次会话次数），下面是最近一条动作；
/// 失败时展开原因、建议和操作按钮，并停在面板里等用户处理。
struct ActionFeedbackView: View {
    /// 正在展示的反馈；nil 表示空闲态，面板只显示最近一条。
    let presentation: ActionFeedbackPresentation?
    let lastPresentation: ActionFeedbackPresentation?
    let sessionCount: Int
    let strings: ActionFeedbackStrings?
    let isCopied: Bool
    let onAction: (ActionFeedbackAction) -> Void
    let onCopy: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private var isFailure: Bool { presentation?.kind == .failure }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow
            if let active = presentation {
                divider
                if active.kind == .failure {
                    failureBody(active)
                } else {
                    detailRow(
                        title: active.title,
                        elapsed: active.elapsedMilliseconds,
                        live: true
                    )
                }
            } else if let last = lastPresentation {
                divider
                detailRow(
                    title: last.title,
                    elapsed: last.elapsedMilliseconds,
                    live: false
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: ActionFeedbackLayout.hudWidth, alignment: .leading)
        .background(shape.fill(.ultraThinMaterial))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .contentShape(shape)
        // 整块可拖：点击（<2pt）仍交给下面的按钮。
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onDragEnd() }
        )
        .onHover(perform: onHover)
    }

    private var statusRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let countText {
                Text(countText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private func detailRow(title: String, elapsed: Int, live: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: live ? .medium : .regular))
                .foregroundStyle(live ? Color.primary : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(elapsedText(elapsed))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func failureBody(_ active: ActionFeedbackPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(active.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(elapsedText(active.elapsedMilliseconds))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(active.closeLabel ?? "")
            }
            if let context = active.context {
                Text(context)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = active.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if primaryTitle != nil || copyTitle != nil {
                HStack(spacing: 8) {
                    if let title = primaryTitle {
                        hudButton(title, prominent: true) {
                            if let action = active.action { onAction(action) }
                        }
                    }
                    if let title = copyTitle {
                        hudButton(
                            isCopied ? (active.copiedTitle ?? title) : title,
                            prominent: false,
                            action: onCopy
                        )
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var primaryTitle: String? {
        guard presentation?.action != nil else { return nil }
        return presentation?.actionTitle
    }

    private var copyTitle: String? {
        presentation?.copyTitle
    }

    private func hudButton(
        _ title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        prominent
                            ? Color.accentColor.opacity(0.9)
                            : Color.primary.opacity(0.10)
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        let template = isFailure ? strings?.hudAttentionStatus : strings?.hudIdleStatus
        return template ?? "—"
    }

    private var statusColor: Color {
        if isFailure { return .red }
        return presentation == nil ? .secondary : .green
    }

    private var countText: String? {
        guard sessionCount > 0, let strings else { return nil }
        return strings.format(strings.hudSessionCountFormat, String(sessionCount))
    }

    private func elapsedText(_ milliseconds: Int) -> String {
        guard milliseconds >= 1000 else { return "\(max(milliseconds, 0))ms" }
        return String(format: "%.1fs", Double(milliseconds) / 1000)
    }
}

/// 只观察 `ActionFeedbackCenter` 并维护真实浮层；不持有业务状态。
@MainActor
final class ActionFeedbackWindowCoordinator {
    private let center: ActionFeedbackCenter
    private let placementStore: ActionFeedbackPlacementStore
    private var panel: ActionFeedbackPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var cancellable: AnyCancellable?
    private var loggedRenderKey: String?
    private var dragOrigin: CGPoint?
    private var usedStoredPlacement = false

    init(
        center: ActionFeedbackCenter? = nil,
        placementStore: ActionFeedbackPlacementStore = ActionFeedbackPlacementStore()
    ) {
        self.center = center ?? .shared
        self.placementStore = placementStore
    }

    func start() {
        cancellable = Publishers.CombineLatest4(
            center.$presentation,
            center.$copiedPresentationID,
            center.$lastPresentation,
            center.$sessionCount
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] presentation, copiedID, lastPresentation, sessionCount in
            self?.render(
                presentation,
                copiedID: copiedID,
                lastPresentation: lastPresentation,
                sessionCount: sessionCount
            )
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
    }

    /// 面板常显：只要本次会话出现过动作（sessionCount > 0）就一直挂着；
    /// presentation 为 nil 时只显示空闲状态和最近一条。设置里关掉开关走
    /// `reset()`，sessionCount 归零后面板隐藏。
    private func render(
        _ presentation: ActionFeedbackPresentation?,
        copiedID: UUID?,
        lastPresentation: ActionFeedbackPresentation?,
        sessionCount: Int
    ) {
        guard sessionCount > 0 else {
            hidePanel()
            return
        }
        guard let screen = ActionFeedbackScreenResolver.preferredScreen() else { return }
        let host = ensureHostingView()
        let view = ActionFeedbackView(
            presentation: presentation,
            lastPresentation: lastPresentation,
            sessionCount: sessionCount,
            strings: center.latestStrings,
            isCopied: presentation != nil && copiedID == presentation?.id,
            onAction: { [weak center] action in center?.perform(action) },
            onCopy: { [weak center] in center?.copyDiagnostics() },
            onClose: { [weak center] in center?.dismiss() },
            onHover: { [weak center] hovering in center?.setHovering(hovering) },
            onDrag: { [weak self] translation in self?.handleDrag(translation) },
            onDragEnd: { [weak self] in self?.finishDrag() }
        )
        host.rootView = AnyView(view)
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 {
            size = NSSize(width: ActionFeedbackLayout.hudWidth, height: 64)
        }
        // 固定宽度，空闲态和失败态之间左右不跳动。
        size.width = ActionFeedbackLayout.hudWidth
        size.height = max(size.height, 1)
        let panel = ensurePanel()
        panel.ignoresMouseEvents = false
        panel.setContentSize(size)
        let origin = placementOrigin(panelSize: size, screen: screen)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        host.frame = NSRect(origin: .zero, size: size)
        panel.orderFrontRegardless()
        let renderKey = "\(sessionCount)-\(presentation?.id.uuidString ?? "idle")"
        if loggedRenderKey != renderKey {
            loggedRenderKey = renderKey
            let kindName = presentation.map { "\($0.kind)" } ?? "idle"
            AppLogger.shared.write(
                "ACTION FEEDBACK panel phase=shown kind=\(kindName) " +
                    "session_count=\(sessionCount) " +
                    "width=\(Int(size.width)) height=\(Int(size.height)) " +
                    "x=\(Int(origin.x)) y=\(Int(origin.y)) " +
                    "placement=\(usedStoredPlacement ? "stored" : "default") " +
                    "window_number=\(panel.windowNumber) " +
                    "screen_width=\(Int(screen.visibleFrame.width)) " +
                    "screen_height=\(Int(screen.visibleFrame.height)) " +
                    "ignores_mouse=false"
            )
        }
        if let presentation,
           presentation.announces,
           let announcement = presentation.accessibilityAnnouncement,
           let contentView = panel.contentView {
            let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
            NSAccessibility.post(
                element: contentView,
                notification: .announcementRequested,
                userInfo: userInfo
            )
        }
    }

    private func hidePanel() {
        if dragOrigin != nil {
            dragOrigin = nil
            center.setDragging(false)
        }
        center.setHovering(false)
        panel?.orderOut(nil)
        if loggedRenderKey != nil {
            loggedRenderKey = nil
            AppLogger.shared.write("ACTION FEEDBACK panel phase=hidden")
        }
    }

    private func ensureHostingView() -> NSHostingView<AnyView> {
        if let hostingView { return hostingView }
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.autoresizingMask = [.width, .height]
        hostingView = host
        return host
    }

    private func ensurePanel() -> ActionFeedbackPanel {
        if let panel { return panel }
        let panel = ActionFeedbackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 412, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // .floating 低于 Dock（20）和菜单栏（24），气泡会被压住；HUD 需要盖住
        // Dock、菜单栏和其他 App 的全屏窗口，因此固定在 .screenSaver。
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        // 拖动由 SwiftUI 手势驱动，不用系统的窗口背景拖动，避免和按钮点击抢事件。
        panel.isMovable = false
        panel.contentView = ensureHostingView()
        self.panel = panel
        return panel
    }

    /// 记住过就按记忆位置还原，没记住过就用默认落点。
    private func placementOrigin(panelSize: CGSize, screen: NSScreen) -> CGPoint {
        if let displayID = screen.actionFeedbackDisplayID,
           let saved = placementStore.placement(displayID: displayID) {
            usedStoredPlacement = true
            return ActionFeedbackLayout.origin(
                normalizedX: saved.normalizedX,
                normalizedY: saved.normalizedY,
                panelSize: panelSize,
                visibleFrame: screen.visibleFrame
            )
        }
        usedStoredPlacement = false
        return ActionFeedbackLayout.origin(
            visibleFrame: screen.visibleFrame,
            panelSize: panelSize
        )
    }

    private func handleDrag(_ translation: CGSize) {
        guard let panel else { return }
        if dragOrigin == nil {
            dragOrigin = panel.frame.origin
            center.setDragging(true)
        }
        guard let start = dragOrigin,
              let visibleFrame = (panel.screen?.visibleFrame)
        else { return }
        panel.setFrameOrigin(
            ActionFeedbackLayout.clampedOrigin(
                CGPoint(
                    x: start.x + translation.width,
                    y: start.y - translation.height
                ),
                panelSize: panel.frame.size,
                visibleFrame: visibleFrame
            )
        )
    }

    private func finishDrag() {
        guard let panel, dragOrigin != nil else { return }
        dragOrigin = nil
        center.setDragging(false)
        savePlacement(panel: panel)
    }

    private func savePlacement(panel: ActionFeedbackPanel) {
        guard let screen = panel.screen,
              let displayID = screen.actionFeedbackDisplayID
        else { return }
        let normalized = ActionFeedbackLayout.normalizedOrigin(
            origin: panel.frame.origin,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        placementStore.save(
            ActionFeedbackPlacement(
                normalizedX: Double(normalized.x),
                normalizedY: Double(normalized.y)
            ),
            displayID: displayID
        )
        AppLogger.shared.write(
            "ACTION FEEDBACK placement phase=saved " +
                "x=\(Int(panel.frame.origin.x)) y=\(Int(panel.frame.origin.y)) " +
                "width=\(Int(panel.frame.width)) height=\(Int(panel.frame.height))"
        )
    }
}

/// 不接受键盘焦点的无边框面板。按钮仍能接收鼠标点击，但不会把前台 App 的
/// 输入焦点抢走。
private final class ActionFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 只使用公开的窗口几何信息选择屏幕，不读取窗口标题、内容或第三方 App 状态。
enum ActionFeedbackScreenResolver {
    static func preferredScreen(
        frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        windowInfo: [[String: Any]]? = nil,
        screens: [NSScreen] = NSScreen.screens,
        mainScreen: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        let fallback = mainScreen ?? screens.first
        guard let frontmostPID, !screens.isEmpty else { return fallback }
        let windows = windowInfo ?? (
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        )
        let displayFrames: [(screen: NSScreen, frame: CGRect)] = screens.map { screen in
            let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID
            let frame = displayID.map(CGDisplayBounds)
                ?? CGRect(
                    x: screen.frame.minX,
                    y: (mainScreen?.frame.maxY ?? 0) - screen.frame.maxY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            return (screen, frame)
        }
        var best: (screen: NSScreen, area: CGFloat)?
        for window in windows {
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == frontmostPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1
            else { continue }
            for entry in displayFrames {
                let area = entry.frame.intersection(frame).area
                if area > (best?.area ?? 0) {
                    best = (entry.screen, area)
                }
            }
        }
        return best?.screen ?? fallback
    }

    /// 同一坐标系下的屏幕命中测试，供单测覆盖多屏选择。
    static func bestScreenIndex(
        windowFrame: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in screenFrames.enumerated() {
            let area = frame.intersection(windowFrame).area
            if area > (best?.area ?? 0) {
                best = (index, area)
            }
        }
        guard let best, best.area > 0 else { return nil }
        return best.index
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
