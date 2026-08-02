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

                directionButton(symbol: "chevron.up", command: .up)
                    .offset(y: -directionalOffset)
                directionButton(symbol: "chevron.down", command: .down)
                    .offset(y: directionalOffset)
                directionButton(symbol: "chevron.left", command: .left)
                    .offset(x: -directionalOffset)
                directionButton(symbol: "chevron.right", command: .right)
                    .offset(x: directionalOffset)

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

    private func directionButton(symbol: String, command: RemoteCommand) -> some View {
        Button {
            perform(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 68, height: 68)
                .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityLabel(accessibilityLabel(for: command))
    }

    private func accessibilityLabel(for command: RemoteCommand) -> String {
        switch command {
        case .up: "向上"
        case .down: "向下"
        case .left: "向左"
        case .right: "向右"
        default: "方向"
        }
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
        ZStack {
            AppIconRoundedRectangle()
                .fill(
                    LinearGradient(
                        colors: isActive
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
                Image(systemName: isActive ? "waveform" : "mic.fill")
                    .font(.system(size: 45, weight: .medium))
                Text(isActive ? "正在说话" : "按住说话")
                    .font(.system(size: 24, weight: .bold))
                Text(isActive ? "松手停止" : "松手停止")
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(isActive ? 0.11 : 0.18), radius: isActive ? 2 : 5, x: 0, y: isActive ? 1 : 4)
        .scaleEffect(isActive ? 0.98 : 1)
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
        .animation(.easeOut(duration: 0.1), value: isActive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("按住说话")
        .accessibilityValue(isActive ? "正在录音" : "未录音")
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
