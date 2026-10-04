---
title: 遥控器卡片空白区域点击失效
template: doc
lang: zh
---

## 结论

卡片空白区域没有接入设备选择动作。候选修复已通过本机点击验证。
真实多设备、授权按钮及录音期间的回归仍待验收。

## 错误证据

- 用户报告：遥控器卡片只能点击文字，内部空白无响应。
- 基线：`8816bfd478388fe40b1c0f81cd095d63f0a114f9`。
- 分支：`codex/fix-remote-card-hit-area-20261005`。
- 复现使用生产 `SettingsView`，窗口为 `1020 × 772`。
- 配置来自既有截图入口，使用隔离的模拟设备。
- 修复前，点击连接页首张卡片右侧空白，界面没有变化。
- 点击同一卡片文字后，设备选择执行，截图夹具重新计算连接状态。
- 卡片文字可操作是正常边界；空白不能操作是错误边界。

## 根因与日志缺口

`Sources/RemoteMic/SettingsView.swift` 的 `remoteDeviceCard` 只把文字区域放入选择按钮。
外层 `HStack` 承载卡片留白、尺寸、背景和边框。
文字区域没有显式点击形状；外层留白没有点击入口。
上述结构与重复点击实验一致，根因置信度高。

未取得用户现场日志。既有设备选择入口没有独立点击坐标日志。
本次以界面动作和可访问状态变化确认根因。

链路为：鼠标点击 → 设备选择 → 原有状态刷新 → 选中描边与设备画布。
修复只改变点击入口，复用原有模型方法和日志边界。
没有新增异步、失败、取消、超时、重试或恢复路径。
不记录设备名称、UUID 或点击坐标。

## 最小修复

| 文件 | 必要变化 |
| --- | --- |
| `Sources/RemoteMic/SettingsView.swift` | 文字按钮增加矩形点击形状；卡片背景响应留白点击；描边不拦截点击 |
| `feature/button-mapping/PRODUCT_SPEC.md` | 明确整卡与边框范围执行同一动作 |
| `design-qa.md`、`design-qa.en.md` | 同步全局卡片点击规范及英文翻译 |
| `Testing/ConnectedRemoteCards.md` | 增加整卡点击用例和验证边界 |
| `TODO.md` | 同步既有设备卡任务的候选进度 |
| 本文、HTML 与 `Bugs/README.md` | 保存根因、验证和文档入口 |
| `Screenshots/remote-card-hit-area/` | 保存生产界面和图片摘要清单 |

背景使用单独的点击手势，前景按钮保留自身动作。
卡片没有嵌套按钮，也没有新增可访问选择项。
苹果卡片的启用、停用和重试继续由原有按钮处理。

## 验证命令与结果

| 检查 | 结果 |
| --- | --- |
| `swift build --disable-keychain` | 最终公开构建通过 |
| `swift test --disable-keychain --filter 'RemoteDeviceNamePolicyTests\|RemoteDeviceNameIntegrationTests\|physicalRemoteProfilesPersistIndependentMappingsAndBindings\|SiriRemoteActivationTests'` | 最终 37 项、4 个 suite 通过 |
| `swift test --disable-keychain --skip-build --filter SettingsPageRegressionTests` | 54 项设置页回归通过 |
| 固定私有源码的双硬件构建 | 通过；源码来自主线指定提交 `527e16ed0e12701a0fc22de945052e160c4c7e62` |
| `bash scripts/verify-repository-governance.sh` | 通过 |
| `git diff --check` | 通过 |
| 生产窗口点击 | 左侧边框内留白、横向卡片底部留白触发选择 |
| 横向苹果卡片选择 | 描边与画布切换；启用按钮仍显示，未自动启用服务 |
| 可访问状态 | 每张设备卡只有一个选择按钮；次要按钮独立显示 |
| 中英文、浅深色截图 | 两个页面共八张，另有空白点击后的选中截图 |

最初尝试运行裸二进制时，Sparkle 动态库路径不完整。
本机界面验证包补齐框架与本项目资源后正常运行。
早期本地私有源码较旧，构建出现接口不匹配。
改用主线指定的固定源码后，苹果与 Chromecast 构建通过。
这些失败没有导致修改产品代码或依赖版本。

## 截图证据

图片目录为 `Screenshots/remote-card-hit-area/`。
`manifest.json` 记录原始格式、尺寸、SHA-256 和源码摘要。
三张中文浅色图片来自原生窗口，原始格式为 JPEG。
其他六张来自生产离屏入口，原始格式为 PNG。
所有图片均为 `2040 × 1544` 像素。

没有重绘、缩放或重新压缩原始图片。
英文长型号按既有规则截断，完整名称保留在可访问标签中。
横向第三张卡片可滚动；本次不改变卡片布局。

## 验证边界

- 模拟连接数据只用于验证点击入口和显示。
- 选择设备会刷新真实连接集合，模拟卡片可随即消失。
- 因此该夹具不证明真实多设备连接或持续切换。
- 本机实点覆盖中文浅色；其他语言及外观只验证静态显示。
- VoiceOver 朗读、真实键盘操作和滚动后的点击仍待验证。
- 未执行真实 helper 授权、重试、停用及录音期间的禁用验收。
- 未验证真实遥控器、音频及第三方语音工具。
- 本次不提供安装包，不修改版本号，不发布更新。
- 验证步骤见 `Testing/ConnectedRemoteCards.md` 的用例 3B。

## 查重

2026-10-05 扫描全部 Open PR 的标题与标签。
相关活动 PR #577 只修改导入会员导航，不覆盖设备卡点击。
已检查该 PR 的描述、文件和代码差异。
历史 #479 统一设备卡信息，#572 增加主动启用入口。
这些改动已在主线；其描述及相关文件未实现本次空白点击修复。
