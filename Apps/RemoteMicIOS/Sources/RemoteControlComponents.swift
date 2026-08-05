import SwiftUI

extension View {
    @ViewBuilder
    func remoteOnChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

enum RemotePalette {
    static let backgroundTop = Color(red: 0.84, green: 0.85, blue: 0.86)
    static let backgroundBottom = Color(red: 0.69, green: 0.71, blue: 0.73)
    static let graphiteTop = Color(red: 0.35, green: 0.37, blue: 0.40)
    static let graphiteBottom = Color(red: 0.25, green: 0.27, blue: 0.30)
    static let graphiteEdge = Color.black.opacity(0.36)
    static let voiceTop = Color(red: 0.34, green: 0.41, blue: 0.44)
    static let voiceBottom = Color(red: 0.21, green: 0.28, blue: 0.31)
    static let voiceActiveTop = Color(red: 0.42, green: 0.52, blue: 0.53)
    static let voiceActiveBottom = Color(red: 0.25, green: 0.35, blue: 0.36)
    static let lightTop = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let lightBottom = Color(red: 0.77, green: 0.79, blue: 0.82)
    static let text = Color(red: 0.18, green: 0.19, blue: 0.21)
}

struct RemoteBackground: View {
    var body: some View {
        GeometryReader { proxy in
            Image("AluminumBackground")
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.08), .clear, .black.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .ignoresSafeArea()
    }
}

struct TactileButtonStyle: ButtonStyle {
    var showsPressedVisuals = true
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(showsPressedVisuals && configuration.isPressed ? 0.975 : 1)
            .brightness(showsPressedVisuals && configuration.isPressed ? -0.045 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .remoteOnChange(of: configuration.isPressed) { isPressed in
                onPressChanged?(isPressed)
            }
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
    let onButtonStateChanged: (RemoteCommand, Bool) -> Void
    let customTitle: (RemoteCommand) -> String?
    @Environment(\.appLanguage) private var language

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
                    directionalOffset: directionalOffset,
                    customTitle: customTitle(.up)
                ) { isPressed in
                    onButtonStateChanged(.up, isPressed)
                }
                DPadDirectionControl(
                    symbol: "chevron.down",
                    direction: .down,
                    directionalOffset: directionalOffset,
                    customTitle: customTitle(.down)
                ) { isPressed in
                    onButtonStateChanged(.down, isPressed)
                }
                DPadDirectionControl(
                    symbol: "chevron.left",
                    direction: .left,
                    directionalOffset: directionalOffset,
                    customTitle: customTitle(.left)
                ) { isPressed in
                    onButtonStateChanged(.left, isPressed)
                }
                DPadDirectionControl(
                    symbol: "chevron.right",
                    direction: .right,
                    directionalOffset: directionalOffset,
                    customTitle: customTitle(.right)
                ) { isPressed in
                    onButtonStateChanged(.right, isPressed)
                }

                Button {} label: {
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
                        .overlay {
                            if let customTitle = customTitle(.confirm) {
                                Text(customTitle)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.94))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .allowsTightening(true)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, diameter * 0.035)
                            }
                        }
                        .frame(width: diameter * 0.39, height: diameter * 0.39)
                }
                .buttonStyle(TactileButtonStyle { isPressed in
                    onButtonStateChanged(.confirm, isPressed)
                })
                .accessibilityLabel(language.text("确定"))
                .accessibilityAction {
                    onButtonStateChanged(.confirm, true)
                    onButtonStateChanged(.confirm, false)
                }
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
    let customTitle: String?
    let onPressChanged: (Bool) -> Void

    @State private var isPressed = false
    @Environment(\.appLanguage) private var language

    var body: some View {
        let iconOffset = direction.iconOffset(distance: directionalOffset)

        ZStack {
            DPadSectorShape(direction: direction)
                .fill(Color.black.opacity(isPressed ? 0.13 : 0))

            VStack(spacing: 1) {
                Image(systemName: symbol)
                    .font(.system(size: customTitle == nil ? 30 : 25, weight: .semibold))

                if let customTitle {
                    Text(customTitle)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .allowsTightening(true)
                        .multilineTextAlignment(.center)
                        .frame(width: 62)
                }
            }
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
                    onPressChanged(true)
                }
                .onEnded { _ in
                    isPressed = false
                    onPressChanged(false)
                }
        )
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text(direction.accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onPressChanged(true)
            onPressChanged(false)
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
    let customTitle: String?
    let onPressChanged: (Bool) -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button {} label: {
            GraphiteSurface {
                VStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .font(.system(size: customTitle == nil ? 32 : 27, weight: .medium))
                        .frame(height: 34, alignment: .center)

                    if let customTitle {
                        Text(customTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .allowsTightening(true)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12, alignment: .center)
                    }
                }
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(TactileButtonStyle(onPressChanged: onPressChanged))
        .accessibilityLabel(language.text(title))
        .accessibilityAction {
            onPressChanged(true)
            onPressChanged(false)
        }
    }
}

struct VoiceButton: View {
    let isActive: Bool
    let onPressChanged: (Bool) -> Void

    @State private var isTrackingPress = false
    @Environment(\.appLanguage) private var language

    var body: some View {
        let visualActive = isActive || isTrackingPress

        Button {} label: {
            ZStack {
                AppIconRoundedRectangle()
                    .fill(
                        LinearGradient(
                            colors: visualActive
                                ? [RemotePalette.voiceActiveTop, RemotePalette.voiceActiveBottom]
                                : [RemotePalette.voiceTop, RemotePalette.voiceBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                AppIconRoundedRectangle()
                    .stroke(
                        Color.white.opacity(visualActive ? 0.78 : 0.45),
                        lineWidth: visualActive ? 1.8 : 1
                    )
                    .padding(1)
                AppIconRoundedRectangle()
                    .stroke(Color.black.opacity(0.25), lineWidth: 1.4)

                VStack(spacing: 10) {
                    Image(systemName: visualActive ? "waveform" : "mic.fill")
                        .font(.system(size: 45, weight: .medium))
                        .scaleEffect(visualActive ? 1.12 : 1)
                    Text(language.text(visualActive ? "正在说话" : "按住说话"))
                        .font(.system(size: 24, weight: .bold))
                    Text(language.text("松手停止"))
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(visualActive ? 0.08 : 0.18), radius: visualActive ? 1 : 5, x: 0, y: visualActive ? 1 : 4)
        .scaleEffect(visualActive ? 0.955 : 1)
        .offset(y: visualActive ? 3 : 0)
        .contentShape(AppIconRoundedRectangle())
        .buttonStyle(TactileButtonStyle(showsPressedVisuals: false) { isPressed in
            guard isTrackingPress != isPressed else { return }
            isTrackingPress = isPressed
            onPressChanged(isPressed)
        })
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: visualActive)
        .accessibilityLabel(language.text("按住说话"))
        .accessibilityValue(language.text(isActive ? "正在录音" : isTrackingPress ? "正在准备" : "未录音"))
        .accessibilityAction {
            onPressChanged(!isActive)
        }
    }
}

struct ConfirmButton: View {
    let customTitle: String?
    let onPressChanged: (Bool) -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button {} label: {
            LightSurface {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 45, weight: .semibold))
                    Text(language.text("确定"))
                        .font(.system(size: 25, weight: .bold))
                    Text(customTitle ?? "Return")
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .allowsTightening(true)
                        .multilineTextAlignment(.center)
                        .opacity(0.78)
                }
                .foregroundStyle(RemotePalette.text)
            }
        }
        .buttonStyle(TactileButtonStyle(onPressChanged: onPressChanged))
        .accessibilityLabel(language.text("确定，Return"))
        .accessibilityAction {
            onPressChanged(true)
            onPressChanged(false)
        }
    }
}
