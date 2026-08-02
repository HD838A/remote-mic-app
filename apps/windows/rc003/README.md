# Remote Mic · RC003（Windows）

这是与 macOS App 完全独立打包的 Windows 版本。它同时实现 RC003 麦克风链路和普通权限按键映射：

```text
RC003 WinRT BLE/GATT
→ ATVV
→ IMA/DVI ADPCM
→ 16 kHz PCM
→ 用户明确选择的 Windows 播放端点
→ 用户自行安装的 VB-CABLE CABLE Input（可选）

RC003 HID
→ Windows Raw Input
→ 单击 / 双击 / 长按
→ 用户映射
→ SendInput 或打开应用
```

设置窗口采用与 macOS 相同的信息架构：连接与语音、按键、权限、关于。麦克风键固定由 ATVV 语音生命周期接管，不能改成普通按键动作。

不包含 DJI、Frida、WUDFHost 注入、输入法进程附加、内核驱动或 VB-CABLE 安装包。

## 系统与安装边界

- Windows 10 1809+ / Windows 11 x64。
- 应用按当前用户安装到 `%LOCALAPPDATA%\RemoteMic\RC003`，安装应用本身不请求管理员权限。
- RC003 需由用户在 Windows 蓝牙设置中配对。
- 若要让输入法把 RC003 当作麦克风，用户需自行从 [VB-Audio 官网](https://vb-audio.com/Cable/) 安装 VB-CABLE；该第三方驱动通常需要 UAC 和重启。
- Remote Mic 选择 `CABLE Input` 播放端点；输入法或语音应用选择 `CABLE Output` 录音端点。
- Windows 产物是安装器 EXE 和 portable ZIP，不复用 macOS APP、PKG、DMG、Developer ID、公证或 Sparkle。
- Raw Input 和 SendInput 不请求管理员权限；受 UIPI 限制，普通权限应用不能控制以管理员身份运行的目标应用。

## 运行

```powershell
RemoteMicRC003.exe --settings
RemoteMicRC003.exe --bridge
RemoteMicRC003.exe --list-output-devices
RemoteMicRC003.exe --dry-run
```

桥接模式使用 Windows 命名 Mutex，当前登录会话只能运行一个实例。配置和日志位于 `%LOCALAPPDATA%\RemoteMic\RC003`。按键映射保存后，运行中的桥接会在下一次实体按键时读取新配置。

## 在没有 Windows 电脑时测试

仓库是公开仓库，`.github/workflows/windows-rc003-ci.yml` 使用 GitHub 标准 `windows-latest` Runner。根据 [GitHub Actions 计费文档](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions)，GitHub 当前对公开仓库的标准 Hosted Runner 不收取 Actions 分钟费用；工作流保留期设为 7 天，减少无用 artifact 占用。

CI 可以完成：

- Windows 依赖安装、语法检查和单元测试；
- PyInstaller one-dir 构建与 `--dry-run`；
- Inno Setup 安装器编译；
- portable ZIP、安装器和 SHA-256 清单；
- Windows tag 构建的免费自签 Authenticode。

CI 不能代替真实 RC003、蓝牙芯片、VB-CABLE、输入法、SmartScreen、安装/卸载和睡眠唤醒测试。正式宣称支持 Windows 前仍需借用实体 Windows 机器，或请可信测试者按研究文档验收；无需在 Mac 安装模拟器或虚拟机。

## 本地 Windows 构建

安装 Python 3.12 和 Inno Setup 6 后：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build\build-windows.ps1 -Version 0.1.0-dev
```

输出位于 `dist\release\`。默认构建是 unsigned；正式 tag 由 GitHub Actions 使用免费自签证书签名。

## 免费自签证书

在 Mac 上设置一个只存在于当前终端的强密码，然后生成 PFX：

```bash
export REMOTE_MIC_WINDOWS_PFX_PASSWORD='使用密码管理器生成的长随机密码'
./apps/windows/rc003/build/create-self-signed-certificate.sh
```

把脚本生成的 PFX Base64 和密码分别保存为 GitHub Secrets：

- `WINDOWS_CERTIFICATE_PFX_BASE64`
- `WINDOWS_CERTIFICATE_PASSWORD`

私钥和 PFX 位于已忽略的 `build/secrets/`，必须离线备份，不能提交仓库。tag `windows-rc003-v*` 缺少 Secrets 时工作流会失败，不会把 unsigned 包伪装成正式自签 Release。

自签证书成本为 0，但 Windows 默认不信任：仍可能显示“未知发布者”、签名链不受信任或 SmartScreen 警告。项目只公开证书 SHA-256 指纹和资产 SHA-256，不要求用户把证书导入受信任根。

## 已知缺口

- 包含 PySide6 四页设置窗口、Raw Input 和 SendInput 的 unsigned Windows 包已由 [Actions run 30730044548](https://github.com/HD838A/remote-mic-app/actions/runs/30730044548) 成功构建；安装器约 35 MB，portable ZIP 约 53 MB。真实 RC003 逐键体验仍需 Windows 真机验收。
- 标准 Raw Input 能收到哪些 RC003 键取决于 Windows、蓝牙芯片和设备 HID 暴露方式；真实 13 键逐键验收尚未完成，系统已经消费的原始键也可能无法完全拦截。
- 当前没有自动更新、系统托盘、配置导入导出或测试音。
- VB-CABLE 方向配置错误时只会表现为目标应用没有声音，仍需在 Windows 真机完善诊断。
- 免费自签不能获得公共 CA 的默认系统信任。

来源和删减范围见 [ATTRIBUTION.md](ATTRIBUTION.md)。
