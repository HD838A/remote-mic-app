# Windows 支持可行性研究

- 研究日期：2026-07-31
- 当前仓库：[HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app)
- 当前仓库研究基线：[`bbf6895389a70343246bcf1f92ae9e06df3e9c47`](https://github.com/HD838A/remote-mic-app/tree/bbf6895389a70343246bcf1f92ae9e06df3e9c47)
- 首选 Windows fork：[`miaomiaozii/windows-remote-mic-app@271ed794`](https://github.com/miaomiaozii/windows-remote-mic-app/tree/271ed7947eec19c4c691ed3ba97f338461be8051)
- 当前实施范围：**仅小米蓝牙遥控器 2 Pro / RC003**

本文只做源码、发布资产和公开资料研究，没有修改应用代码，没有安装 Windows 驱动，没有操作真实 RC003 或 Apple Siri Remote，也没有在 Windows 主机上完成独立硬件验收。

候选项目的逐项证据见 [Windows 源码与 fork 对比](candidate-comparison.md)。Apple Siri Remote 的 Windows 专项研究已经完成并保留在 [Apple Siri Remote Windows 路线](apple-siri-remote.md)，但目前暂停，不进入本方案的实施、验收和发布范围。

## 结论摘要

1. **RC003 的 Windows 版本已经有可工作的源码基线，不需要从零重写。** 当前仓库的六个公开 fork 中，只有 [`miaomiaozii/windows-remote-mic-app`](https://github.com/miaomiaozii/windows-remote-mic-app) 有实质 Windows 改动。它实现了 WinRT BLE、ATVV、IMA/DVI ADPCM、PortAudio、Raw Input、SendInput、Qt/QML 设置页、PyInstaller 和 Inno Setup，并声明已用真实 RC003 验收全部按键与豆包语音链路。
2. **最佳短期路线是以该 Windows fork 为产品源码基线，而不是移植现有 Swift/AppKit 应用。** macOS 的 CoreBluetooth、IOHID、CoreAudio HAL、AppKit、Sparkle 和签名脚本都不能在 Windows 直接复用；可复用的是协议事实、测试向量、设备画像、产品交互和隐私约束。
3. **麦克风主链路在 Windows 上可行，而且不必依赖 Frida。** RC003 语音可以通过 WinRT GATT 接收并解码，再写入用户选择的播放端点。要让输入法把它当作麦克风，当前候选依赖 VB-CABLE：程序写入 `CABLE Input`，输入法选择 `CABLE Output`。
4. **完整安装体验会比当前 macOS 版多一个第三方驱动步骤。** 基础应用可按当前候选安装到用户目录，不要求管理员权限；VB-CABLE 安装需要 UAC、管理员权限和通常一次重启。当前项目决定只使用免费自签 Windows 证书，因此即使文件带有自签 Authenticode 签名，SmartScreen 和“未知发布者”提示仍可能继续出现。
5. **完整的 RC003 按键支持比麦克风更敏感。** Windows 普通 Raw Input 拿不到或不能可靠区分部分 HID 报告。候选使用 Frida Gadget 注入 RC003 对应的 `WUDFHost.exe`，并为豆包输入法附加 `ImeService.exe` 来处理注入标记。这需要管理员/调试权限，可能触发安全软件，也是正式产品化前最大的安全与维护风险。
6. **Windows 没有 macOS 的“输入监控/辅助功能”授权模型。** 普通 BLE、Raw Input 和同完整性级别的 `SendInput` 没有对应的 TCC 弹窗；但 `SendInput` 受 UIPI 限制，不能可靠控制更高完整性级别的管理员应用。驱动安装、WUDFHost 注入和调试权限改由 UAC/管理员权限承担。
7. **当前所有实施资源只投入 RC003 Windows 正式化。** 优先交付不依赖进程注入的 RC003 麦克风主链路，再处理普通按键、可选完整 HID tap、签名和正式安装。Apple Remote 不参与当前技术选型，也不作为 Windows 首版或后续阶段的验收项。
8. **Windows 和 macOS 必须是两条完全独立的发布流水线。** Apple Developer ID 只能用于 macOS；Windows 在 Windows 构建环境中使用独立的免费自签 Authenticode 证书生成和签署 EXE/MSI/安装器。两端可以共享产品版本概念，但不能共享二进制、安装包、签名证书、公证或自动更新产物。

## 当前研究与实施范围

本轮“支持 Windows”只表示让小米 RC003 在 Windows 上达到无线麦和遥控按键目标：

| 目标 | 目标硬件 | 当前证据 | 结论 |
| --- | --- | --- | --- |
| Windows 版无线麦 | 小米 RC003 | 有直接 fork、Release、Windows CI 和上游真机声明 | 可进入产品化验证 |

Apple Siri Remote Windows 研究不删除，但已从当前范围移除。今后如果重新启动，应作为独立项目重新确认目标和验收条件，不与 RC003 Windows 版本捆绑。

RC003 使用公开的 ATVV 自定义 GATT 服务，音频为 16 kHz IMA/DVI ADPCM；本文后续架构、权限、安装、功能矩阵和阶段计划均只针对 RC003。

## 当前 macOS 产品与 Windows 目标架构

### 当前 macOS 数据路径

```text
RC003
→ CoreBluetooth / ATVV
→ IMA/DVI ADPCM
→ 16 kHz mono PCM
→ AVAudioEngine
→ MiRemoteV 2ch / 用户选择的回环设备
→ 输入法或语音应用
```

### 推荐的 Windows RC003 数据路径

```text
RC003
→ Windows 系统蓝牙配对
→ WinRT BluetoothLEDevice / GATT
→ ATVV 会话与 IMA/DVI ADPCM 解码
→ 16 kHz mono PCM
→ PortAudio / WASAPI 输出端点
→ CABLE Input
→ CABLE Output（作为录音输入）
→ 输入法或语音应用
```

对应的源码证据：

- [`ble_transport_winrt.py`](https://github.com/miaomiaozii/windows-remote-mic-app/blob/271ed7947eec19c4c691ed3ba97f338461be8051/apps/windows/rc003/src/ovb_rc003/ble_transport_winrt.py)：WinRT 设备发现、GATT 服务/特征、通知和重连；
- [`atvv_protocol.py`](https://github.com/miaomiaozii/windows-remote-mic-app/blob/271ed7947eec19c4c691ed3ba97f338461be8051/apps/windows/rc003/src/ovb_rc003/atvv_protocol.py)：ATVV 命令、能力和 ADPCM 解码；
- [`audio_playback.py`](https://github.com/miaomiaozii/windows-remote-mic-app/blob/271ed7947eec19c4c691ed3ba97f338461be8051/apps/windows/rc003/src/ovb_rc003/audio_playback.py)：音频端点、16→48 kHz 连续重采样和 PCM 写入；
- [`raw_input_windows.py`](https://github.com/miaomiaozii/windows-remote-mic-app/blob/271ed7947eec19c4c691ed3ba97f338461be8051/apps/windows/rc003/src/ovb_rc003/raw_input_windows.py)：Windows Raw Input；
- [`win32_input.py`](https://github.com/miaomiaozii/windows-remote-mic-app/blob/271ed7947eec19c4c691ed3ba97f338461be8051/apps/windows/rc003/src/ovb_rc003/win32_input.py)：键盘注入。

## 最佳源码基线

### 选择：miaomiaozii/windows-remote-mic-app

这是当前最适合继续验证的源码基线，原因是：

- 它就是当前仓库的 fork，许可证同为 GPL-3.0-only；
- Windows 代码已经从 macOS 主线中独立出来，产品名、设备画像和 RC003 交互最接近本项目；
- 最新固定提交有成功的 [Windows CI](https://github.com/miaomiaozii/windows-remote-mic-app/actions/runs/30610405749)；
- 发布了 [`v0.1.0-windows-rc003-candidate.1`](https://github.com/miaomiaozii/windows-remote-mic-app/releases/tag/v0.1.0-windows-rc003-candidate.1)；
- README 声明完成了真实 RC003 配对、十三键和语音识别验收；
- 相比早期上游，增加了重复按键边沿、语音触发时序、设置保存、Frida HID tap 和豆包输入法兼容修复。

它不是可直接导入当前 Swift 包的“库”，而是一套独立 Windows 应用源码。推荐将其视为 Windows 产品主线，而不是把 Python 文件混入 macOS Swift target。

### 不能直接宣布正式可用的原因

1. 发布的 EXE 没有 Authenticode 签名；PE Security Directory 为空，README 也明确标记为 unsigned。
2. Release 仍是 prerelease，公开下载量和设备覆盖很低。
3. 真机结论来自维护者声明，本次没有独立 Windows 主机和 RC003 复现。
4. 源码中仍残留 “not yet real-device verified” / “UNVERIFIED” 文案，与顶层 README 的已验收状态不一致。
5. 发布的 portable ZIP 实际包含 Frida Python 模块、Frida Gadget 和 VB-CABLE 包，但 Inno Setup 源码注释仍声称“不包含 Frida binary”。发布边界文档与产物必须先统一。
6. 完整按键和豆包兼容依赖跨进程注入，安全软件、Windows 更新和目标进程版本都可能造成回归。
7. 当前候选缺少当前 macOS 产品已有的可信公开签名、公证等价物、自动更新、多语言、配置导入导出、使用统计、用户可调增益和测试音等产品能力；当前决策不购买 Windows 可信公开签名，这一差异将长期存在。

## Windows 权限与系统能力变化

| 权限或能力 | 基础 RC003 麦克风 | 完整按键 | 正式产品建议 |
| --- | --- | --- | --- |
| 蓝牙配对 | 用户在 Windows 设置中确认 | 同左 | 不自动配对，不保存真实蓝牙地址 |
| WinRT BLE/GATT | 普通桌面进程可使用 | 同左 | 固定 Windows 10 1809+，验证缓存和重连 |
| 麦克风隐私授权 | Remote Mic 自身通常不需要，因为它写播放端点 | 同左 | 最终消费 `CABLE Output` 的输入法可能受 Windows 麦克风隐私设置影响 |
| Raw Input | 不需要管理员 | 读取普通按键 | 按 VID/PID/设备路径过滤，避免误收键盘 |
| SendInput | 不需要单独授权 | 需要 | 受 UIPI 限制，不能保证控制管理员权限应用 |
| VB-CABLE 驱动 | 若要成为系统麦克风则需要 | 同左 | 用户显式确认，UAC 安装，提示重启和第三方许可 |
| Frida/WUDFHost 注入 | 麦克风主链路不需要 | 完整 HID 报告可能需要 | 设为可选高级能力；默认版本不应静默提权或注入 |
| 豆包 ImeService 附加 | 音频本身不需要 | 只为特定语音快捷键物理化 | 不应成为通用 Windows 版的强制依赖 |
| Windows 防火墙 | 当前直接 fork 不需要公网监听 | 不需要 | 若采用本机 UDP 子进程，只绑定 loopback 并避免公网规则 |
| 应用签名 | unsigned 可运行但会有 SmartScreen | 同左 | 当前使用免费自签 Authenticode；不获得默认系统信任 |
| 内核驱动签名 | 使用官方 VB-CABLE 时由厂商承担 | 自研虚拟麦克风才需要 | 第一版不自研驱动；长期方案需 WDK、签名和驱动发布流程 |

微软文档佐证：

- [Bluetooth GATT client](https://learn.microsoft.com/en-us/windows/uwp/devices-sensors/gatt-client)；
- [`BluetoothLEDevice`](https://learn.microsoft.com/en-us/uwp/api/windows.devices.bluetooth.bluetoothledevice)；
- [`SendInput`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput) 明确说明受 UIPI 限制；
- [Kernel-mode code signing policy](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/kernel-mode-code-signing-policy--windows-vista-and-later-)；
- [Virtual audio devices](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/virtual-audio-devices)。

## Windows 应用代码签名从哪里来

Windows 可执行文件使用 **Authenticode**，它与 Apple Developer Program、Developer ID 和 Apple 公证没有关系。macOS 现有证书、Keychain 身份、`notarytool` profile 和 Sparkle EdDSA 密钥都不能作为 Windows 代码签名身份。

### 当前项目决定

**Windows 版本之后只使用免费自签证书，不购买 Microsoft Artifact Signing 或公共 CA Authenticode 证书。**

这意味着：

- Windows 应用、helper 和安装器仍可以带 Authenticode 数字签名；
- 签名可以用于校验文件签名后是否被修改，并让项目核对固定证书指纹；
- 普通 Windows 默认不信任该自签证书；
- 文件属性可能显示签名链不受信任，安装时仍可能显示“未知发布者”；
- Microsoft Defender SmartScreen 仍可能阻止或警告；
- 不能把自签产物宣传为“受 Microsoft 信任”或“已验证发布者”；
- 不要求普通用户把本项目自签证书导入系统根证书存储，因为这会扩大该证书的信任范围；
- 用户侧主要依靠 GitHub Release 来源、SHA-256、GitHub asset digest 和公开证书指纹核验下载完整性。

付费方案继续记录在下文，只作为未来成本参考，不属于当前计划。

### 可选来源

#### 方案 A：Microsoft Artifact Signing（付费，不采用）

[Microsoft Artifact Signing（原 Trusted Signing）](https://learn.microsoft.com/en-us/azure/trusted-signing/overview) 是 Azure 提供的云端代码签名服务。通常需要：

- Azure 订阅；
- 在支持的国家/地区和订阅类型内开通资源；
- 完成发布者身份验证；
- 创建证书配置文件；
- 在 Windows CI 中通过 SignTool/Trusted Signing 集成完成签名。

私钥由服务托管，不需要把 PFX 放入 GitHub Secrets 或开发机。是否可用取决于届时的地区、主体类型和身份验证资格，正式采用前必须在发布主体账号中实际确认。

微软在 2026-07-31 公开价格页显示的美元参考价：

| SKU | 基础费用 | 月签名额度 | 超额价格 |
| --- | --- | --- | --- |
| Basic | 9.99 美元/月 | 5,000 次 | 0.005 美元/次 |
| Premium | 99.99 美元/月 | 100,000 次 | 0.005 美元/次 |

价格来自 [Artifact Signing pricing](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/)，实际账单会受地区、币种、税费和 Azure 协议影响。微软 FAQ 说明按所选 SKU 收取整月费用，不按启用日期按比例折算，并且需要付费 Azure 订阅。

#### 方案 B：公共 CA 签发的 Authenticode 证书（付费，不采用）

可以向提供 Windows Code Signing 的公共证书机构购买 OV/EV 或其当时提供的等效代码签名产品，例如 DigiCert、GlobalSign、Sectigo 等。应以采购时 Microsoft/CA 的最新信任和合规要求为准，不在项目中固定推荐某一家。

现代公开代码签名证书通常要求私钥保存在合规硬件令牌、HSM 或 CA 云签名服务中，不能把普通 PFX 私钥直接提交仓库。采购主体名称会显示在 Windows 的“已验证的发布者”信息中，因此应使用稳定、可长期验证的个人或公司法律主体。

这类证书通常是每年数百美元，具体取决于 CA、OV/EV 或等效产品、硬件令牌、云签名和购买年限。该费用与 Apple Developer Program 费用完全独立，不能互相抵扣或复用。

#### 方案 C：免费自签名证书（当前采用）

自签名证书的证书采购费用为 0，可以在受控 Windows 构建机上创建并用于 Authenticode 签名。普通用户的 Windows 不会默认信任它，也不能解决公开发行的“未知发布者”和 SmartScreen 问题。

### 费用决策

| 方案 | 证书/服务成本 | 当前是否采用 | 用户默认信任 |
| --- | --- | --- | --- |
| Microsoft Artifact Signing Basic | 约 9.99 美元/月 | 否 | 是，满足服务条件时 |
| Microsoft Artifact Signing Premium | 约 99.99 美元/月 | 否 | 是，满足服务条件时 |
| 公共 CA Authenticode | 通常每年数百美元 | 否 | 是，证书链有效时 |
| 自签 Authenticode | 0 | **是** | **否** |

当前发布策略：

1. 在专用 Windows 发布环境生成项目自签代码签名证书；
2. 私钥不得写入仓库、Release、日志或普通 CI artifact；
3. 尽量跨版本沿用同一发布证书，并公开证书 SHA-256 指纹，方便用户发现异常更换；
4. 签署本项目的 EXE、DLL 和安装器；
5. 发布每个资产的 SHA-256 和 GitHub digest；
6. 在发布说明中明确“免费自签，Windows 默认不信任，可能出现 SmartScreen/未知发布者提示”；
7. 证书到期或主动轮换时，同时发布旧、新证书指纹和变更说明；
8. 不引导普通用户把自签证书安装为系统受信任根证书。

### 应签哪些文件

Windows 正式产物至少需要覆盖：

- 主程序 `RemoteMicRC003.exe`；
- 本项目构建的 helper EXE 和 DLL；
- Inno Setup/NSIS 安装器 EXE，或 MSI；
- 卸载器中由本项目生成且支持预签名的可执行组件；
- 自动更新组件和以后新增的本项目二进制。

portable ZIP 本身不是 Authenticode 可执行文件，通常通过以下方式保证完整性：

- ZIP 内所有本项目 EXE/DLL 先完成自签 Authenticode 签名；
- Release 同时发布 SHA-256；
- 核对 GitHub asset digest；
- 如有独立更新清单，再对更新清单做单独签名。

第三方二进制应保留并验证原厂签名，不应修改后冒充本项目重新签名。特别是 VB-CABLE 驱动应使用 VB-Audio 提供的原始签名产物；本项目不签署、不改写其 `.sys`、`.cat` 或厂商安装器。

### 应用签名不等于驱动签名

Windows 应用的 Authenticode 签名不能直接用于发布新的内核驱动。如果以后自研虚拟麦克风驱动，还需要独立的 Windows Hardware Developer Program、驱动包签名和 Microsoft attestation/HLK/WHQL 等届时适用的流程，参考微软的 [Driver code signing requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-reqs)。

第一版使用原厂 VB-CABLE 时，驱动签名由 VB-Audio 承担；本项目只需要签自己的应用和安装器，并在安装前验证 VB-Audio 原始驱动签名和固定哈希。

### SmartScreen 预期

可信公共 Authenticode 签名可以显示经验证的发布者并证明文件签名后未被修改，但也不保证新证书、新产品第一次发布时绝对不出现 SmartScreen 提示。当前采用的是自签证书，系统默认不信任其证书链，因此更不能承诺消除警告。发布文档只能声明文件具有本项目自签签名，并提供证书指纹和下载哈希供人工核验。

微软的签名工具和验证入口：

- [Cryptography tools / SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/cryptography-tools)；
- [SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)。

## Windows 与 macOS 必须独立打包

两端只能共享协议设计、设备定义、品牌版本和部分测试向量，不能共享最终构建或发布产物。

| 发布环节 | macOS | Windows |
| --- | --- | --- |
| 构建主机 | macOS + Xcode/Swift 工具链 | Windows x64 + Python/PyInstaller/Inno Setup，或未来选定的 Windows 工具链 |
| 应用格式 | `.app` | `.exe` |
| 安装格式 | `.pkg` + `.dmg` | Inno/NSIS `.exe` 或 `.msi`；可另提供 portable `.zip` |
| 应用签名 | Apple Developer ID Application | 免费自签 Authenticode，不受 Windows 默认信任 |
| 安装器签名 | Developer ID Installer | 使用同一 Windows 自签发布证书签署安装器 EXE/MSI |
| 平台审核 | Apple notarization + staple | 无 Apple 公证；验证自签签名、证书指纹、哈希和 SmartScreen/Defender 行为 |
| 音频驱动 | `MiRemoteV2ch.driver`，CoreAudio HAL | 第一版使用原厂 VB-CABLE；以后自研驱动需单独 Windows 驱动发布流程 |
| 自动更新 | Sparkle ZIP + appcast + EdDSA | 必须使用独立 Windows 更新器/更新清单；不能读取 macOS Sparkle 包 |
| 卸载 | macOS PKG/脚本边界 | Windows Apps & Features/卸载器，并单独处理是否保留 VB-CABLE |
| 验证命令 | `codesign`、`pkgutil`、`spctl`、`stapler` | `signtool verify`、PowerShell `Get-AuthenticodeSignature`、安装/卸载实测 |

### 强制发布边界

- Windows 构建不能调用或依赖 macOS 的 `build-app.sh`、`build-dmg.sh`、Developer ID、`notarytool` 或 Sparkle appcast；
- macOS 构建不能打包 Windows EXE、VB-CABLE 或 Windows helper；
- 两个平台分别维护依赖锁定、SBOM、签名验证、安装升级和卸载测试；
- 可以使用相同的营销版本号，例如 `1.5.0`，但应有各自的构建编号、最低系统版本和发布检查；
- 即使在同一个 GitHub Release 页面发布，也必须使用明确的平台文件名，并由两个独立 CI job 生成，不能在一台主机上把另一平台的旧产物直接拼入安装包；
- Windows 首个正式版本应发布 Windows 专用 release notes，明确系统要求、RC003、VB-CABLE、UAC、重启和已知限制。

## 安装过程差异

### 基础应用

当前候选使用 Inno Setup，默认安装到 `%LOCALAPPDATA%\RemoteMic\RC003`：

```text
运行未签名安装器
→ SmartScreen 可能警告
→ 当前用户目录安装应用
→ 创建设置/启动/停止/卸载入口
→ 用户在 Windows 设置中配对 RC003
→ 应用内选择设备和音频输出端点
```

这一部分可以不请求管理员权限，也不安装服务或内核驱动。

### 把 RC003 变成“系统麦克风”

```text
安装基础应用
→ 用户选择安装/修复 VB-CABLE
→ Windows UAC
→ 运行 VB-Audio 原始驱动安装器
→ 重启 Windows
→ Remote Mic 选择 CABLE Input
→ 输入法选择 CABLE Output
```

VB-CABLE 不是本项目的 GPL 代码，也不是开源库。是否允许随包分发、商业使用和品牌展示必须按 VB-Audio 的实际许可单独确认；即使技术上能打包，也不能仅凭 Donationware 描述推断全部分发权。

### 完整按键高级组件

候选为部分 RC003 HID 报告使用 Frida Gadget：

```text
识别 RC003 对应的 WUDFHost.exe
→ 用户显式以管理员权限运行
→ 获取 SeDebugPrivilege
→ 把已校验的 Gadget DLL 注入 WUDFHost
→ 通过本机 socket 取得 HID 报告
→ 低级键盘钩子抑制原生重复事件
→ SendInput 执行用户映射
```

该路径不是普通“辅助功能授权”，而是高风险进程注入。第一版正式产品应允许用户完全不启用它，并保证 BLE 麦克风仍然可用。

## 当前 macOS 功能在 Windows fork 中的覆盖

| 当前产品能力 | Windows fork 状态 | 结论 |
| --- | --- | --- |
| RC003 ATVV 麦克风 | 已实现，上游声明真机通过 | 核心可复用 |
| 输出到虚拟麦克风 | 通过 VB-CABLE | 可用，但安装与许可不同 |
| 用户选择音频端点 | 已实现 | 可保留 |
| 不修改默认输入/输出 | 已实现为显式选择 | 应继续保持 |
| 0–24 dB 用户可调增益 | 协议层支持安全增益，当前界面固定约 +10 dB | 产品功能缺口 |
| 1 秒测试音 | 未找到对应产品功能 | 产品功能缺口 |
| 13 个实体按键 | 已实现，上游声明真机通过 | 完整体验依赖 HID tap |
| 单击/双击/长按 | 有按钮手势模块与映射逻辑 | 仍需逐键真机验收 |
| 自定义组合快捷键 | 已实现 | 受 SendInput/UIPI 约束 |
| 打开应用 | 已实现 Windows 动作执行 | 需要补齐当前产品预置和聚焦策略 |
| 蓝牙自动重连 | 有 connection supervisor | 需长时间稳定性验收 |
| 设置页与诊断 | Qt/QML 已实现 | 目前主要为中文 |
| 中英文即时切换 | 未实现当前同等级本地化 | 产品功能缺口 |
| 配置导入导出 | 未发现 | 产品功能缺口 |
| 本地使用统计 | 未发现 | 产品功能缺口 |
| 自动更新 | 未发现正式更新框架 | 产品功能缺口 |
| 可信公开签名 | 当前决定不采购 | 接受未知发布者和 SmartScreen 提示 |

## 推荐实施路线

### 阶段 0：固定源码与法律边界

- 以 `271ed7947eec19c4c691ed3ba97f338461be8051` 或后续经过审查的固定提交为基线；
- 保留 GPL 来源和上游归属；
- 核对 Frida、Qt、PortAudio、NumPy、VB-CABLE 的分发义务；
- 统一 README、安装器注释和实际 Release 内容。

### 阶段 1：只验证最重要的麦克风链路

- Windows 11 x64 + 真实 RC003；
- 不启用 Frida，不注入 WUDFHost 或 ImeService；
- 完成配对、GATT 订阅、按住说话、ADPCM 解码、CABLE Input 输出；
- 在 Windows 听写、豆包输入法和至少一个通用语音应用中分别验证；
- 测量首帧延迟、丢帧、增益、长时间重连和睡眠唤醒。

只有这一阶段通过，才说明 Windows 版本满足“麦克风最重要”的核心目标。

### 阶段 2：安全的普通按键

- 先只使用 Raw Input 和 SendInput；
- 列出无需管理员权限即可稳定识别的按键；
- 明确管理员应用不受普通映射控制的 UIPI 限制；
- 复用当前产品的映射语义，而不是直接复制 macOS key code。

### 阶段 3：可选完整 HID tap

- 对 Frida/WUDFHost 路线做单独威胁模型和杀毒软件兼容测试；
- 明确启用、停用、升级和崩溃恢复；
- 不让注入失败阻断麦克风；
- 若长期维护成本过高，接受少数按键不可映射，或研究正式驱动替代。

### 阶段 4：正式发布

- 创建并安全保管免费 Windows 自签 Authenticode 证书，签署应用、helper 和安装器；
- 发布自签证书 SHA-256 指纹和全部资产 SHA-256，并明确未知发布者/SmartScreen 预期；
- 使用独立 Windows CI 构建 EXE/MSI/portable ZIP，不复用 macOS APP/PKG/DMG 或发布脚本；
- 固定第三方资产哈希并生成 SBOM；
- 在干净 Windows 10 1809、Windows 11 当前稳定版上验证安装/升级/卸载；
- 明确 VB-CABLE 的安装、重启和卸载边界；
- 增加自动更新前，先解决应用与驱动不能原子更新的问题。

## 验收门槛

正式宣布“Windows 支持”前，至少需要：

1. 两台不同蓝牙芯片的 Windows 11 机器，以及一台最低支持版本机器；
2. 三只 RC003 或至少两个不同固件/批次；
3. 连续 8 小时运行、睡眠/唤醒、蓝牙开关和设备离线恢复；
4. 连续 100 次语音按下/释放无卡死、无首音节稳定丢失；
5. CABLE Input/Output 方向错误时有明确诊断；
6. 无 Frida 模式下麦克风完全可用；
7. 启用 Frida 时安全软件、UAC、崩溃和升级行为可解释并可恢复；
8. 安装器、应用和所有本项目二进制完成自签签名、证书指纹、哈希和来源核验；
9. 卸载不会删除用户未授权删除的第三方驱动，也不会残留本项目注入进程；
10. 不把上游 README 的真机声明当作本项目自己的验收结果。

## 最终建议

**Windows RC003 最佳可用源码基线：`miaomiaozii/windows-remote-mic-app`。**

推荐把它作为独立 Windows 产品主线继续验证，优先保留：

- WinRT BLE/GATT；
- ATVV 会话与 ADPCM 解码；
- 显式音频端点选择；
- PortAudio 输出；
- 配置、诊断和失败关闭策略；
- Windows CI 与安装器结构。

第一版不应强制依赖：

- Frida 注入 WUDFHost；
- 附加豆包 ImeService；
- 自研虚拟音频驱动；
- Apple A2854 支持。

其中 Apple A2854 已明确移出当前 Windows 工作范围。相关文档只作为历史研究资料保留，不触发开发、验证或发布工作。
