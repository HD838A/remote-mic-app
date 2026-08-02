import SwiftUI

struct RemoteControlScreen: View {
    @EnvironmentObject private var connection: RemoteMacConnection

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

                    DPadView(perform: perform)
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
            }
        }
        .preferredColorScheme(.light)
        .task {
            HapticFeedback.shared.prepare()
            connection.start()
        }
    }

    private var header: some View {
        ZStack {
            HStack {
                Button {
                    perform(.power)
                } label: {
                    LightSurface {
                        Image(systemName: "power")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(RemotePalette.text.opacity(0.86))
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("关机")

                Spacer()

                Button {
                    connection.restartDiscovery()
                } label: {
                    LightSurface {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.blue)
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("选择 Mac")
            }

            HStack(spacing: 10) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
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
            }
            .offset(x: -20)
        }
        .frame(height: 58)
    }

    private func middleControls(buttonSize: CGFloat, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            HStack(spacing: 0) {
                middleButton("返回", image: "chevron.left", command: .back, size: buttonSize)
                Spacer(minLength: spacing)
                middleButton("主页", image: "house", command: .home, size: buttonSize)
                Spacer(minLength: spacing)
                middleButton("菜单", image: "line.3.horizontal", command: .menu, size: buttonSize)
            }

            HStack(spacing: 0) {
                middleButton("TV", image: "tv", command: .television, size: buttonSize)
                Spacer(minLength: spacing)
                middleButton("增大音量", image: "speaker.plus.fill", command: .volumeUp, size: buttonSize)
                Spacer(minLength: spacing)
                middleButton("减小音量", image: "speaker.minus.fill", command: .volumeDown, size: buttonSize)
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
        MiddleControlButton(title: title, systemImage: image) {
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

            ConfirmButton {
                perform(.confirm)
            }
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

    private func perform(_ command: RemoteCommand) {
        HapticFeedback.shared.trigger(command.hapticStrength)
        connection.send(command)
    }
}

#Preview("Remote Control") {
    RemoteControlScreen()
        .environmentObject(RemoteMacConnection())
}
