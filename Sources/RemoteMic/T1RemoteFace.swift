import SwiftUI

/// Geometry is normalized to the shared remote illustration frame.
enum T1RemoteFaceLayout {
    static let voice = UnitPoint(x: 0.655, y: 0.303)
    static let voiceCardY: CGFloat = 0.64

    static let placements: [RemoteMappingPlacement] = [
        .init(button: .power, side: .right, anchor: UnitPoint(x: 0.685, y: 0.056), targetY: 0.08),
        .init(button: .up, side: .left, anchor: UnitPoint(x: 0.5, y: 0.091), targetY: 0.09),
        .init(button: .left, side: .left, anchor: UnitPoint(x: 0.342, y: 0.169), targetY: 0.25),
        .init(button: .ok, side: .left, anchor: UnitPoint(x: 0.5, y: 0.169), targetY: 0.41),
        .init(button: .right, side: .right, anchor: UnitPoint(x: 0.658, y: 0.169), targetY: 0.36),
        .init(button: .down, side: .left, anchor: UnitPoint(x: 0.5, y: 0.247), targetY: 0.57),
        .init(button: .volumeUp, side: .right, anchor: UnitPoint(x: 0.817, y: 0.139), targetY: 0.22),
        .init(button: .volumeDown, side: .right, anchor: UnitPoint(x: 0.817, y: 0.207), targetY: 0.50),
        .init(button: .back, side: .left, anchor: UnitPoint(x: 0.345, y: 0.303), targetY: 0.73),
        .init(button: .mute, side: .left, anchor: UnitPoint(x: 0.345, y: 0.402), targetY: 0.89),
        .init(button: .home, side: .right, anchor: UnitPoint(x: 0.655, y: 0.409), targetY: 0.78),
        .init(button: .menu, side: .right, anchor: UnitPoint(x: 0.655, y: 0.515), targetY: 0.92),
    ]
}

struct T1RemoteFace: View {
    @EnvironmentObject private var localization: LocalizationStore

    let selectedButton: RemoteButton?
    let activeButtons: Set<RemoteButton>
    let reservedButtons: Set<RemoteButton>
    let voiceActive: Bool
    let onEdit: (RemoteButton) -> Void
    let onVoice: () -> Void

    static func preview(height: CGFloat) -> some View {
        let size = RemoteMappingLayout.remoteSize
        let scale = height / size.height
        return Self(
            selectedButton: nil, activeButtons: [], reservedButtons: [],
            voiceActive: false, onEdit: { _ in }, onVoice: {}
        )
        .frame(width: size.width, height: size.height)
        .scaleEffect(scale)
        .frame(width: size.width * scale, height: height)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("remote.device.model.t1"))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 19)
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.9), Color(white: 0.48), Color(white: 0.83)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 17)
                            .fill(LinearGradient(
                                colors: [Color(white: 0.16), Color(white: 0.075)],
                                startPoint: .top, endPoint: .bottomTrailing
                            ))
                            .padding(3)
                    }
                    .frame(width: size.width * 0.636, height: size.height - 4)
                    .position(x: size.width / 2, y: size.height / 2)
                    .accessibilityHidden(true)

                Circle()
                    .fill(Color(white: 0.35))
                    .frame(width: 3, height: 3)
                    .position(point(UnitPoint(x: 0.5, y: 0.048), in: size))
                    .accessibilityHidden(true)

                directionRing
                    .frame(width: size.width * 0.44, height: size.width * 0.44)
                    .position(point(UnitPoint(x: 0.5, y: 0.169), in: size))

                // The two printed controls on the left share one elongated cap.
                Capsule()
                    .fill(Color(white: 0.105))
                    .overlay { Capsule().strokeBorder(Color(white: 0.24), lineWidth: 1) }
                    .frame(width: 42, height: 102)
                    .position(point(UnitPoint(x: 0.345, y: 0.45), in: size))
                    .accessibilityHidden(true)

                Image(systemName: "computermouse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 32, height: 32)
                    .position(point(UnitPoint(x: 0.345, y: 0.497), in: size))
                    .accessibilityLabel(Text("button_mapping.t1.air_mouse"))

                Capsule()
                    .fill(Color(white: 0.095))
                    .overlay { Capsule().strokeBorder(Color(white: 0.40), lineWidth: 1) }
                    .frame(width: 11, height: size.height * 0.128)
                    .position(point(UnitPoint(x: 0.817, y: 0.173), in: size))
                    .accessibilityHidden(true)

                ForEach(T1RemoteFaceLayout.placements) { placement in
                    key(placement.button)
                        .position(point(placement.anchor, in: size))
                }

                Button(action: onVoice) {
                    ZStack {
                        Circle().fill(Color(white: 0.11))
                        Circle().strokeBorder(keyBorder(active: voiceActive, selected: false), lineWidth: 1)
                        ZStack {
                            Circle().frame(width: 9).offset(x: -4, y: -3)
                            Circle().frame(width: 4).offset(x: 5, y: 2)
                            Circle().frame(width: 3).offset(x: 8, y: -2)
                            Circle().frame(width: 5).offset(x: 1, y: 6)
                        }
                        .foregroundStyle(.white.opacity(0.92))
                    }
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .position(point(T1RemoteFaceLayout.voice, in: size))
                .accessibilityLabel(Text("button_mapping.voice_button.title"))
            }
        }
    }

    private var directionRing: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(Color(white: 0.28), lineWidth: 1)
            Circle()
                .fill(Color(white: 0.115))
                .overlay { Circle().strokeBorder(Color(white: 0.06), lineWidth: 1) }
                .padding(22)
        }
        .accessibilityHidden(true)
    }

    private func key(_ button: RemoteButton) -> some View {
        let sideKey = button == .volumeUp || button == .volumeDown
        let pillKey = button == .mute
        let keySize: CGFloat = button.isDirectional ? 24 : button == .power ? 26 : 42
        let active = activeButtons.contains(button)
        let selected = selectedButton == button
        let reserved = reservedButtons.contains(button)
        return Button {
            onEdit(button)
        } label: {
            ZStack {
                if !sideKey && !pillKey && !button.isDirectional {
                    Circle().fill(Color(white: 0.11))
                    Circle().strokeBorder(keyBorder(active: active, selected: selected), lineWidth: 1)
                } else if active || selected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill((active ? Color.orange : Color.accentColor).opacity(0.25))
                }
                Image(systemName: symbol(for: button))
                    .font(.system(size: sideKey ? 8 : button.isDirectional ? 10 : 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: sideKey ? 17 : keySize, height: sideKey ? 26 : keySize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reserved)
        .accessibilityLabel(Text(button.displayName(using: localization)))
        .help(button.displayName(using: localization))
    }

    private func symbol(for button: RemoteButton) -> String {
        switch button {
        case .back: return "arrow.left"
        case .volumeUp: return "plus"
        case .volumeDown: return "minus"
        default: return button.systemImage
        }
    }

    private func keyBorder(active: Bool, selected: Bool) -> Color {
        if active { return .orange }
        if selected { return .accentColor }
        return Color(white: 0.24)
    }

    private func point(_ anchor: UnitPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
    }
}
