import SwiftUI

struct RemoteControlScreen: View {
    @State private var isVoiceActive = false
    @State private var lastCommand: RemoteCommand?

    var body: some View {
        ZStack {
            RemoteBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    header

                    DPadView(perform: perform)
                        .frame(maxWidth: 260)

                    middleControls

                    primaryControls
                        .padding(.top, 2)

                    Text("麦克风仅在按住时启用")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RemotePalette.text.opacity(0.62))
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.light)
        .task {
            HapticFeedback.shared.prepare()
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
                    perform(.chooseDevice)
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
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("已连接")
                            .foregroundStyle(Color.green.opacity(0.88))
                    }
                    Text("Mac 设备")
                        .foregroundStyle(RemotePalette.text.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .font(.system(size: 14, weight: .medium))
            }
        }
        .frame(height: 58)
    }

    private var middleControls: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible())
            ],
            spacing: 16
        ) {
            MiddleControlButton(title: "返回", systemImage: "chevron.left") {
                perform(.back)
            }
            MiddleControlButton(title: "主页", systemImage: "house") {
                perform(.home)
            }
            MiddleControlButton(title: "菜单", systemImage: "line.3.horizontal") {
                perform(.menu)
            }
            MiddleControlButton(title: "TV", systemImage: "tv") {
                perform(.television)
            }
            MiddleControlButton(title: "增大音量", systemImage: "speaker.plus.fill") {
                perform(.volumeUp)
            }
            MiddleControlButton(title: "减小音量", systemImage: "speaker.minus.fill") {
                perform(.volumeDown)
            }
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 16) {
            VoiceButton(isActive: isVoiceActive) { isPressed in
                setVoiceActive(isPressed)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 164)

            ConfirmButton {
                perform(.confirm)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 164)
        }
    }

    private func setVoiceActive(_ active: Bool) {
        guard isVoiceActive != active else { return }
        isVoiceActive = active
        perform(active ? .voiceStart : .voiceStop)
    }

    private func perform(_ command: RemoteCommand) {
        lastCommand = command
        HapticFeedback.shared.trigger(command.hapticStrength)
    }
}

#Preview("Remote Control") {
    RemoteControlScreen()
}
