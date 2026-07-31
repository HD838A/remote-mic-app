# Windows 源码与 fork 对比

- 研究日期：2026-07-31
- 目标：为当前无线麦项目选择最佳 Windows 源码基线

本文区分“可供用户下载的程序”“可复用的源码参考”和“适合作为本项目长期主线的基线”。这些项目都不是可直接导入 Swift Package 的统一库。

## 当前仓库 fork 调查

[`HD838A/remote-mic-app`](https://github.com/HD838A/remote-mic-app) 当时有六个公开 fork：

| Fork | 相对上游状态 | Windows 价值 |
| --- | --- | --- |
| [`miaomiaozii/windows-remote-mic-app`](https://github.com/miaomiaozii/windows-remote-mic-app) | ahead 12 / behind 28，已分叉为 Windows 专用仓库 | **唯一有实质 Windows 实现的 fork** |
| [`gpboyer2/remote-mic-app`](https://github.com/gpboyer2/remote-mic-app) | identical | 无新增 Windows 内容 |
| [`keaneliu3333/remote-mic-app`](https://github.com/keaneliu3333/remote-mic-app) | behind | 无新增 Windows 内容 |
| [`fewtrerch/remote-mic-app`](https://github.com/fewtrerch/remote-mic-app) | behind | 无新增 Windows 内容 |
| [`pizigao/remote-mic-app`](https://github.com/pizigao/remote-mic-app) | behind | 无新增 Windows 内容 |
| [`mickorz/remote-mic-app`](https://github.com/mickorz/remote-mic-app) | behind | 无新增 Windows 内容 |

因此，从当前仓库 fork 开始研究时，实际候选只有 `miaomiaozii/windows-remote-mic-app`。

## 候选总表

| 项目 | 固定提交 | 技术栈 | RC003 麦克风 | 完整按键 | Release / CI | 许可 | 结论 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [`miaomiaozii/windows-remote-mic-app`](https://github.com/miaomiaozii/windows-remote-mic-app) | [`271ed794`](https://github.com/miaomiaozii/windows-remote-mic-app/tree/271ed7947eec19c4c691ed3ba97f338461be8051) | Python、WinRT、Qt/QML、PortAudio | 有，上游声明真机通过 | 有，完整体验依赖 Frida | prerelease；Windows CI 成功 | GPL-3.0-only | **最佳当前基线** |
| [`xxb26553663-star/remote-bridge-hub`](https://github.com/xxb26553663-star/remote-bridge-hub) | [`8a93f321`](https://github.com/xxb26553663-star/remote-bridge-hub/tree/8a93f321ac71a602300c6cd77f7256fa4b63068e) | Python、WinRT、Tk/自定义 UI、PortAudio | 有 | 有，依赖 Frida | v1.0.0；Windows checks | GPL-3.0 | 最佳上游协议/发行参考 |
| [`nijez/open-voice-bridge`](https://github.com/nijez/open-voice-bridge) | Windows tag [`8891d62`](https://github.com/nijez/open-voice-bridge/tree/8891d62) | Python Windows 候选；当前主线为 macOS Swift | 有 Windows 历史实现 | 有 | 历史 Windows prerelease；当前 Release 主力为 macOS | GPL-3.0 | 历史来源，不作为新主线 |
| [`mwlt/Voice_VibeCoding`](https://github.com/mwlt/Voice_VibeCoding) | [`79129bc3`](https://github.com/mwlt/Voice_VibeCoding/tree/79129bc3001aade2763803bb6c0274a87dba1f3a) | Rust、Tauri 2、Vue 3、WASAPI | 有实现声明 | 有，依赖 WUDFHost 注入 | 多个 MSI/NSIS Release；无 GitHub CI | **无 LICENSE** | 架构参考，不可直接采用 |
| [`microsoft/Windows-driver-samples/audio/sysvad`](https://github.com/microsoft/Windows-driver-samples/tree/ef7c3074748ab05726c3a9161d3256118efd76e2/audio/sysvad) | [`ef7c3074`](https://github.com/microsoft/Windows-driver-samples/tree/ef7c3074748ab05726c3a9161d3256118efd76e2/audio/sysvad) | C/C++、WDK、WaveRT/AVStream | 不处理 RC003 协议 | 不处理按键 | 官方样例，不是终端产品 | MIT | 仅供长期自研虚拟音频驱动参考 |

## 1. miaomiaozii/windows-remote-mic-app

### 优点

- 当前仓库直接 fork，领域模型和许可证最接近；
- Windows 目录本身约 2.5 万行新增实现和大量测试；
- WinRT 依赖版本固定，显式处理 GATT 缓存、断线、通知 token 和线程边界；
- ATVV 解码与当前 macOS 协议事实一致；
- 音频写入显式选择的端点，不修改系统默认设备；
- 有 Qt/QML 设置、诊断、单实例、原子配置写入和安装/便携两种产物；
- 最新提交对应的 [Windows CI run 30610405749](https://github.com/miaomiaozii/windows-remote-mic-app/actions/runs/30610405749) 成功；
- 上游 README 声明真实 RC003 十三键与豆包语音链路已通过。

### 关键风险

#### 未签名

`v0.1.0-windows-rc003-candidate.1` 的安装器明确为 unsigned。本次下载的安装器 SHA-256 与 GitHub Release digest 一致：

```text
RemoteMicRC003Setup-0.1.0-candidate-unsigned.exe
55660a5c514ef851ffb39a97b6711758ab7ff7882e1a1b455267be95a7322293
```

PE Security Directory 为 `00000000 00000000`，没有 Authenticode 签名。

正式采用该基线时，需要由本项目在独立 Windows 发布环境创建免费自签 Authenticode 证书，并重新构建、签署 Windows 应用和安装器。当前决定不购买 Microsoft Artifact Signing 或公共 CA 证书，因此普通 Windows 仍不会默认信任发布者，必须同时发布证书指纹和资产 SHA-256。macOS 的 Apple Developer ID、Developer ID Installer 和公证票据不能用于 Windows；Windows 产物也必须由独立 Windows CI 打包，不能从 macOS DMG/PKG 或 Sparkle 产物转换而来。具体费用和分包边界见 [Windows 支持可行性研究](README.md#windows-应用代码签名从哪里来)。

#### 发布内容与注释不一致

portable ZIP SHA-256：

```text
RemoteMicRC003-0.1.0-candidate-portable-unsigned.zip
041b430825e91972ba793f5fd9d7fd280dfc81cb1c9b12f48bc72fc8141eac45
```

ZIP 内实际包含：

```text
_internal/frida/_frida.pyd
_internal/ovb_rc003/frida_assets/frida-gadget-17.15.3-windows-x86_64.dll.xz
_internal/vb_cable_bundle/VBCABLE_Driver_Pack45.zip
```

但 [`RemoteMicRC003Setup.iss`](https://github.com/miaomiaozii/windows-remote-mic-app/blob/271ed7947eec19c4c691ed3ba97f338461be8051/apps/windows/rc003/installer/RemoteMicRC003Setup.iss) 的头部注释仍写着“No Frida binary is included”。安装器会递归打包完整 dist，因此不能根据该注释推断最终产物边界。

#### 验收表述不一致

顶层 README 和 Windows README 已声称真机通过，但以下源码仍保留旧表述：

- `__init__.py` / `__main__.py`：not yet real-device verified；
- `ble_transport_winrt.py`：UNVERIFIED against live WinRT runtime；
- `pyproject.toml` 和安装器注释也仍标记未实机验证。

这不证明实现不可用，但说明候选发布前缺少一次完整的状态清理与发布审计。

#### 进程注入

完整 HID tap 使用 [`frida_hid_tap_injector.py`](https://github.com/miaomiaozii/windows-remote-mic-app/blob/271ed7947eec19c4c691ed3ba97f338461be8051/apps/windows/rc003/src/ovb_rc003/frida_hid_tap_injector.py)：

- 获取 `SeDebugPrivilege`；
- 定位 RC003 的 `WUDFHost.exe`；
- `OpenProcess` / `VirtualAllocEx` / `WriteProcessMemory` / `CreateRemoteThread`；
- 用 `LoadLibraryW` 注入 Gadget DLL。

豆包语音快捷键兼容还会附加 `ImeService.exe`，清除本项目注入事件的标记。这两项都可能被终端防护软件识别为高风险行为。

### 适合复用的边界

- `atvv_protocol.py` / `atvv_session.py`；
- `ble_transport_winrt.py`；
- `audio_output.py` / `audio_playback.py`；
- 设备选择、配置和诊断的失败关闭逻辑；
- Windows CI、PyInstaller 和 Inno Setup 结构。

### 不应在第一阶段强制复用

- Frida WUDFHost 注入；
- 豆包 ImeService 物理化；
- 随包分发 VB-CABLE，除非完成单独许可核对；
- 把上游真机声明直接改写成本项目已验收。

## 2. xxb26553663-star/remote-bridge-hub

### 价值

- 项目描述本身就是 Windows voice input and remote-control bridge；
- RC003、T1、汉王 V60 三套独立安装包；
- `v1.0.0` 有正式 Release，Xiaomi 安装器有较多下载；
- GPL-3.0，源码和安装器完整；
- 同样使用 WinRT ATVV、Frida HID tap 和 VB-CABLE；
- 是 Windows fork 明确引用的 HID 旁路上游。

安装器核验：

```text
XiaomiRemoteBridgeSetup-1.0.0.exe
da86cbaca204390524eac0af6575818a3049b56ab15c0d2cb228f18c582bac5f
```

SHA-256 与 GitHub digest 一致，PE Security Directory 为空，仍是未签名安装器。

### 不作为首选的原因

- 不是当前仓库直接 fork，产品界面和配置模型差异更大；
- Windows fork 已在其基础上继续修复 RC003 重复按键、语音时序、保存可靠性等问题；
- 仓库同时承载三类设备和推广内容，不适合作为当前产品的最小边界；
- 仍依赖 Frida 与 VB-CABLE，未消除核心发布风险。

结论：保留为协议、安装器和 HID tap 的交叉参考，不取代 Windows fork。

## 3. nijez/open-voice-bridge

该项目当前主线已经转向 macOS Swift，但历史 tag `v0.3.0-windows-rc003-candidate.1` 包含 Windows RC003 候选。`miaomiaozii/windows-remote-mic-app` 的 ATTRIBUTION 明确把它列为 WinRT BLE、ATVV、Raw Input、SendInput 和 Qt/QML 设置页的上游来源。

它的价值是追溯代码来源和历史设计，不是继续承载 Windows 产品：

- 当前仓库描述和最新 Release 主力均为 macOS；
- Windows fork 已把 Windows 子树独立维护并追加真机修复；
- 继续从历史 tag 开发会丢失这些后续修复。

## 4. mwlt/Voice_VibeCoding

### 技术优点

- Rust + Tauri 2 + Vue 3，安装包显著小于 Python/Qt 候选；
- 直接实现 WinRT BLE、ADPCM、HID tap、WASAPI/音频路由；
- 有音频波形、ATVV 修复、虚拟声卡探测、托盘、开机自启和更新提示；
- 对 `always_play`、`hold_device`、`deferred` 三种 VB-CABLE 生命周期做过作者侧对照；
- Release 安装器体积约 11–13 MB。

安装器核验：

```text
Voice.VibeCoding_1.3.10_x64-setup.exe
9dfe5c0092a12561db7543fbabaec2917b0019c467d522602a4d90b9eb9172ef
```

SHA-256 与 GitHub digest 一致，PE Security Directory 为空，未签名。

### 不能直接采用的原因

- GitHub API 没有识别到许可证，仓库也没有 LICENSE 文件；README 明确写“若未附带 LICENSE，默认保留所有权利”；
- 没有 GitHub Actions 工作流或公开 CI 结果；
- 提交和 Release 很密集，但缺少与 Python fork 同等级的自动化证据；
- 仓库直接提交了 VB-CABLE ZIP 和 Frida Gadget 资产，第三方再分发边界需要独立审查；
- T1/V60 只是预留，作者明确没有硬件测试；
- 同样依赖 WUDFHost 注入，未降低安全模型风险。

结论：适合参考 Rust/Tauri UI、音频生命周期和诊断体验；在获得明确许可证前，不能复制或派生其代码。

## 5. Microsoft SysVAD

[`audio/sysvad`](https://github.com/microsoft/Windows-driver-samples/tree/ef7c3074748ab05726c3a9161d3256118efd76e2/audio/sysvad) 是微软虚拟音频驱动样例，可作为长期自研 `Remote Mic` Windows 虚拟录音设备的起点。

它不能解决：

- RC003 蓝牙和 ATVV；
- ADPCM 解码；
- Siri Remote HID/Opus；
- 按键映射和设置 UI。

采用 SysVAD 意味着新增 WDK、驱动签名、管理员安装、重启、升级/回滚、Windows 版本兼容和可能的硬件中心发布流程。第一版使用成熟第三方虚拟线缆的风险明显更低。

## Release 核验汇总

| 项目 | 资产 | SHA-256 | GitHub digest | Authenticode |
| --- | --- | --- | --- | --- |
| Windows fork | `RemoteMicRC003Setup-0.1.0-candidate-unsigned.exe` | `55660a5c...a7322293` | 一致 | 无 |
| remote-bridge-hub | `XiaomiRemoteBridgeSetup-1.0.0.exe` | `da86cbac...582bac5f` | 一致 | 无 |
| Voice_VibeCoding | `Voice.VibeCoding_1.3.10_x64-setup.exe` | `9dfe5c00...b9172ef` | 一致 | 无 |

本次只下载并静态检查资产，没有在 Windows 上运行任何 EXE。

## 最终排名

### 面向当前项目的 Windows RC003 产品

1. **miaomiaozii/windows-remote-mic-app**：最佳源码基线；
2. **xxb26553663-star/remote-bridge-hub**：最佳上游协议和发行交叉参考；
3. **nijez/open-voice-bridge 的 Windows 历史 tag**：来源追溯；
4. **mwlt/Voice_VibeCoding**：架构参考，但许可证阻塞；
5. **Microsoft SysVAD**：长期自研虚拟麦克风驱动参考。

### 最终选择

**选择 `miaomiaozii/windows-remote-mic-app`，但只把它视为待正式化的 Windows 应用源码基线，不视为已完成的稳定库。**

最先保留麦克风链路，最晚处理进程注入；免费自签流程、证书指纹与资产哈希、第三方许可和独立真机验收是从候选升级为产品的前置条件。当前接受自签证书不能消除 SmartScreen/未知发布者提示。
