# 无线麦 SayAll for Windows · RC003

## Windows 版本（RC003）

把小米蓝牙遥控器 2 Pro（RC003）变成 Windows 语音输入遥控器：按住遥控器的
语音键说话，程序接收 RC003 的蓝牙语音、写入虚拟麦克风，并在按下/松开边界
触发桌面语音输入软件。

Windows 客户端位于 `apps/windows/rc003/`，是当前实际使用和打包的产品基线。

当前 Windows 客户端支持两套彼此隔离、可在设置界面手动切换的预设：

- Typeless：默认使用 `Ctrl + Alt` 点按开始，再次点按结束。
- 千问输入法：默认使用右 `Alt` 点按开始，再次点按结束，并带有经过验证的
  Windows 目标适配。

> 当前版本是首个可用的源码/构建候选 `0.1.0-candidate`，安装包尚未签名。项目已经在真实
> RC003、VB-CABLE、Typeless 和千问输入法上完成主要交互验收，但仍保留下面
> 列出的已知限制。自动化测试不能替代其他电脑、遥控器固件和第三方软件版本
> 上的真实设备验收。

## 功能

- 自动发现并连接已配对的 RC003。
- 接收 ATVV 语音流并解码为 16 kHz、单声道、16-bit PCM。
- 将语音持续写入用户选择的 Windows 播放端点，配合 VB-CABLE 提供虚拟麦克风。
- 遥控器语音键采用“物理长按、桌面软件两次点按”的会话边界协议。
- Typeless 与千问预设在设置界面中切换，不需要手动切换桥接脚本。
- 普通遥控器按键映射、真实按键检测和使用统计。
- 显示当前生效预设、桥接状态和可读取时的遥控器电量。
- 连接、按键映射、统计、权限和检查五个 Windows 设置页面。
- 安装器支持原位升级：安装新版时自动停止并替换旧程序，保留配置、按键映射、
  使用统计和日志，Windows 中只保留一个安装条目。

## 系统要求

- Windows 10 1809（内部版本 17763）或更高版本，x64。
- 小米蓝牙遥控器 2 Pro / RC003。
- Python 3.11（仅源码运行和开发需要；打包版本自带运行环境）。
- 需要虚拟麦克风时安装 [VB-CABLE](https://vb-audio.com/Cable/)。
- Typeless 或千问输入法由用户自行安装和配置，本项目不包含这些第三方软件。

音频方向必须正确：

```text
RC003 → 无线麦 SayAll Windows → CABLE Input → CABLE Output → 语音输入软件
```

在无线麦 SayAll Windows 中选择 `CABLE Input`，在 Typeless 或千问中选择
`CABLE Output` 作为麦克风。

## 快速开始

### 使用源码

在 Windows PowerShell 中：

```powershell
./scripts/setup-baseline.ps1
./打开最新源码设置.cmd
```

也可以直接进入客户端目录运行：

```powershell
cd apps/windows/rc003
$env:PYTHONPATH = "src"
.\.venv\Scripts\python.exe -m ovb_rc003 --settings
```

在“连接”页面选择 RC003、音频输出和语音软件预设，然后点击“保存并切换桥接”。

### 构建与测试

```powershell
./scripts/test-baseline.ps1
./scripts/build-baseline-candidate.ps1
./scripts/package-baseline-portable.ps1
./scripts/package-baseline-installer.ps1
```

安装器需要先使用 Inno Setup 6 编译：

```powershell
ISCC.exe apps/windows/rc003/installer/RemoteMicRC003Setup.iss
```

生成的安装器、便携 ZIP、构建目录、配置和日志均被 Git 忽略，不属于公开源码。
更完整的开发和打包说明见
[Windows 客户端文档](apps/windows/rc003/README.md)。

## 更新已有安装

直接运行新版本安装器，不需要先卸载或删除旧版本。安装器使用固定 AppId 和安装
目录，先停止旧设置/桥接进程，再替换独立的程序载荷；以下运行期数据会保留：

- `config.json`
- `key_bindings.json`
- `usage-statistics.json`
- `logs/`

便携 ZIP 不具备这套原位升级能力，需要无手工清理的升级体验时应使用安装器。

## 已知限制

- RC003 的返回键、音量加和音量减目前不会通过受支持的 Windows 输入路径稳定
  到达程序；项目不会为此安装 SYSTEM 服务、注入系统驱动宿主或降低系统保护。
- Typeless 和千问都可能完成识别但没有把文字自动提交到当前编辑器。最近一次
  验收中两者均可用，但偶发内容需要从语音软件中手动复制；项目当前不会强制
  抢焦点或自动粘贴。
- 千问的目标适配与已验证的客户端版本绑定；千问升级后需要重新验证，失败时
  会安全停止适配，而不会影响 Typeless 预设。
- 安装器尚未代码签名，Windows SmartScreen 可能提示风险。发布或传输安装包时
  应同时提供并核对 SHA-256。

## 隐私与安全

- 不把真实蓝牙地址、HID 设备路径、语音数据、令牌或个人绝对路径写入源码。
- 生产日志只记录诊断所需的状态和计数，不记录原始语音内容。
- 配置、统计和日志保存在当前用户的 `%LOCALAPPDATA%\RemoteMic\RC003`，并被
  Git 排除。
- 每次公开构建都会运行源码边界检查，拒绝个人路径、真实 MAC 地址、凭据形状
  文本和未授权二进制文件。

## 项目结构

- `apps/windows/rc003/`：当前可用的 Python / PySide6 Windows 客户端。
- `device-profiles/`：RC003 和其他实验设备的公开协议描述。
- `docs/decisions/`：语音边界、音频写入、预设切换和安装升级 ADR。
- `opendesign/`：设置界面的设计系统与原型。
- `include/`、`src/`、`apps/cli/`：后续渐进迁移使用的 C++20 基础层。
- `tests/` 与 `apps/windows/rc003/tests/`：硬件无关和 Windows 客户端回归测试。

本目录是一套独立的 Windows 工程，不以仓库历史 Windows Community Preview
或旧 PR #3 为代码基线。`RemoteMicRC003` 可执行文件名、安装器 AppId 和
`%LOCALAPPDATA%\RemoteMic\RC003` 数据路径是为原位升级保留的兼容标识。

## 开源协议与第三方组件

项目以 [GPL-3.0](LICENSE.md) 发布。来源和改编说明见
[COPYRIGHT.md](COPYRIGHT.md)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
以及 [ATTRIBUTION.md](apps/windows/rc003/ATTRIBUTION.md)。

VB-CABLE、Typeless、千问输入法及其商标均属于各自权利人；本项目不包含或替代
这些第三方语音识别产品。
