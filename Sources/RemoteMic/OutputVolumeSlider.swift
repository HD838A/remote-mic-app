import SwiftUI

/// 用户唯一音量的共用控件。
///
/// 连接页「语音设备」面板和 Onboarding 语音测试卡渲染的是同一份控件：标签文案、
/// 取值范围（0–1000%）、步长（20%）和数值格式都在这里定义一次，避免两处语义漂移。
/// 拖动时立即作用到送往语音工具的声音，不需要重建音频链路。
struct OutputVolumeSlider: View {
    @ObservedObject var settings: AppSettings
    let model: BridgeAppModel
    /// 标签列宽。连接页与「输出设备」对齐用 92，Onboarding 卡内用 44。
    var labelWidth: CGFloat = 92
    var valueWidth: CGFloat = 54
    var spacing: CGFloat = 14
    var labelFont: Font = .body
    var accessibilityIdentifier: String = "output.volume"
    var onEditingChanged: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: spacing) {
            Text("audio.volume.title")
                .font(labelFont)
                .frame(width: labelWidth, alignment: .leading)

            Slider(
                value: Binding(
                    get: { settings.outputVolumePercent },
                    set: { model.updateOutputVolumePercent($0) }
                ),
                in: VirtualAudioOutputLevelPolicy.percentRange,
                // 0–1000% 若用 1% 步长，AppKit 会画 1000 条刻度，轨道会糊成一条深色条带。
                step: 20,
                onEditingChanged: { editing in onEditingChanged?(editing) }
            )
            .accessibilityIdentifier(accessibilityIdentifier)

            Text("\(Int(settings.outputVolumePercent.rounded()))%")
                .font(.system(.body, design: .monospaced))
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}
