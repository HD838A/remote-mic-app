# Ubuntu RC003 候选版本

Ubuntu 24.04 或 26.04，BlueZ、PipeWire 和 WirePlumber。请在当前用户的图形会话内运行。当前提供命令行桥接与 Debian 安装包，复用 macOS 的 ATVV 协商、分帧、解码和 PCM 后处理。实体遥控器验收遵循[跨硬件音频合同](HardwareVoiceAudioContract.md)。

## 构建与安装

在仓库根目录，使用官方 Swift 6.2 Ubuntu 24.04 工具链、GNU make、binutils 和 dpkg-dev 编译。测试需要系统 Python 3、python3-gi 和 python3-dbus。

```sh
make -f packaging/ubuntu/Makefile test package
sudo apt install ./.build/ubuntu/sayall-ubuntu_*.deb
```

## 连接与使用

1. 在 Ubuntu 的蓝牙设置里配对小米蓝牙遥控器 2 Pro（RC003）。按住主页和菜单键可进入配对。安装后重新连接一次，让系统加载此型号专用的键位表。
2. 运行 `sayall-ubuntu --list` 和 `sayall-ubuntu --probe`。已配对多支时，用 `--device ADDRESS` 选择其中一支。探测成功应显示 `ATVV ready: 16000 Hz mono`。
3. 在终端运行 `sayall-ubuntu`，保持进程运行。在支持麦克风的输入工具中选 **SayAll RC003**。将焦点放到 Codex 输入框，使用该工具的听写功能。如需按住说话，将输入工具的快捷键设为 `F13`。确认键发送 Enter，方向键用于导航，返回键发送 Esc。可在 Codex 的「设置 → 键盘快捷键」里把电视键（F14）绑定为新建会话，把菜单键（F15）绑定为切换会话。此版本输出音频，由所选输入工具完成转写。
4. `Ctrl+C` 会释放蓝牙通知并移除本进程创建的音频节点。遥控器断开时桥接会退出，唤醒并重连后再次启动即可。需要登录时自动运行和断线重试时，执行 `systemctl --user enable --now sayall-ubuntu.service`，停用时执行 `systemctl --user disable --now sayall-ubuntu.service`。卸载使用 `sudo apt remove sayall-ubuntu`，然后重连遥控器。

## 验收

- 开机首次协商、短按、长句（超过 60 秒）、两段连续语音，应从同一遥控器收到完整首尾。正常松手后日志应给出该段的样本数。听写软件选中虚拟麦克风后，逐句核对 Codex 输入框里的文字。
- 蓝牙断开、权限不足和 PipeWire 停止时，检查进程的诊断与退出结果，再检查能否重启恢复。确认其他键盘、默认扬声器及默认麦克风不变。
- `sayall-ubuntu --pcm` 输出 16 kHz 单声道有符号小端 16 位 PCM，仅在显式重定向时写盘。`--probe` 只读回能力响应并退出。实物采样、听写结果与用户的设备地址均不提交到仓库。
