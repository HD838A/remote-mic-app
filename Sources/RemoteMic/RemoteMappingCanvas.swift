import AppKit
import SwiftUI

enum RemoteMappingSide {
    case left
    case right
}

struct RemoteMappingPlacement: Identifiable {
    let button: RemoteButton
    let side: RemoteMappingSide
    let anchor: UnitPoint
    let targetY: CGFloat

    var id: RemoteButton { button }
}

enum RemoteMappingLayout {
    static let canvasHeight: CGFloat = 430
    static let remoteSize = CGSize(width: 174, height: 352)

    static let buttonPlacements: [RemoteMappingPlacement] = [
        RemoteMappingPlacement(button: .power, side: .left, anchor: UnitPoint(x: 0.386, y: 0.099), targetY: 0.08),
        RemoteMappingPlacement(button: .up, side: .left, anchor: UnitPoint(x: 0.502, y: 0.179), targetY: 0.23),
        RemoteMappingPlacement(button: .left, side: .left, anchor: UnitPoint(x: 0.362, y: 0.246), targetY: 0.38),
        RemoteMappingPlacement(button: .ok, side: .left, anchor: UnitPoint(x: 0.502, y: 0.246), targetY: 0.53),
        RemoteMappingPlacement(button: .down, side: .left, anchor: UnitPoint(x: 0.502, y: 0.317), targetY: 0.68),
        RemoteMappingPlacement(button: .back, side: .left, anchor: UnitPoint(x: 0.406, y: 0.389), targetY: 0.83),
        RemoteMappingPlacement(button: .right, side: .right, anchor: UnitPoint(x: 0.638, y: 0.246), targetY: 0.215),
        RemoteMappingPlacement(button: .volumeUp, side: .right, anchor: UnitPoint(x: 0.604, y: 0.390), targetY: 0.36),
        RemoteMappingPlacement(button: .home, side: .right, anchor: UnitPoint(x: 0.406, y: 0.479), targetY: 0.505),
        RemoteMappingPlacement(button: .volumeDown, side: .right, anchor: UnitPoint(x: 0.604, y: 0.480), targetY: 0.65),
        RemoteMappingPlacement(button: .menu, side: .right, anchor: UnitPoint(x: 0.406, y: 0.569), targetY: 0.795),
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
}

struct RemoteMappingCanvas: View {
    @EnvironmentObject private var localization: LocalizationStore

    @Binding var selectedButton: RemoteButton
    let activeButtons: Set<RemoteButton>
    let voiceActive: Bool
    let actionSummary: (RemoteButton, ButtonTrigger) -> String
    let onEdit: (RemoteButton, ButtonTrigger) -> Void

    var body: some View {
        GeometryReader { geometry in
            let metrics = Metrics(width: geometry.size.width)
            ZStack {
                connectionLines(metrics: metrics)

                MappingRemotePhoto()
                    .frame(
                        width: RemoteMappingLayout.remoteSize.width,
                        height: RemoteMappingLayout.remoteSize.height
                    )
                    .position(x: metrics.remoteCenterX, y: RemoteMappingLayout.canvasHeight / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

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
                    selected: selectedButton == placement.button
                )
            }
            drawConnection(
                context: &context,
                start: metrics.remotePoint(for: RemoteMappingLayout.voiceAnchor),
                end: metrics.cardEdgePoint(side: .right, targetY: RemoteMappingLayout.voiceTargetY),
                side: .right,
                selected: voiceActive
            )
        }
        .allowsHitTesting(false)
    }

    private func drawConnection(
        context: inout GraphicsContext,
        start: CGPoint,
        end: CGPoint,
        side: RemoteMappingSide,
        selected: Bool
    ) {
        let elbowX = start.x + (side == .left ? -28 : 28)
        var path = Path()
        path.move(to: start)
        path.addLine(to: CGPoint(x: elbowX, y: start.y))
        path.addLine(to: CGPoint(x: elbowX, y: end.y))
        path.addLine(to: end)

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
        context.fill(
            Path(ellipseIn: CGRect(x: start.x - 2.5, y: start.y - 2.5, width: 5, height: 5)),
            with: .color(color)
        )

        let direction: CGFloat = side == .left ? -1 : 1
        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - direction * 6, y: end.y - 4))
        arrow.addLine(to: CGPoint(x: end.x - direction * 6, y: end.y + 4))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    private func mappingCard(_ button: RemoteButton) -> some View {
        let selected = selectedButton == button
        let active = activeButtons.contains(button)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol(for: button))
                    .frame(width: 14)
                Text(button.displayName(using: localization))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                ForEach(ButtonTrigger.allCases) { trigger in
                    Button {
                        selectedButton = button
                        onEdit(button, trigger)
                    } label: {
                        VStack(spacing: 1) {
                            Text(trigger.displayName(using: localization))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(actionSummary(button, trigger))
                                .font(.system(size: 9, weight: trigger == .singleClick ? .semibold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(
                        "\(button.displayName(using: localization)) · \(trigger.displayName(using: localization))"
                    )
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(button.displayName(using: localization)))
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .frame(width: 14)
                Text("button_mapping.voice_button.title")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("button_mapping.voice_button.fixed")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(voiceActive ? Color.orange : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (voiceActive ? Color.orange : Color.secondary).opacity(0.12),
                        in: Capsule()
                    )
            }
            Text("button_mapping.voice_button.detail")
                .font(.system(size: 9))
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

    private func symbol(for button: RemoteButton) -> String {
        switch button {
        case .power: return "power"
        case .up: return "chevron.up"
        case .left: return "chevron.left"
        case .ok: return "circle.circle"
        case .right: return "chevron.right"
        case .down: return "chevron.down"
        case .back: return "arrow.uturn.backward"
        case .volumeUp: return "speaker.plus"
        case .home: return "house"
        case .volumeDown: return "speaker.minus"
        case .menu: return "line.3.horizontal"
        case .tv: return "tv"
        }
    }

    private struct Metrics {
        let width: CGFloat
        let cardWidth: CGFloat
        let cardHeight: CGFloat = 54

        init(width: CGFloat) {
            self.width = width
            cardWidth = min(250, max(218, (width - 270) / 2))
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
