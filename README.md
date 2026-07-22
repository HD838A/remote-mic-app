# 小米蓝牙遥控器 2 Pro · macOS 桥接

这是 `remote-bridge-hub` 小米 RC003 桥接能力的原生 macOS 版本。它常驻菜单栏，负责：

- 自动发现、连接和重连小米蓝牙遥控器 2 Pro / RC003：精确匹配系统显示名称 `MI RC`、`Xiaomi Bluetooth Remote 2 Pro` 或“小米蓝牙语音遥控器”（trim 后比较，英文大小写不敏感），或命中 ATVV service UUID；不做任意“小米”设备的模糊匹配；
- 接收 Android TV Voice-over-BLE（ATVV）语音并解码为 16 kHz PCM；
- 把语音送到选定的 CoreAudio 输出设备，配合 BlackHole 作为会议、听写或 AI 应用的虚拟麦克风；
- 把 RC003 语音键真实上报的 F5 硬件按下/松开仅对该型号映射为 Mac Fn/🌐︎，应用退出时恢复原映射，用现有的 Fn 长按语音输入工具完成遥控器按住说话；
- 通过 IOHID 读取 RC003 原始按键报告，提供返回、主页、菜单、TV、音量等 macOS 动作映射。

## 当前状态

0.2.0 上游测试版已在一只 RC003 和 Apple Silicon Mac 上完成蓝牙连接、方向/确定/返回/主页/菜单/TV/音量按键、ATVV 语音、Fn 按住/释放与真实中文语音转文字验收。本 fork 的 0.2.2 新增豆包兼容虚拟麦克风：将独立的 BlackHole 派生驱动 `MiRemoteV 2ch` 标识为 USB transport，避免豆包过滤普通 virtual transport 设备。DMG 包含可双击的系统安装器，Universal 二进制和 macOS 11 部署目标仍需在目标机运行验收。

## 系统要求

- macOS 11 Big Sur 或以上（覆盖首批 M1 Mac 的出厂系统；菜单栏与设置窗口统一使用 AppKit 容器）；
- Apple Silicon 或 Intel Mac（源码兼容；`build-app.sh` 默认只生成当前 Mac 架构的应用包；`./scripts/build-app.sh --universal` 会分别构建 arm64 与 x86_64 并用 `lipo` 合并为通用二进制，`./scripts/verify-app.sh --universal` 会严格确认两种架构都在合并后的二进制中）；
- 已在“系统设置 → 蓝牙”中配对的小米蓝牙遥控器 2 Pro / RC003；
- 语音作为虚拟麦克风使用时，安装 [BlackHole 2ch](https://existential.audio/blackhole/) 或等价的可写 CoreAudio 回环设备。

应用不会自动安装音频驱动，也不会修改系统默认输入/输出设备；只有用户主动运行 DMG 中的系统安装器，才会安装 `MiRemoteV2ch.driver`。

## 构建

```bash
./scripts/test.sh
./scripts/build-app.sh
./scripts/verify-app.sh
open "dist/小米遥控器桥接.app"
```

生成真正包含 arm64 与 x86_64 的 Universal 候选包：

```bash
./scripts/build-app.sh --universal
./scripts/verify-app.sh --universal
```

`scripts/test.sh` 会运行不依赖 XCTest 的协议自测，再编译完整应用。安装了完整 Xcode 的开发机还可以额外运行 `xcrun swift test`；当前 macOS 26 Command Line Tools 自带的 Swift Testing 运行库路径不完整，因此不能只依赖它作为验收入口。

### 豆包兼容虚拟麦克风

如果 QuickTime 已能从 BlackHole 录到遥控器语音、豆包输入法仍没有反应，说明遥控器、ATVV 解码和回环输出已经正常；豆包是在过滤 virtual transport 设备。下载 DMG 后，双击其中的“安装豆包兼容麦克风.pkg”，按系统 Installer 提示授权即可；不需要 Xcode、Git 或终端命令。

安装器内置由固定 BlackHole `v0.7.1` 源码和项目内补丁构建的独立 `MiRemoteV2ch.driver`。实际音频 Device 报告为 USB transport，名称是 `MiRemoteV 2ch`，与 `BlackHole2ch.driver` 并存且绝不覆盖它。安装器校验驱动并重启 CoreAudio 后，在桥接应用“虚拟麦克风”中点击“刷新音频设备 → 选择 MiRemoteV 2ch”，再在豆包中使用该设备或完全重启豆包。

若要移除，双击 DMG 中的“卸载豆包兼容麦克风.pkg”。DMG 所附的构建和校验脚本仅供开发者复现、审计和发布构建使用。

首次启用自定义映射时，按系统提示允许：

1. 蓝牙：发现与连接 RC003；
2. 输入监控：读取遥控器原始 HID 报告，并在兼容模式下抑制重复系统事件；
3. 辅助功能：把映射后的按键动作发送给当前应用。

按键后端会先尝试设备级独占；如果 macOS 拒绝普通应用独占键盘类 HID，则自动退回非独占监听。退回后只在收到 RC003 原始按键报告后的 180 毫秒内抑制同一系统事件，降低双触发风险，并避免长期拦截其他键盘。若不授予输入监控或关闭“自定义按键映射”，macOS 仍可按普通蓝牙键盘处理它能识别的按键。

## 语音使用

1. 在应用设置中选择 `BlackHole 2ch`，或豆包兼容模式的 `MiRemoteV 2ch`，作为语音输出；
2. 在目标语音输入应用中选择同一个设备作为麦克风；
3. 按住遥控器麦克风键：macOS 会把该遥控器的真实 F5 硬件按下映射为 Fn，应用同时开始桥接 ATVV 语音；松开时硬件键直接释放 Fn 并结束语音流。

应用直接把音频写到所选设备，不会把 BlackHole 设为系统默认设备。

在不连接 RC003 的情况下，也可以在设置页“虚拟麦克风”区点击“发送 1 秒测试音”，验证所选设备链路是否可用：测试音只在内存生成、低音量、固定频率，不落盘；未选择设备或设备不可用时按钮不可用并给出说明；RC003 语音进行中时按钮禁用，且应用内部会再次拒绝，不会打断正在进行的语音流。

## 默认按键

| 遥控器按键 | macOS 动作 |
| --- | --- |
| 方向 / 确定 | 方向键 / Return |
| 返回 | Delete（退格） |
| 主页 | 显示桌面（Fn-F11） |
| 菜单 | Shift-F10 |
| TV | Command-Tab |
| 电源 | Escape（不会让 Mac 睡眠） |
| 音量 + / - | 系统音量增减 |

设置页使用保持原始比例的 RC003 实物图，点击真实实体按键位置会定位到右侧映射项；实物没有独立静音键，因此界面不再显示虚构的静音实体键。每个普通按键都可以改成预置动作（包括按需映射为系统静音）或禁用，选择后自动保存，也可一键恢复默认映射。语音键执行固定的“设备专属 F5→Fn 硬件映射 + ATVV 语音桥接”核心动作，不参与普通按键映射。

## 安全与隐私

- 不上传语音，不保存语音文件；PCM 只在内存与选定音频设备之间流动。
- 测试音同样只在内存生成，不落盘；不会自动更改系统默认音频设备，也不会打断正在进行的 RC003 语音流。
- 不保存真实蓝牙地址；macOS 只持久化系统提供的匿名外设 UUID。
- 权限不足、设备不匹配或音频设备不存在时失败关闭，并在状态页说明原因。
- 不自动安装、登录启动、提交、推送或发布。

## 来源与许可

ATVV UUID、握手、RC003 HID usage 与 IMA/DVI ADPCM 行为参考 GPL-3.0 项目 [xxb26553663-star/remote-bridge-hub](https://github.com/xxb26553663-star/remote-bridge-hub)。本适配版本统一按 `GPL-3.0-only` 发布；参考项目的品牌与商业资产不包含在本项目中。修改与归属说明见 `COPYRIGHT` 和 `THIRD_PARTY_NOTICES.md`。
