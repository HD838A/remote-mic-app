import SwiftUI

enum RemotePalette {
    static let backgroundTop = Color(red: 0.965, green: 0.968, blue: 0.974)
    static let backgroundBottom = Color(red: 0.91, green: 0.92, blue: 0.935)
    static let graphiteTop = Color(red: 0.35, green: 0.37, blue: 0.40)
    static let graphiteBottom = Color(red: 0.25, green: 0.27, blue: 0.30)
    static let graphiteEdge = Color.black.opacity(0.36)
    static let blueTop = Color(red: 0.27, green: 0.50, blue: 0.76)
    static let blueBottom = Color(red: 0.12, green: 0.35, blue: 0.63)
    static let lightTop = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let lightBottom = Color(red: 0.77, green: 0.79, blue: 0.82)
    static let text = Color(red: 0.18, green: 0.19, blue: 0.21)
}

struct RemoteBackground: View {
    var body: some View {
        LinearGradient(
            colors: [RemotePalette.backgroundTop, RemotePalette.backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            LinearGradient(
                colors: [.white.opacity(0.34), .clear, .black.opacity(0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? -0.045 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct AppIconRoundedRectangle: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: min(rect.width, rect.height) * 0.2237,
            style: .continuous
        )
        .path(in: rect)
    }
}

struct GraphiteSurface<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            AppIconRoundedRectangle()
                .fill(
                    LinearGradient(
                        colors: [RemotePalette.graphiteTop, RemotePalette.graphiteBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            AppIconRoundedRectangle()
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                .padding(1)
            AppIconRoundedRectangle()
                .stroke(RemotePalette.graphiteEdge, lineWidth: 1.5)
            content
        }
        .shadow(color: .black.opacity(0.19), radius: 4, x: 0, y: 3)
    }
}

struct LightSurface<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            AppIconRoundedRectangle()
                .fill(
                    LinearGradient(
                        colors: [RemotePalette.lightTop, RemotePalette.lightBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            AppIconRoundedRectangle()
                .stroke(Color.white.opacity(0.75), lineWidth: 1)
                .padding(1)
            AppIconRoundedRectangle()
                .stroke(Color.black.opacity(0.23), lineWidth: 1.3)
            content
        }
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 3)
    }
}

struct DPadView: View {
    let perform: (RemoteCommand) -> Void

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let directionalOffset = diameter * 0.29

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [RemotePalette.graphiteTop, RemotePalette.graphiteBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        DPadDividers()
                            .stroke(Color.black.opacity(0.52), lineWidth: 1.5)
                            .padding(diameter * 0.025)
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                            .padding(2)
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.black.opacity(0.42), lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 7, x: 0, y: 5)

                DPadDirectionControl(
                    symbol: "chevron.up",
                    direction: .up,
                    directionalOffset: directionalOffset
                ) {
                    perform(.up)
                }
                DPadDirectionControl(
                    symbol: "chevron.down",
                    direction: .down,
                    directionalOffset: directionalOffset
                ) {
                    perform(.down)
                }
                DPadDirectionControl(
                    symbol: "chevron.left",
                    direction: .left,
                    directionalOffset: directionalOffset
                ) {
                    perform(.left)
                }
                DPadDirectionControl(
                    symbol: "chevron.right",
                    direction: .right,
                    directionalOffset: directionalOffset
                ) {
                    perform(.right)
                }

                Button {
                    perform(.confirm)
                } label: {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.11), Color.black.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            Circle()
                                .stroke(Color.black.opacity(0.58), lineWidth: 1.5)
                        }
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                .padding(2)
                        }
                        .frame(width: diameter * 0.39, height: diameter * 0.39)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("确定")
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

}

private enum DPadDirection {
    case up
    case down
    case left
    case right

    var accessibilityLabel: String {
        switch self {
        case .up: return "向上"
        case .down: return "向下"
        case .left: return "向左"
        case .right: return "向右"
        }
    }

    func iconOffset(distance: CGFloat) -> CGSize {
        switch self {
        case .up: return CGSize(width: 0, height: -distance)
        case .down: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        }
    }

    var startAngle: Double {
        switch self {
        case .up: return 225
        case .right: return 315
        case .down: return 45
        case .left: return 135
        }
    }
}

private struct DPadDirectionControl: View {
    let symbol: String
    let direction: DPadDirection
    let directionalOffset: CGFloat
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        let iconOffset = direction.iconOffset(distance: directionalOffset)

        ZStack {
            DPadSectorShape(direction: direction)
                .fill(Color.black.opacity(isPressed ? 0.13 : 0))

            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(isPressed ? 0.88 : 0.94))
                .offset(
                    x: iconOffset.width,
                    y: iconOffset.height + (isPressed ? 2 : 0)
                )
        }
        .contentShape(DPadSectorShape(direction: direction))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    action()
                }
                .onEnded { _ in
                    isPressed = false
                }
        )
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(direction.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            action()
        }
    }
}

private struct DPadSectorShape: Shape {
    let direction: DPadDirection

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let innerRadius = min(rect.width, rect.height) * 0.195
        let startAngle = direction.startAngle
        let endAngle = startAngle + 90
        let startRadians = startAngle * .pi / 180
        let endRadians = endAngle * .pi / 180
        let outerStart = CGPoint(
            x: center.x + cos(startRadians) * radius,
            y: center.y + sin(startRadians) * radius
        )
        let innerEnd = CGPoint(
            x: center.x + cos(endRadians) * innerRadius,
            y: center.y + sin(endRadians) * innerRadius
        )

        var path = Path()
        path.move(to: outerStart)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        path.addLine(to: innerEnd)
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .degrees(endAngle),
            endAngle: .degrees(startAngle),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

private struct DPadDividers: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let innerRadius = rect.width * 0.195
        let outerRadius = rect.width * 0.49

        for degrees in [45.0, 135.0, 225.0, 315.0] {
            let radians = degrees * .pi / 180
            path.move(to: CGPoint(
                x: center.x + cos(radians) * innerRadius,
                y: center.y + sin(radians) * innerRadius
            ))
            path.addLine(to: CGPoint(
                x: center.x + cos(radians) * outerRadius,
                y: center.y + sin(radians) * outerRadius
            ))
        }
        return path
    }
}

struct MiddleControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GraphiteSurface {
                Image(systemName: systemImage)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityLabel(title)
    }
}

struct VoiceButton: View {
    let isActive: Bool
    let onPressChanged: (Bool) -> Void

    @State private var isTrackingPress = false

    var body: some View {
        let visualActive = isActive || isTrackingPress

        ZStack {
            AppIconRoundedRectangle()
                .fill(
                    LinearGradient(
                        colors: visualActive
                            ? [Color(red: 0.23, green: 0.58, blue: 0.83), Color(red: 0.09, green: 0.37, blue: 0.68)]
                            : [RemotePalette.blueTop, RemotePalette.blueBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            AppIconRoundedRectangle()
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
                .padding(1)
            AppIconRoundedRectangle()
                .stroke(Color.black.opacity(0.25), lineWidth: 1.4)

            VStack(spacing: 10) {
                Image(systemName: visualActive ? "waveform" : "mic.fill")
                    .font(.system(size: 45, weight: .medium))
                Text(visualActive ? "正在说话" : "按住说话")
                    .font(.system(size: 24, weight: .bold))
                Text("松手停止")
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(visualActive ? 0.11 : 0.18), radius: visualActive ? 2 : 5, x: 0, y: visualActive ? 1 : 4)
        .scaleEffect(visualActive ? 0.98 : 1)
        .contentShape(AppIconRoundedRectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isTrackingPress else { return }
                    isTrackingPress = true
                    onPressChanged(true)
                }
                .onEnded { _ in
                    guard isTrackingPress else { return }
                    isTrackingPress = false
                    onPressChanged(false)
                }
        )
        .animation(.easeOut(duration: 0.1), value: visualActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("按住说话")
        .accessibilityValue(isActive ? "正在录音" : isTrackingPress ? "正在准备" : "未录音")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onPressChanged(!isActive)
        }
    }
}

struct ConfirmButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LightSurface {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 45, weight: .semibold))
                    Text("确定")
                        .font(.system(size: 25, weight: .bold))
                    Text("Return")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.78)
                }
                .foregroundStyle(RemotePalette.text)
            }
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityLabel("确定，Return")
    }
}
