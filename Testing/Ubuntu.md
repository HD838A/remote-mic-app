# Ubuntu 桌面版构建与验收

Ubuntu 24.04 或 26.04 桌面，BlueZ、PipeWire、WirePlumber 和带 RemoteDesktop 门户的图形会话。当前硬件验收型号为小米蓝牙语音遥控器 2 Pro（RC003）。

## 安装及连接

1. 下载当前 PR 的 Ubuntu CI 测试包，在下载目录运行 `sudo apt install ./sayall-ubuntu_*.deb`。从应用菜单启动「无线麦 SayAll」，或在终端运行 `sayall-ubuntu`。
2. 按向导打开 Ubuntu 蓝牙设置。长按遥控器主页和菜单键配对。若已配对，安装后断开并重连一次，让 udev 应用设备权限。在向导里选中遥控器并连接。
3. 在听写工具的麦克风列表里选 **SayAll RC003**。在向导里选择语音输入工具或自定义其快捷键。要使用改键，在「按键」中开启全按键支持，并在 Ubuntu 的桌面授权窗口允许键盘和指针控制。系统权限按当前用户和这支遥控器生效。
4. 在 Codex 输入框中按住语音键说一句话，松开检查文字。由用户选择的 Linux 听写工具完成转写。按键页可为确认、返回、菜单等键设置快捷键或组合动作。
5. 在托盘菜单退出即可释放连接。可在「设置」中启用登录启动。卸载使用 `sudo apt remove sayall-ubuntu`，然后重新连接遥控器。

## 从源码编译

构建需要 Swift 6.2、近期稳定版 Rust 和 Cargo、Node.js 22.12 以上、pnpm 10.15.0，以及系统开发包。原生 Vue/Tauri 桌面取自[官方 Windows 公开源码的固定版本](https://github.com/GetSayAll/remote-mic-app-windows/tree/5410f6d30e1061607c8ccbbca7c6c7f1cc474951)。编译脚本检出精确提交，应用 Ubuntu 平台补丁，按 pnpm 和 Cargo 锁文件构建。音频库直接编译本仓库中的 ATVV 实现。已安装软件无需这些开发工具。

```sh
sudo apt install build-essential git patch dpkg-dev libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev libxdo-dev python3-dbus python3-gi python3-pil gir1.2-atspi-2.0
SAYALL_TEST_FRONTEND=1 make -f packaging/ubuntu/Makefile test package
sudo apt install ./.build/ubuntu/sayall-ubuntu_*.deb
```

完整 Ubuntu 24.04 构建环境及无硬件桌面冒烟测试见 [Ubuntu CI](../.github/workflows/ubuntu-ci.yml)。`SAYALL_PUBLIC_CHECKOUT` 可指定已包含固定提交的本地上游检出。安装包包括 Linux 桌面程序、只读回眸 MCP 服务、BlueZ/PipeWire 后端及 Swift 音频库。

## 验收

- 在欢迎向导和主窗口检查公开版的连接、按键、组合动作、推荐、回眸、设置和账号入口。验证修改设置后重启能恢复。账号服务遵循上游公开构建的可用范围。
- 验证按键录入、自定义快捷键、组合动作和桌面权限撤销。验证选定遥控器以外的键盘正常。只在明确启用回眸时核对可访问的前台编辑框，密码输入框不参与捕获。
- 用同一设备测试短句、超过 60 秒的长句和连续两段话，对照[硬件语音合同](HardwareVoiceAudioContract.md)。关掉蓝牙后再启用，核对 UI 连接状态及麦克风节点清理、恢复。
- 排查音频时先从托盘退出桌面程序，再运行 `/usr/bin/python3 /usr/lib/sayall-ubuntu/bridge.py --probe`。成功会显示 `ATVV ready: 16000 Hz mono`。`--pcm` 为显式诊断模式，输出 16 kHz 单声道 s16le。公开验证材料请隐藏设备地址和用户语音。
