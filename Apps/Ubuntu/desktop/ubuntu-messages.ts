export function isUbuntuDesktop(): boolean {
  return typeof window !== "undefined" && /Linux/i.test(navigator.platform) && "__TAURI_INTERNALS__" in window;
}

export const ubuntuMessages: Record<string, [string, string]> = {
  "需要安装 VB-CABLE": [
    "等待遥控器麦克风",
    "Waiting for the remote microphone"
  ],
  "由 VB-Audio 提供的免费虚拟声卡。安装需要管理员权限，完成后需重启电脑。": [
    "连接遥控器后，PipeWire 会创建 SayAll RC003 麦克风。",
    "Connect the remote to create the SayAll RC003 microphone in PipeWire."
  ],
  "装了 VB-CABLE，但还没有检测到设备": [
    "还没有检测到遥控器麦克风",
    "The remote microphone is not available yet"
  ],
  "无线麦把遥控器的声音送到播放端（CABLE Input）；语音工具再从录音端（CABLE Output）读取声音。": [
    "语音工具可以从 SayAll RC003 麦克风读取遥控器的声音。",
    "Select the SayAll RC003 microphone in your dictation app."
  ],
  "这台电脑还没有 VB-CABLE 语音设备": [
    "等待 PipeWire 建立麦克风",
    "Waiting for PipeWire to create the microphone"
  ],
  "这台电脑还没有 VB-CABLE 语音设备，先安装再继续。": [
    "请连接遥控器，等待 SayAll RC003 麦克风出现。",
    "Connect the remote and wait for the SayAll RC003 microphone."
  ],
  "先安装，再继续：": [
    "检查连接和声音设置",
    "Check the connection and sound settings"
  ],
  "下载压缩包并完整解压，右键安装程序选择「以管理员身份运行」。": [
    "在上一步中选择并连接已配对的遥控器。",
    "Select and connect your paired remote in the previous step."
  ],
  "安装完成后重启电脑，再回来点「重新检测」。": [
    "打开声音设置，确认「输入」中出现 SayAll RC003，再点「重新检测」。",
    "Open Sound settings, look for SayAll RC003 under Input, then rescan."
  ],
  "打开官方下载页": [
    "打开声音设置",
    "Open Sound Settings"
  ],
  "已打开官方下载页；安装需要管理员权限，完成后请重启电脑": [
    "已打开 Ubuntu 声音设置",
    "Opened Ubuntu Sound settings"
  ],
  "已打开 VB-CABLE 官方下载页面；安装时需要管理员权限，完成后请重启电脑": [
    "已打开 Ubuntu 声音设置",
    "Opened Ubuntu Sound settings"
  ],
  "没有检测到 VB-CABLE；安装完成后要重启电脑，再回来重新检测": [
    "请连接遥控器后重新检测麦克风",
    "Connect the remote, then rescan for its microphone"
  ],
  "未检测到 VB-CABLE；安装完成后需要重启电脑，再重新检测": [
    "请连接遥控器后重新检测麦克风",
    "Connect the remote, then rescan for its microphone"
  ],
  "已检测到 VB-CABLE。在下面列表里选择带「推荐」标记的 CABLE 设备；输入法的麦克风请选择 CABLE Output。": [
    "在输入工具中选择 SayAll RC003 麦克风。",
    "Select the SayAll RC003 microphone in your dictation app."
  ],
  "正在检测 VB-CABLE…": [
    "正在检测 PipeWire 麦克风…",
    "Checking the PipeWire microphone…"
  ],
  "已检测到 {count} 个 VB-CABLE 语音设备": [
    "已检测到 {count} 个遥控器麦克风",
    "Found {count} remote microphone(s)"
  ],
  "这一步只需要这一个播放端。": [
    "可在其他应用中选择此麦克风。",
    "Select this microphone in your other apps."
  ],
  "几何鸭": [
    "青色麦克风",
    "Teal microphone"
  ],
  "使用当前用户的 Windows 登录启动项，不需要管理员权限。": [
    "使用当前用户的 Ubuntu 登录启动项。",
    "Start SayAll when you sign in to Ubuntu."
  ],
  "无线麦只支持小米蓝牙语音遥控器 2 和小米蓝牙语音遥控器 2 Pro（RC001 / RC003）。": [
    "在列表中选择已配对的小米蓝牙语音遥控器。",
    "Select a paired Xiaomi Bluetooth voice remote."
  ],
  "在电脑上打开蓝牙设置（可直接点击下方按钮），打开电脑的蓝牙开关后点击「添加设备」然后选择「蓝牙」选项。": [
    "打开 Ubuntu 蓝牙设置，开启蓝牙。",
    "Open Ubuntu Bluetooth settings and turn on Bluetooth."
  ],
  "选中「小米蓝牙语音遥控器」，等待配对完成，列表里找不到设备时，打开高级设置或者点开「显示所有设备」。": [
    "在蓝牙列表中选择 MI RC 或「小米蓝牙语音遥控器」，等待配对完成。",
    "Select MI RC or your Xiaomi voice remote and wait for pairing to finish."
  ],
  "应用已经连上遥控器，但 Windows 还没有提供它的按键通道。先按一下普通按键；仍无反应时，在蓝牙设置里删除这支遥控器，再按「TV」键 3 秒重新配对；还是不行就重启这台电脑（用「重启」，不要用「关机」再开机）。": [
    "请在蓝牙设置中断开并重新连接遥控器，让 Ubuntu 为其输入设备应用权限，然后按一下普通键。",
    "Disconnect and reconnect the remote in Bluetooth settings so Ubuntu applies the input-device permissions, then press a regular button."
  ],
  "Windows 还没有识别到这支遥控器的按键通道。打开蓝牙设置重新配对。": [
    "尚未获得遥控器输入权限，请在安装后重新连接。",
    "Reconnect the remote after installation to apply input-device permissions."
  ],
  "开启后，遥控器上的所有按键都能设置自定义功能，包括 Windows 默认收不到的返回 / 音量+ / 音量−。": [
    "开启后，可以为遥控器上的按键设置快捷键和组合动作。",
    "Enable to map remote buttons to shortcuts and combined actions."
  ],
  "开启后，无线麦会直接读取遥控器上已配置的按键，避免影响物理键盘上的同名按键；返回 / 音量+ / 音量−也需要开启后才能使用。每次开启都会弹出 Windows 授权窗口，请选择“是”；关闭开关即停。": [
    "Ubuntu 会请求允许控制键盘和指针。授权后，遥控器可执行已配置的动作。关闭此开关会释放控制权限。",
    "Ubuntu will ask to allow keyboard and pointer control. Once allowed, the remote can perform your configured actions. Turn this off to release control."
  ],
  "开启时 Windows 会弹出授权窗口，请选择“是”。": [
    "在 Ubuntu 的桌面授权窗口中允许键盘和指针控制。",
    "Allow keyboard and pointer control in the Ubuntu desktop prompt."
  ],
  "每次开启都会弹出 Windows 授权窗口，请选择“是”。": [
    "在 Ubuntu 的桌面授权窗口中允许键盘和指针控制。",
    "Allow keyboard and pointer control in the Ubuntu desktop prompt."
  ]
};
