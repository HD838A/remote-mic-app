Remote Mic · RC003（Windows）

这是只支持小米 RC003 的 Windows 麦克风与按键映射验证版本。

使用步骤：
1. 在 Windows 蓝牙设置中配对 RC003。
2. 如需把声音提供给输入法或会议软件，请自行从 https://vb-audio.com/Cable/ 安装 VB-CABLE；本安装包不包含也不会自动安装驱动。
3. 打开“Remote Mic · RC003 设置”，选择 CABLE Input（播放端点），保存并启动桥接。
4. 在输入法或语音应用中选择 CABLE Output（录音端点）。
5. 按住 RC003 麦克风键说话，松开结束。
6. 在设置的“按键”页面配置单击、双击、长按、预置动作或自定义快捷键；麦克风键固定为语音。

限制：
- 按键映射使用普通权限 Raw Input 和 SendInput，不注入 Windows 系统进程，也不附加输入法进程。
- Windows 和蓝牙 HID 暴露方式可能使部分实体键无法识别或无法屏蔽原始动作；普通权限应用也不能控制管理员权限目标应用。
- 应用按当前用户安装，不需要管理员权限；VB-CABLE 是用户另行安装的第三方驱动，安装时通常需要 UAC 和重启。
- 免费自签 Release 仍可能显示“未知发布者”或 SmartScreen 警告，请对照 Release 的 SHA-256 和证书指纹。
- 当前尚未由本项目在真实 Windows 机器和 RC003 上完成独立验收。
