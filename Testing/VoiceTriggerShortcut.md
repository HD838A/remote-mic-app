# 语音触发自定义快捷键测试手册

适用分支：`codex/voice-trigger-shortcut-20261120`（候选实现，未合入）。产品规则以 [功能规范](../feature/voice-trigger-shortcut/PRODUCT_SPEC.md) 为准。

## 测试前准备

1. 确认 `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain` 和定向测试通过。
2. 使用 ROM 为 RC003 的实体遥控器，连接 Typeless 所在 Mac。
3. 在 Typeless 中设置一个可观察的翻译快捷键，例如 Fn + Shift + S；普通听写模式保持 Fn。
4. 在 SayAll 打开 按键映射 → 语音设置，语音键选择 Fn/地球键，开启“语音键模拟 Fn 点按”。
5. 授予辅助功能（新名称：设备控制和数据访问）和输入监控权限。
6. 在 Typeless 中确认音频输入与 SayAll 虚拟麦克风一致，并准备一个可输入文字的文本框。
7. 清空并保留一份不含 `voiceTriggerShortcut` 的旧配置，用于兼容导入。

## 用例 1：入口与模式门控

操作：

1. 保持 Fn + Fn 点按开启，打开语音设置。
2. 关闭“语音键模拟 Fn 点按”。
3. 改选左 Command，再改回 Fn 并重新开启点按。

预期：

- 步骤 1 显示“自定义语音触发（未设置（使用 Fn））”和“录入”按钮。
- 步骤 2 后整行隐藏，已保存值不丢失。
- 步骤 3 非 Fn 模式隐藏；恢复 Fn 点按后重新显示。
- 页面不出现下拉列表，所有操作在页面内完成。

失败判定：任何本应隐藏的模式仍显示该行，或重新开启后已保存值丢失。

## 用例 2：录制、拒绝裸键、重新录入与清除

操作：

1. 点击“录入”，只按 `S` 不按修饰键。
2. 点击“录入”，按 Fn + Shift + S。
3. 再次点击“重新录入”，只按 Fn + Shift，确认纯修饰键组合可录入。
4. 再次点击“重新录入”，按 Control + Option + K。
5. 点击“清除”。

预期：

- 步骤 1 不保存，显示“快捷键至少需要一个修饰键…”，且未写入设置。
- 步骤 2 显示组合键，日志出现 `VOICE TRIGGER phase=completed result=configured`、`has_function=true`。
- 步骤 3 显示 `⇧fn`，日志出现 `modifier_chord=true`；后续会话只发送 Fn/Shift 的按下与释放，不额外发送主键。
- 步骤 4 更新为新组合；步骤 5 显示未设置，日志 `result=cleared`。
- 日志不包含 `S`、`K`、完整组合或目标 App 名称。

失败判定：裸键被保存、清除后仍生效、日志出现按键内容。

## 用例 3：录音中禁止修改

操作：

1. 设置 Fn + Shift + S。
2. 按住 RC003 语音键并说一句话，保持按住。
3. 在设置页点击“重新录入”或“清除”。
4. 保持录音，关闭“语音键模拟 Fn 点按”。
5. 松开语音键，等待会话结束。

预期：

- 录音、排空或关闭阶段按钮禁用，模型层拒绝修改；不会出现写入一半的组合。
- 步骤 4 会导致 Fn 点按关闭，但当前会话仍用开始时的自定义触发关闭目标，不改发 Fn；若目标已打开但触发不可用，则记录停止失败而不是混发。
- 松开后完成当前会话，目标收到一次停止触发；之后按钮恢复可用。
- 日志记录 `VOICE TRIGGER rejected reason=voice_active`，不记录按键内容。

失败判定：录音中组合改变、按钮可写入、当前会话漏发停止触发、同一次会话混发 Fn 与自定义触发。

## 用例 4：RC003 + Typeless 翻译会话

操作：

1. 设置 Fn + Shift + S，并将 Typeless 切到翻译模式；如果 Typeless 的翻译快捷键是纯修饰键组合，则改设 Fn + Shift。
2. 按住 RC003 语音键，说一句短句，松开。
3. 观察 Typeless 是否进入翻译听写并输出文字。
4. 连续快速执行 3 次，每次间隔小于 2 秒。
5. 在开始说话前立即松开一次，验证空语音/尾音路径。

预期：

- 每次按下后 Typeless 进入一次翻译听写；每次松开后退出一次并提交文字。
- 每次会话只发送一组开始/停止触发，不额外发送 Fn，不出现第二次才成功。
- 快速连续会话不串音、不丢尾字；正常松开不 flush 尾音。
- 空语音不把目标留在听写状态；失败按现有错误路径显示或记录。

失败判定：需要按两次才生效、翻译与听写混用、尾字丢失、目标持续停留在听写状态、同一次会话出现 Fn 触发。

## 用例 5：未设置时回退 Fn

操作：

1. 清除自定义触发。
2. 使用 Typeless 普通听写模式，按住语音键说一句并松开。
3. 检查日志。

预期：

- 仍按现有行为发送两次 Fn 点按，Typeless 普通听写开始和结束。
- 不出现 `VOICE FN TAP trigger=custom`；会话仍走既有 Fn 点按路径。

失败判定：未设置时发送自定义键，或不再发送 Fn。

## 用例 6：辅助功能权限拒绝

操作：

1. 保持自定义触发已设置，撤销 SayAll 的辅助功能权限。
2. 按下并松开 RC003 语音键。

预期：

- 开始触发提交失败，出现 `start_tap_failed`；Fn 点按模式关闭并明确提示，后续回退硬件 Fn 路径。
- 同一次会话不改为发送 Fn，不提交 pre-roll 音频。
- 恢复权限后重新开启 Fn 点按可再次使用。

失败判定：权限拒绝后仍显示语音成功、混发 Fn、或会话卡在 starting。

## 用例 7：断连、挂起与退出

操作：

1. 开始一次自定义触发会话，在收音中断开 RC003。
2. 重连后再次开始会话，在注发开始触发后 100 ms 内让 Mac 进入快速用户切换或挂起。
3. 回到会话后退出 SayAll。
4. 再次启动并测试一次正常会话。

预期：

- 断连/挂起时发送一次匹配的关闭触发；不发送 Fn。
- 退出时若停止触发已提交，不再补发，避免目标重新打开。
- 重启后设置保留，下一次会话只发送一组开始/停止触发。
- 日志包含 `shutdown`、`suspended` 或对应终态；不得把异常结束记为正常成功。

失败判定：目标停留在听写状态、目标被重新打开、混发 Fn、设置丢失或会话卡死。

## 用例 8：配置导入导出与旧配置

操作：

1. 导出当前完整配置，检查 `voiceTriggerShortcut` 字段存在且不含明文按键内容（只有键码与修饰标志）。
2. 在另一套隔离设置中导入，确认触发键恢复并生效；再执行一次完整备份恢复，确认触发键、模式和 Fn 点按开关一起恢复。
3. 修改导出 JSON，将 `modifierFlagsRawValue` 改为 `0`，再导入。
4. 导入不含 `voiceTriggerShortcut` 的旧配置。
5. 尝试通过跨 Mac 便携配置导入。

预期：

- 步骤 2 触发键恢复；步骤 3 只丢弃该字段，导入报告标记 `voiceTriggerShortcut`，其余配置正常。
- 步骤 4 回退未设置，继续发送 Fn，不报错。
- 步骤 5 在私有包未更新前回退未设置；这是已知兼容边界，不静默声称已迁移。

失败判定：裸键被安装、旧配置整份失败、导入报告缺失、便携配置声称携带但实际丢失。

## 用例 9：稳定功能回归

操作：

1. 关闭 Fn 点按，使用豆包长按模式完成一次语音。
2. 使用左 Command 语音键完成一次语音。
3. 用 iPhone、Apple Watch 或网页版入口完成一次移动语音。
4. 检查普通按键映射、App 聚焦和翻页动作。

预期：

- 长按式工具不经过自定义触发；语音键模式、移动语音和普通按键不受影响。
- 关闭自定义行后页面布局、窗口几何和滚动不裁切。

失败判定：任何稳定路径被改写、额外发送组合键、或移动语音被当成点按会话。

## 日志收集

- 设置页操作：`VOICE TRIGGER phase=completed result=configured|cleared`、`VOICE TRIGGER rejected reason=modifier_required|voice_active`。
- 会话路径：`VOICE FN TAP trigger=custom ... phase=completed result=submitted|failed target_response=unknown`。
- 失败/终止：`VOICE FN TAP drain ...`、`start_tap_failed`、`stop_tap_failed`、`shutdown`、`suspended`。
- 只记录修饰键存在性和数量，不记录按键字符、完整组合、目标 App 内容或用户文字。

## 生产视图截图

2026-11-24 使用本次代码构建的 `SayAll.app` 和 `SettingsScreenshotRenderer` 离屏入口生成：`REMOTE_MIC_SETTINGS_SCREENSHOT_SECTION=mapping`、`..._OPEN_VOICE_SETTINGS=1`、`..._VOICE_TRIGGER_SHORTCUT=1`（纯修饰键用 `chord`）。尺寸均为 `1067 × 760` 逻辑点（`2134 × 1520` PNG），使用隔离设置和虚构测试账户，不读取用户配置。

| 文件 | 语言/外观 | 状态 | SHA-256 |
| --- | --- | --- | --- |
| `zh-light/mapping-1067x760.png` | 中文/浅色 | Fn 点按开启，Fn + Shift + S | `b32c54f5c2ce609157ef82a851d386ac2f3126982ea4a8e32cbb9c6f37821ad7` |
| `zh-dark/mapping-1067x760.png` | 中文/深色 | Fn 点按开启，Fn + Shift + S | `7b36a767a1369c8a84f3359bec51020f0195736d7ed33490e29354ca1ee9e4e4` |
| `en-light/mapping-1067x760.png` | 英文/浅色 | Fn 点按开启，Fn + Shift + S | `510af3c58942481cd5002d35e956c831859cd4914fe0788f0f90abfec5786d2c` |
| `en-dark/mapping-1067x760.png` | 英文/深色 | Fn 点按开启，Fn + Shift + S | `7ca1d2095158dfe1d4618f27ac705d2a5b5b732f92ff0ee2092a7cb382262aa3` |
| `zh-light-chord/mapping-1067x760.png` | 中文/浅色 | 纯修饰键组合 Fn + Shift | `aec2bbdeda57980cc6ddaaf344a3f845e1861c723eaa09d6121efa774405af22` |

原件保存在仓库外持久证据目录 `~/Pictures/SayAllEvidence/voice-trigger-shortcut-20261124/`；PR 附件 URL 与逐项摘要见 [证据索引](../Screenshots/voice-trigger-shortcut-20261124/manifest.json)。截图只证明静态布局、文案、对比度和组合键显示，不证明真实遥控器、音频、Typeless 文字上屏或交互时序。

## 验证边界

- 已完成的自动化：触发键校验、持久化、旧格式、导入导出、无效导入拒绝、控制器自定义/回退/失败、禁用与退出时匹配关闭、录音中模型拒绝修改。
- 未完成：RC003 + Typeless 真实翻译文字上屏、连续会话、快速按放、断连/挂起/退出真机矩阵、生产设置页浅色/深色截图、公开/私有构建和发布门禁。
- 单元测试、构建、签名和截图只证明各自边界，不能替代真实遥控器与第三方工具验收。
