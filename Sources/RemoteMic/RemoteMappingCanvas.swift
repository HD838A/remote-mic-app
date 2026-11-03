import AppKit
import SwiftUI

enum RemoteMappingSide: Equatable {
    case left
    case right
}

/// 画布按键卡的共享视觉规格。
///
/// 三种遥控器的画布由三份代码绘制：宿主的小米画布、私有包的 Siri 与 Chromecast 画布。
/// 按住胶囊以前各自写死样式——2026-10-31 只把宿主侧改成与三个动作格子一致的灰底，
/// 另外两处仍是浅橙底，于是同一页面切到不同遥控器，「按住」长得不一样。
/// 规格集中在这里，私有画布必须按 `Testing/HardwareCompatibilityContract.md`
/// 的「按键设置页共享合同」给出同样的数值，不得各自另写一套。
enum RemoteMappingCardChrome {
    enum HoldChip {
        static let fontSize: CGFloat = 12
        static let fontWeight = Font.Weight.semibold
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 2
        static let cornerRadius: CGFloat = 5
        /// 与单击/双击/长按三个动作格子同底：中性灰，不用强调色。
        static let background = AnyShapeStyle(.quaternary)
    }
}

struct RemoteMappingPlacement: Identifiable {
    let button: RemoteButton
    let side: RemoteMappingSide
    let anchor: UnitPoint
    let targetY: CGFloat

    var id: RemoteButton { button }
}

enum RemoteMappingLayout {
    static let canvasHeight: CGFloat = 570
    static let remoteSize = CGSize(width: 251, height: 510)
    static let arrowCardGap: CGFloat = 7

    static let buttonPlacements: [RemoteMappingPlacement] = [
        RemoteMappingPlacement(button: .power, side: .left, anchor: UnitPoint(x: 0.386, y: 0.099), targetY: 0.08),
        RemoteMappingPlacement(button: .up, side: .left, anchor: UnitPoint(x: 0.502, y: 0.179), targetY: 0.23),
        RemoteMappingPlacement(button: .left, side: .left, anchor: UnitPoint(x: 0.362, y: 0.246), targetY: 0.38),
        RemoteMappingPlacement(button: .back, side: .left, anchor: UnitPoint(x: 0.406, y: 0.389), targetY: 0.53),
        RemoteMappingPlacement(button: .home, side: .left, anchor: UnitPoint(x: 0.406, y: 0.479), targetY: 0.68),
        RemoteMappingPlacement(button: .menu, side: .left, anchor: UnitPoint(x: 0.406, y: 0.569), targetY: 0.83),
        RemoteMappingPlacement(button: .right, side: .right, anchor: UnitPoint(x: 0.638, y: 0.246), targetY: 0.215),
        RemoteMappingPlacement(button: .ok, side: .right, anchor: UnitPoint(x: 0.502, y: 0.246), targetY: 0.36),
        RemoteMappingPlacement(button: .down, side: .right, anchor: UnitPoint(x: 0.502, y: 0.317), targetY: 0.505),
        RemoteMappingPlacement(button: .volumeUp, side: .right, anchor: UnitPoint(x: 0.604, y: 0.390), targetY: 0.65),
        RemoteMappingPlacement(button: .volumeDown, side: .right, anchor: UnitPoint(x: 0.604, y: 0.480), targetY: 0.795),
        RemoteMappingPlacement(button: .tv, side: .right, anchor: UnitPoint(x: 0.604, y: 0.569), targetY: 0.94),
    ]

    static let voiceAnchor = UnitPoint(x: 0.630, y: 0.099)
    static let voiceTargetY: CGFloat = 0.07

    static func remotePoint(for anchor: UnitPoint, canvasWidth: CGFloat) -> CGPoint {
        let remoteOrigin = CGPoint(
            x: canvasWidth / 2 - remoteSize.width / 2,
            y: (canvasHeight - remoteSize.height) / 2
        )
        return CGPoint(
            x: remoteOrigin.x + remoteSize.width * anchor.x,
            y: remoteOrigin.y + remoteSize.height * anchor.y
        )
    }

    static func cardEdgePoint(
        side: RemoteMappingSide,
        targetY: CGFloat,
        canvasWidth: CGFloat,
        cardWidth: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: side == .left ? cardWidth : canvasWidth - cardWidth,
            y: canvasHeight * targetY
        )
    }

    static func cardWidth(for canvasWidth: CGFloat) -> CGFloat {
        min(300, max(270, (canvasWidth - 260) / 2))
    }

    static func connectionControlPoints(
        start: CGPoint,
        end: CGPoint,
        side: RemoteMappingSide
    ) -> (start: CGPoint, end: CGPoint) {
        let direction: CGFloat = side == .left ? -1 : 1
        let distance = min(70, max(34, abs(end.x - start.x) * 0.58))
        let endpointDistance = min(42, max(24, distance * 0.6))
        return (
            CGPoint(x: start.x + direction * distance, y: start.y),
            CGPoint(x: end.x - direction * endpointDistance, y: end.y)
        )
    }

    static func arrowTip(cardEdge: CGPoint, side: RemoteMappingSide) -> CGPoint {
        let direction: CGFloat = side == .left ? -1 : 1
        return CGPoint(
            x: cardEdge.x - direction * arrowCardGap,
            y: cardEdge.y
        )
    }
}

struct RemoteMappingCanvas: View {
    @EnvironmentObject private var localization: LocalizationStore

    @Binding var selectedButton: RemoteButton
    let activeButtons: Set<RemoteButton>
    let voiceActive: Bool
    let actionSummary: (RemoteButton, ButtonTrigger) -> String
    let holdSummary: (RemoteButton) -> String
    /// 悬停时显示的完整形态（例如 `⌘ Command + ⇧ Shift + H`）；卡片正文用 `actionSummary`。
    var actionDetail: ((RemoteButton, ButtonTrigger) -> String)? = nil
    let onEdit: (RemoteButton, ButtonTrigger) -> Void
    let onEditHold: (RemoteButton) -> Void
    var onVoiceSettings: () -> Void = {}
    /// 方案作用域只覆盖 10 个普通按键；不在范围内的按键置灰且不可点。
    var reservedButtons: Set<RemoteButton> = []

    var body: some View {
        GeometryReader { geometry in
            let metrics = Metrics(width: geometry.size.width)
            ZStack {
                MappingRemotePhoto()
                    .frame(
                        width: RemoteMappingLayout.remoteSize.width,
                        height: RemoteMappingLayout.remoteSize.height
                    )
                    .position(x: metrics.remoteCenterX, y: RemoteMappingLayout.canvasHeight / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                connectionLines(metrics: metrics)

                ForEach(RemoteMappingLayout.buttonPlacements) { placement in
                    mappingCard(placement.button)
                        .frame(width: metrics.cardWidth, height: metrics.cardHeight)
                        .position(
                            x: metrics.cardCenterX(for: placement.side),
                            y: RemoteMappingLayout.canvasHeight * placement.targetY
                        )
                }

                voiceCard
                    .frame(width: metrics.cardWidth, height: metrics.cardHeight)
                    .position(
                        x: metrics.cardCenterX(for: .right),
                        y: RemoteMappingLayout.canvasHeight * RemoteMappingLayout.voiceTargetY
                    )
            }
        }
        .frame(height: RemoteMappingLayout.canvasHeight)
    }

    private func connectionLines(metrics: Metrics) -> some View {
        Canvas { context, _ in
            for placement in RemoteMappingLayout.buttonPlacements {
                drawConnection(
                    context: &context,
                    start: metrics.remotePoint(for: placement.anchor),
                    end: metrics.cardEdgePoint(side: placement.side, targetY: placement.targetY),
                    side: placement.side,
                    selected: selectedButton == placement.button,
                    showsAnchor: activeButtons.contains(placement.button)
                )
            }
            drawConnection(
                context: &context,
                start: metrics.remotePoint(for: RemoteMappingLayout.voiceAnchor),
                end: metrics.cardEdgePoint(side: .right, targetY: RemoteMappingLayout.voiceTargetY),
                side: .right,
                selected: voiceActive,
                showsAnchor: voiceActive
            )
        }
        .allowsHitTesting(false)
    }

    private func drawConnection(
        context: inout GraphicsContext,
        start: CGPoint,
        end: CGPoint,
        side: RemoteMappingSide,
        selected: Bool,
        showsAnchor: Bool
    ) {
        let arrowTip = RemoteMappingLayout.arrowTip(cardEdge: end, side: side)
        let controls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: arrowTip,
            side: side
        )
        var path = Path()
        path.move(to: start)
        path.addCurve(to: arrowTip, control1: controls.start, control2: controls.end)

        let color = selected ? Color.accentColor : Color.secondary.opacity(0.42)
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: selected ? 1.6 : 1.0,
                lineCap: .round,
                lineJoin: .round
            )
        )
        if showsAnchor {
            context.fill(
                Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)),
                with: .color(Color.orange)
            )
        }

        let direction: CGFloat = side == .left ? -1 : 1
        var arrow = Path()
        arrow.move(to: arrowTip)
        arrow.addLine(to: CGPoint(x: arrowTip.x - direction * 6, y: arrowTip.y - 4))
        arrow.addLine(to: CGPoint(x: arrowTip.x - direction * 6, y: arrowTip.y + 4))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    /// 卡片正文是紧凑形态，完整形态只在悬停时出现。
    private func actionHelp(button: RemoteButton, trigger: ButtonTrigger) -> String {
        let prefix =
            "\(button.displayName(using: localization)) · \(trigger.displayName(using: localization))"
        guard let detail = actionDetail?(button, trigger), !detail.isEmpty else { return prefix }
        return "\(prefix) — \(detail)"
    }

    private func mappingCard(_ button: RemoteButton) -> some View {
        let selected = selectedButton == button
        let active = activeButtons.contains(button)
        let reserved = reservedButtons.contains(button)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: button.systemImage)
                    .frame(width: 14)
                Text(button.displayName(using: localization))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    selectedButton = button
                    onEditHold(button)
                } label: {
                    Text(holdSummary(button))
                        .font(.system(
                            size: RemoteMappingCardChrome.HoldChip.fontSize,
                            weight: RemoteMappingCardChrome.HoldChip.fontWeight
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, RemoteMappingCardChrome.HoldChip.horizontalPadding)
                        .padding(.vertical, RemoteMappingCardChrome.HoldChip.verticalPadding)
                        .background(
                            RemoteMappingCardChrome.HoldChip.background,
                            in: RoundedRectangle(
                                cornerRadius: RemoteMappingCardChrome.HoldChip.cornerRadius
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("\(button.displayName(using: localization)) · \(holdSummary(button))")
            }

            HStack(spacing: 4) {
                ForEach(ButtonTrigger.allCases) { trigger in
                    Button {
                        selectedButton = button
                        onEdit(button, trigger)
                    } label: {
                        VStack(spacing: 1) {
                            Text(trigger.displayName(using: localization))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(actionSummary(button, trigger))
                                .font(.system(size: 12, weight: trigger == .singleClick ? .semibold : .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(actionHelp(button: button, trigger: trigger))
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { selectedButton = button }
        .background(
            active
                ? Color.orange.opacity(0.12)
                : selected
                    ? Color.accentColor.opacity(0.10)
                    : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    active
                        ? Color.orange.opacity(0.65)
                        : selected
                            ? Color.accentColor.opacity(0.45)
                            : Color.secondary.opacity(0.15)
                )
        }
        .opacity(reserved ? 0.5 : 1)
        .allowsHitTesting(!reserved)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(button.displayName(using: localization)))
    }

    private var voiceCard: some View {
        Button(action: onVoiceSettings) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .frame(width: 14)
                    Text("button_mapping.voice_button.title")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("button_mapping.voice_button.fixed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(voiceActive ? Color.orange : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (voiceActive ? Color.orange : Color.secondary).opacity(0.12),
                            in: Capsule()
                        )
                }
                Text("button_mapping.voice_button.detail")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                voiceActive ? Color.orange.opacity(0.12) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(voiceActive ? Color.orange.opacity(0.65) : Color.secondary.opacity(0.15))
            }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    private struct Metrics {
        let width: CGFloat
        let cardWidth: CGFloat
        let cardHeight: CGFloat = 72

        init(width: CGFloat) {
            self.width = width
            cardWidth = RemoteMappingLayout.cardWidth(for: width)
        }

        var remoteCenterX: CGFloat { width / 2 }

        func cardCenterX(for side: RemoteMappingSide) -> CGFloat {
            side == .left ? cardWidth / 2 : width - cardWidth / 2
        }

        func cardEdgePoint(side: RemoteMappingSide, targetY: CGFloat) -> CGPoint {
            RemoteMappingLayout.cardEdgePoint(
                side: side,
                targetY: targetY,
                canvasWidth: width,
                cardWidth: cardWidth
            )
        }

        func remotePoint(for anchor: UnitPoint) -> CGPoint {
            RemoteMappingLayout.remotePoint(
                for: anchor,
                canvasWidth: width
            )
        }
    }
}

private enum MappingRemoteImageResource {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "RC003-remote-photo",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()
}

private struct MappingRemotePhoto: View {
    var body: some View {
        Group {
            if let photo = MappingRemoteImageResource.image {
                Image(nsImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Text("remote.photo.missing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}
