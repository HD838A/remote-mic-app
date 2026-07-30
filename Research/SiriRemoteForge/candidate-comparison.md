# Wand、siri-remote-steamos、SiriRemoteVibe 深度对比与最终选型

- 研究日期：2026-07-30
- 当前目标：为 macOS“无线麦”增加第三代 Siri Remote（A2854）支持
- 首要条件：遥控器麦克风必须可用
- 次要条件：按键、触摸板、页面滚动、正式安装和后续维护可接受
- 本次行为：只读研究、离线构建验证和 Release 产物核验；没有修改或安装任何应用代码、HAL、LaunchDaemon 或 Bluetooth 系统配置

## 最终结论

**跨所有已研究项目，当前最佳可用源码基线是 [HOLODATA-COM/SiriRemoteForge](https://github.com/HOLODATA-COM/SiriRemoteForge/tree/10581a960f0738e36516defb79db24b18df214d3)。**

理由：

1. 它是三个关键能力中唯一同时覆盖 macOS 按键、触摸/滚动和已记录实机麦克风链路的上游项目；
2. `mkliu/SiriRemoteVibe` 直接建立在 SiriRemoteForge 历史上，只比指定 Forge 提交多两个提交，不是独立麦克风实现；
3. SiriRemoteVibe 没有 Tag 或 Release，其绿色 CI 不构建和测试 `mic/`，而且改写了上游明确用于修复真实 CoreAudio 多客户端问题的 HAL 读取模型，衍生版本没有新的实机验证记录；
4. `wongsiufool/wand` 是三个新增候选里发布成熟度最高、最适合参考按键/触摸的项目，但它完全没有遥控器麦克风；
5. `ahmedalqamzi/siri-remote-steamos` 的麦克风协议实现可信度较高，但运行平台是 SteamOS/Linux，核心依赖 BlueZ、D-Bus、PipeWire 和 `/dev/uinput`，不能作为当前 Swift/macOS 项目的直接依赖。

因此推荐：

- **总体源码基线：SiriRemoteForge；**
- **按键/触摸的第二参考：Wand；**
- **BLE/Opus 协议的交叉验证：siri-remote-steamos 内含的 Rust `siri-remote`；**
- **不选择 SiriRemoteVibe 作为主线，除非其差异先回到 SiriRemoteForge 上游并完成真实 A2854 麦克风验收。**

## 重要限定：这三个都不是完整的可嵌入库

| 项目 | 实际交付形态 | 是否可直接作为当前 SwiftPM 依赖 |
| --- | --- | --- |
| Wand | macOS 可执行菜单栏 App | 否；`Package.swift` 产物是 executable，且 SwiftPM 构建不包含私有 `MultitouchSupport` |
| siri-remote-steamos | SteamOS 安装包、Rust CLI、GTK/Python 管理层 | 否；Rust crate 只声明 binary，且依赖 Linux BlueZ/PipeWire |
| SiriRemoteVibe | 完整 macOS App + HAL + daemon + router | 只有 `SiriRemoteCore` 是 Swift library；HID、触摸和麦克风仍是 App/系统组件，不是一个可直接导入的统一库 |

所以这里的“最佳库”实际应理解为“最适合作为集成源码基线的仓库”。

## 快速决策表

| 评估项 | Wand | siri-remote-steamos | SiriRemoteVibe | SiriRemoteForge |
| --- | --- | --- | --- | --- |
| 目标平台 | macOS 11+ | SteamOS 3 x86_64 | macOS 13+ | macOS 13+ |
| 第三代 A2854 | 支持声明；产品 ID 表包含部分变体 | 明确只支持第三代 | 明确只支持第三代 | 明确只支持第三代 |
| 按键 | 有 | 有 | 有，功能丰富 | 有，功能丰富 |
| 触摸/页面滚动 | 有源码实现 | 触摸手势转导航键，不是 macOS 连续滚动 | 有，含连续/圆周滚动 | 有，含连续/圆周滚动 |
| 遥控器麦克风 | **没有** | **有，仅 Linux/PipeWire** | **有，继承 Forge；衍生改动未实机验证** | **有，PacketLogger/HAL 路径有上游实机记录** |
| 可下载 Release | v0.2.0 notarized DMG | v1.0.0 tar.gz + SHA-256 | 无 | 研究时无公开 Release 资产 |
| macOS 正式签名 | Developer ID + Hardened Runtime + 公证 | 不适用 | ad-hoc、非 Hardened Runtime | ad-hoc、非 Hardened Runtime |
| 系统侵入性 | 低 | 高：禁用 BlueZ `input`/`hog` | 完整麦克风时高 | 完整麦克风时高 |
| 许可证 | MIT | GPL-3.0 | GPL-3.0-or-later | GPL-3.0-or-later |
| 适合当前项目的角色 | 输入/触摸参考 | 协议参考 | 不建议替代上游 | **主源码基线** |

## 1. wongsiufool/wand

- 研究提交：[`e5bbbec5f5c25e7a443ed79b70e345cef4ed50c8`](https://github.com/wongsiufool/wand/tree/e5bbbec5f5c25e7a443ed79b70e345cef4ed50c8)
- 公开版本：[v0.2.0](https://github.com/wongsiufool/wand/releases/tag/v0.2.0)
- 许可证：MIT

### 定位和架构

Wand 是一个约 3,600 行 Swift 的轻量 macOS 菜单栏应用，核心文件包括：

- `RemoteDetector.swift`：IOHID 发现 Siri Remote；
- `RemoteInputHandler.swift`：seize HID 接口、按键识别和动作映射；
- `TouchHandler.swift`：私有 `MultitouchSupport` 触摸回调；
- `CursorController.swift`：鼠标、点击和 `CGEvent` 像素滚动；
- `RemotePanelController.swift`：图形化映射面板。

它不是一个 library target。`Package.swift` 只声明 executable，而且注明 SwiftPM 构建不包含私有 `MultitouchSupport`；完整触摸能力必须走自带的 `build.sh`。

### 功能

源码实现了：

- 一指移动鼠标；
- 两指像素滚动；
- 轻点点击；
- 中心实体按压点击和 hold-to-drag；
- 方向环点击；
- 单击/双击映射；
- 快捷键学习、文字输入、打开 App；
- 辅助功能和输入监控授权入口；
- A1513/A1962、A2540、A2854 的型号展示。

### 权限、签名和安装

- 用户权限：辅助功能、输入监控；Info.plist 还有蓝牙用途说明；
- entitlement：Bluetooth、Disable Library Validation、Allow DYLD Environment Variables；
- 不安装 HAL、daemon 或 root helper；
- 安装方式是打开 DMG 后拖入 Applications；
- `v0.2.0` 的 Tag 与当前研究提交一致。

本次重新下载并验证了 `Wand-0.2.0.dmg`：

- SHA-256：`5efe52539bf4a42d0cbaf4c97b8ead1bbd42b70bf95a01902d2b57a9a445d95c`；
- `xcrun stapler validate` 通过；
- `spctl` 接受，来源为 `Notarized Developer ID`；
- 签名主体：`Developer ID Application: Kaihong Chen (DBYWRB2S9S)`；
- App 启用了 Hardened Runtime；
- App 和 DMG 的 Gatekeeper 检查均通过。

### 主要问题

1. **没有遥控器麦克风。** 搜索整个仓库没有 Opus、PacketLogger、HAL 或 audio HID 麦克风链路。
2. `TouchHandler.swift` 的多指 pinch 分支明确注明未在硬件上跑通，并记录测试时遥控器没有发出触摸帧。该注释至少说明触摸硬件验收不完整，不能只依据 README 承诺稳定性。
3. `AppleRemoteModel.identify` 能识别产品 ID `0x0315`，但 `RemoteDetector.knownProductIDs` 列表没有 `0x0315`；当前通常会由名称 fallback 命中，但精确匹配表不一致。
4. 设备分组只使用 `vendorID:productID`，两只同型号遥控器会被当成同一物理设备，当前项目若只支持单遥控器影响较小。
5. 没有测试 target 和 GitHub Actions 记录；Release 可验证的是签名/公证，不是物理遥控器端到端行为。

### 对当前项目的价值

Wand 是**最好的轻量按键/触摸参考**，原因是：

- macOS/Swift 技术栈一致；
- MIT 许可证易于参考和移植；
- 代码量小，输入、触摸、鼠标边界清楚；
- 已存在真正可下载、签名、公证的产物。

但麦克风是硬要求，因此 Wand 不能成为最终总体方案。

## 2. ahmedalqamzi/siri-remote-steamos

- 研究提交：[`2dbf7e7e7f503a52c88a4f3c4c193dc0b782f28d`](https://github.com/ahmedalqamzi/siri-remote-steamos/tree/2dbf7e7e7f503a52c88a4f3c4c193dc0b782f28d)
- 公开版本：[v1.0.0](https://github.com/ahmedalqamzi/siri-remote-steamos/releases/tag/v1.0.0)
- 许可证：GPL-3.0

### 定位和架构

它是 SteamOS 3 x86_64 的完整安装包，不是通用跨平台驱动库：

```text
GTK4 设置 App
→ BlueZ 配对和适配器选择
→ user systemd service
→ Rust siri-remote 进程
→ 按键/触摸事件 + Opus 麦克风
→ Python evdev bridge / PipeWire
→ 虚拟 Xbox 控制器、导航键、媒体键、麦克风
```

仓库内置了 `azais-corentin/siri-remote` 的完整对应源代码，并增加：

- `--adapter` 等 SteamOS 多蓝牙适配器能力；
- 麦克风和按钮共用同一个 BLE 连接；
- `--print-events`，让 PipeWire 麦克风进程同时输出控制事件；
- Python `evdev.UInput` 虚拟 Xbox/媒体/导航设备；
- GTK4 安装、配对、诊断、修复和卸载界面；
- 自动重连的 user systemd service。

### 麦克风

这是三个新增候选中协议层最直接的麦克风实现：

```text
A2854 BLE HID
→ BlueZ 直接访问多个 0x2A4D Report characteristic
→ 写入 0xAF 启用输入
→ 订阅 0xFA
→ Opus 解码
→ PipeWire Audio/Source
```

它不需要 PacketLogger，因为 Linux 可以通过调整 BlueZ ownership 直接取得 HID-over-GATT。Rust 源码包含 0xFA parser、Opus decoder、丢包补偿和 PipeWire ring。

### 安装和系统影响

安装器会：

- 将 App、driver 和源码安装到用户的 `~/.local/share/siri-remote`；
- 安装并启用 user systemd service；
- 通过 `pkexec` 写入 `/etc/systemd/system/bluetooth.service.d/siri-remote.conf`；
- 把 `bluetoothd` 启动参数改成 `--noplugin=input,hog`；
- 重启 Bluetooth 服务。

禁用 `input` 和 `hog` 是高影响行为：其他蓝牙键盘、鼠标和手柄可能停止正常工作。卸载器会恢复标准 BlueZ 配置，但安装期间这个系统级冲突始终存在。

### Release 核验

本次下载并检查了 `Siri-Remote-for-SteamOS-v1.0.0.tar.gz`：

- 大小：3,322,039 bytes；
- SHA-256：`ae6df803aab13fa0bd3d3abb50bca3ef7149bb0edf416ec5cc7d6bf130fd92ee`；
- 与 Release 中 `.sha256` 文件一致；
- 包含安装器、卸载器、GTK App、systemd unit、root helper、Python bridge、完整 GPL 源码；
- 主程序是 x86-64 Linux ELF，动态依赖 `libdbus-1.so.3`、`libopus.so.0` 等 Linux 运行库；
- Release 内容与研究提交基本一致，额外包含安装用 icon 目录。

本机是 macOS，不能执行 SteamOS ELF；当前环境也没有 Cargo，因此没有重复运行 Rust 测试。仓库文档称除两个需要未公开 `microphone-dump.txt` fixture 的测试外，其余 62 项通过，但 `HANDOVER.md` 的硬件 acceptance checklist 仍是未勾选状态，仓库也没有 GitHub Actions 工作流。

### 对当前项目的价值

它适合用来：

- 交叉验证 A2854 的 GATT、`0xAF`、`0xFA`、Opus 和触摸报告；
- 参考“按钮和麦克风共享单一 BLE session”的生命周期设计；
- 参考 Opus 丢包补偿和音频 ring。

它不适合成为当前项目主库，因为：

- CoreBluetooth/IOHID 不能复现 Linux BlueZ 对原始 HID service 的控制；
- PipeWire、D-Bus、systemd、uinput 和 GTK 都不是 macOS 组件；
- 禁用 BlueZ 插件的解决方式在 macOS 没有对应公开接口；
- 若把 Rust 协议代码移植到 Swift，仍然无法解决 macOS 收不到原始 0xFA 的入口问题。

## 3. mkliu/SiriRemoteVibe

- 研究提交：[`187e1eeeea5c8ae02c3e08a2b85040b0f3c9e6c8`](https://github.com/mkliu/SiriRemoteVibe/tree/187e1eeeea5c8ae02c3e08a2b85040b0f3c9e6c8)
- 许可证：GPL-3.0-or-later
- Tag/Release：无

### 与 SiriRemoteForge 的真实关系

SiriRemoteVibe 不是从零实现的另一套方案。它的 Git 历史包含 SiriRemoteForge 的提交，当前 main 相对 Forge 研究提交 `10581a960f07` 只领先两个提交：

1. `7c4c8ed02e1a`：增加 Fn/Globe 映射、repeatKey `.tap`、语音 parser/播放节奏和 HAL 读取改动；
2. `187e1eeeea5c`：精简 README，增加 `config.vibe-coding.jsonc`。

其 `NOTICE` 仍以 `SiriRemoteForge` 开头，`HANDOFF.md` 仍把 `HOLODATA-COM/SiriRemoteForge` 写成 canonical repository。这说明它是一个非常新的产品化/配置分支，而不是拥有独立维护和实机证据链的成熟 fork。

### 增加的能力

- `fn` / `function` / `globe` 可作为合成修饰键；
- `repeatKey` 可以区分短按 `.tap` 和继续按住后的 repeat；
- 默认 Vibe Coding 配置：Siri 短按 Enter、长按 Fn，Power 为 Escape，滑动切换 Spaces；
- parser 接受 ATT handle `0x0035` 和 `0x0036`；
- 离线 replay 使用绝对 mach deadline，理论上比逐帧 `usleep` 更不易累计漂移。

### 麦克风风险

SiriRemoteVibe 继承 SiriRemoteForge 的整个麦克风堆栈：

- PacketLogger；
- root capture daemon；
- Opus router；
- shared-memory ring；
- `Siri Remote Mic` HAL；
- built-in mic fallback；
- Full Setup/watchdog/uninstaller 脚本。

但它的首个自有提交把 HAL 从上游的“按 `mInputTime` 建立固定 timeline mapping”改成“顺序 cursor + `mIOCycleCounter` cache”。上游源码把 position-based 模型明确标为解决真实多客户端重读、音频被双倍消耗、断续和爆音问题的关键修复。

本次离线验证结果：

- `SiriRemoteCore`：101 tests 通过；
- App：成功编译并链接；
- Opus decoder self-test：通过；
- router parser 和 monitor ring：通过；
- HAL contract test：通过；
- HAL IO simulation：通过，离线 idempotency 为 0 mismatch。

这些结果说明该提交不是明显的编译错误，离线模型内部自洽。但仍不能证明它在真实 `coreaudiod` 多客户端调度下优于或等价于上游修复，原因是：

- GitHub CI 只有 `SiriRemoteCore` 和 App 编译两个 job；
- CI 没有运行 `mic/build-test.sh`、router、HAL contract 或 IO simulation；
- 没有 Tag、Release、Developer ID、公证或可下载产物；
- 没有该衍生提交之后的真实 A2854 → PacketLogger → HAL 听感验证记录；
- README 的快速开始只构建 ad-hoc、非 Hardened Runtime 的 `HyperVibe.app`，完整麦克风仍需用户手动处理 PacketLogger、HAL 和 daemon。

因此不能把 SiriRemoteVibe 的绿色 CI 当成“麦克风已验证”。

### 对当前项目的价值

可取之处：

- Vibe Coding 默认映射比 Forge 的通用文档更接近当前产品用途；
- Fn/Globe 合成和短按/长按区分值得单独研究；
- 仍保留 Forge 的完整源码和测试工具。

不应选作主线的原因：

- 麦克风实现不是独立证据，只是 Forge 的衍生；
- 自有 HAL 改动触及最敏感的实时 CoreAudio 路径；
- 没有 Release 和实机验收；
- README 被大幅精简后，许多系统风险和安装限制不如上游文档完整；
- 直接采用它会让当前项目同时承担 Forge 原有风险和 fork 差异风险。

## 最佳方案为什么不是三者中的某一个

如果强制只在三个新增候选里选择：

- **要求“现在能下载并在 macOS 正常打开”**：Wand 最好，但麦克风不满足；
- **要求“协议层麦克风直接、完整”**：siri-remote-steamos 最好，但平台不满足；
- **要求“macOS + 触摸 + 麦克风源码都在一个仓库”**：SiriRemoteVibe 唯一满足，但可用性和验证不足，而且其上游 SiriRemoteForge 更可信。

因此三选一本身没有同时满足全部硬条件的诚实答案。把范围扩展到已经研究的所有项目后，SiriRemoteForge 是更合理的唯一首选。

## 推荐接入边界

即使选择 SiriRemoteForge，也不建议把整个项目合并进当前仓库。推荐只把它当作以下边界的源码参考：

### 第一优先：麦克风输入后端

重点研究：

- `mic/router/PklgTailReader.swift`；
- `mic/router/VoiceFrameParser.swift`；
- `mic/OpusVoiceDecoder.swift`；
- `mic/captured/srm_captured.c`；
- `dist/do_install.sh` / `dist/do_uninstall.sh` 的 HCI 设置备份和回滚。

优先目标仍是把解码 PCM 送入当前项目已有的 `MiRemoteV 2ch` 输出路径，而不是第一版就安装第二个 `SiriRemoteMic.driver`。

### 第二优先：按键与触摸

- SiriRemoteForge：功能完整，圆周滚动、手势、layer、HUD 较丰富；
- Wand：代码更小、MIT、已有公证产物，适合交叉检查最小 HID/触摸实现。

触摸正式发布必须用当前项目自己的 Developer ID + Hardened Runtime + 公证产物实机验证，不能直接继承任何 README 的成功声明。

### 不建议直接引入

- SiriRemoteVibe 的 `mic/driver/SiriRemoteMic.c` 差异，除非真实多客户端硬件测试证明其 cycle-cache 模型安全；
- SteamOS 的 BlueZ/systemd/PipeWire/uinput 安装层；
- Wand 的完整设置 UI 和动作系统，因为当前项目已经有自己的设置和按键映射产品层；
- SiriRemoteForge/SiriRemoteVibe 的整个 `SiriRemoteCore`，除非未来明确决定替换当前映射模型。

## 最终排名

### 面向当前 macOS 无线麦产品

1. **SiriRemoteForge — 最佳总体源码基线**
2. **Wand — 最佳按键/触摸辅助参考**
3. **siri-remote-steamos — 最佳 Linux 协议交叉验证**
4. **SiriRemoteVibe — 功能表面最贴近，但不应优先于其上游**

### 只看三个新增候选

1. **Wand — 最可下载、最容易审计，但不满足麦克风硬要求**
2. **SiriRemoteVibe — 唯一同时包含 macOS 触摸和麦克风源码，但验证不足**
3. **siri-remote-steamos — 麦克风实现强，但不能直接用于 macOS**

最终工程决策不采用这个“三选一”排序，而采用跨所有候选的第一名：**SiriRemoteForge**。
