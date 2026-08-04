import SwiftUI

struct RemoteControlScreen: View {
    struct MiddleControl: Equatable {
        let title: String
        let systemImage: String
        let command: RemoteCommand
    }

    static let middleControlRows = [
        [
            MiddleControl(title: "返回", systemImage: "chevron.left", command: .back),
            MiddleControl(title: "菜单", systemImage: "line.3.horizontal", command: .menu),
            MiddleControl(title: "增大音量", systemImage: "speaker.plus.fill", command: .volumeUp),
        ],
        [
            MiddleControl(title: "主页", systemImage: "house", command: .home),
            MiddleControl(title: "TV", systemImage: "tv", command: .television),
            MiddleControl(title: "减小音量", systemImage: "speaker.minus.fill", command: .volumeDown),
        ],
    ]

    @EnvironmentObject private var connection: RemoteMacConnection
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsMacAppInformation = false

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.height < 720
            let spacing: CGFloat = isCompact ? 10 : 16
            let dPadSize: CGFloat = isCompact ? 200 : 250
            let middleButtonSize: CGFloat = isCompact ? 68 : 88
            let primaryHeight: CGFloat = isCompact ? 126 : 160

            ZStack {
                RemoteBackground()

                VStack(spacing: spacing) {
                    header

                    DPadView(
                        perform: perform,
                        confirmPressed: confirmPressed,
                        confirm: confirm,
                        customTitle: connection.buttonTitle(for:)
                    )
                        .frame(width: dPadSize, height: dPadSize)

                    middleControls(buttonSize: middleButtonSize, spacing: spacing)

                    primaryControls
                        .padding(.top, 2)
                        .frame(height: primaryHeight)

                    Text(connection.guidanceText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            connection.hasIssue
                                ? Color.orange.opacity(0.92)
                                : RemotePalette.text.opacity(0.62)
                        )
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.top, isCompact ? 0 : 2)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.vertical, isCompact ? 6 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if proxy.safeAreaInsets.top >= 44 {
                    CutoutEasterEgg()
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 2)
                        .zIndex(1)
                }
            }
        }
        .preferredColorScheme(.light)
        .task {
            HapticFeedback.shared.prepare()
            connection.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, connection.state.shouldRestartDiscoveryOnActivation {
                connection.restartDiscovery()
            }
        }
        .navigationDestination(isPresented: $showsMacAppInformation) {
            MacAppInformationScreen()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        ZStack {
            HStack {
                Button {
                    perform(.power)
                } label: {
                    LightSurface {
                        VStack(spacing: 1) {
                            Image(systemName: "power")
                                .font(.system(
                                    size: connection.buttonTitle(for: .power) == nil ? 25 : 20,
                                    weight: .semibold
                                ))
                                .frame(height: connection.buttonTitle(for: .power) == nil ? 25 : 21)
                            if let customTitle = connection.buttonTitle(for: .power) {
                                Text(customTitle)
                                    .font(.system(size: 7, weight: .semibold))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.72)
                                    .allowsTightening(true)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 44, height: 16, alignment: .center)
                            }
                        }
                        .foregroundStyle(RemotePalette.text.opacity(0.86))
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("关机")

                Spacer()

                Button {
                    connection.restartDiscovery()
                    showsMacAppInformation = true
                } label: {
                    LightSurface {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(RemotePalette.text.opacity(0.86))
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("重新连接并查看 Mac App")
            }

            VStack(alignment: .center, spacing: 3) {
                if let pairingCode = connection.displayedPairingCode {
                    Text("校验码")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RemotePalette.text.opacity(0.62))
                    Text(pairingCode.map(String.init).joined(separator: " "))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.orange.opacity(0.95))
                        .accessibilityLabel("校验码 \(pairingCode)")
                } else {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(connection.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(connection.statusText)
                            .foregroundStyle(
                                connection.isConnected
                                    ? Color.green.opacity(0.88)
                                    : Color.orange.opacity(0.92)
                            )
                    }
                    Text(connection.macName)
                        .foregroundStyle(RemotePalette.text.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .font(.system(size: 14, weight: .medium))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 210)
        }
        .frame(height: 58)
    }

    private func middleControls(buttonSize: CGFloat, spacing: CGFloat) -> some View {
        // 已确认的产品布局；未经明确需求变更，不得调整这两行按钮的顺序。
        VStack(spacing: spacing) {
            ForEach(Array(Self.middleControlRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, control in
                        middleButton(
                            control.title,
                            image: control.systemImage,
                            command: control.command,
                            size: buttonSize
                        )
                        if index < row.count - 1 {
                            Spacer(minLength: spacing)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    private func middleButton(
        _ title: String,
        image: String,
        command: RemoteCommand,
        size: CGFloat
    ) -> some View {
        MiddleControlButton(
            title: title,
            systemImage: image,
            customTitle: connection.buttonTitle(for: command)
        ) {
            perform(command)
        }
        .frame(width: size, height: size)
    }

    private var primaryControls: some View {
        HStack(spacing: 16) {
            VoiceButton(isActive: connection.isVoiceActive) { isPressed in
                setVoiceActive(isPressed)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: connection.isVoiceActive) { _, isActive in
                if isActive {
                    HapticFeedback.shared.trigger(.recordingReady)
                }
            }

            ConfirmButton(
                customTitle: connection.buttonTitle(for: .confirm),
                onPress: confirmPressed,
                action: confirm
            )
            .frame(maxWidth: .infinity)
        }
    }

    private func setVoiceActive(_ active: Bool) {
        HapticFeedback.shared.trigger(active ? .emphasized : .release)
        if active {
            connection.beginVoice()
        } else {
            connection.endVoice()
        }
    }

    private func confirmPressed() {
        HapticFeedback.shared.trigger(.emphasized)
    }

    private func confirm() {
        connection.send(.confirm)
    }

    private func perform(_ command: RemoteCommand) {
        HapticFeedback.shared.trigger(command.hapticStrength)
        connection.send(command)
    }
}

#Preview("Remote Control") {
    RemoteControlScreen()
        .environmentObject(RemoteMacConnection())
}
