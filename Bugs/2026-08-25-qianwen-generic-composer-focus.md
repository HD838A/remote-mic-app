# 千问短按只能聚焦 Codex，其他 App 找不到输入框

- 时间：2026-08-25
- 状态：已通过 Lark / 飞书 / Telegram / 微信真机验收
- 影响范围：macOS；开启千问兼容模式后的“短按定位、长按说话”

## 复现与日志

1. 千问关闭“短按也能开始输入”。
2. 在 Codex 以外的聊天 App 中让输入框失去光标。
3. 点按一次 RC003 语音键。

现场结果：App 没有获得输入焦点。替换后的真机日志连续出现
`QIANWEN FOCUS requested target=frontmost` 与
`QIANWEN FOCUS cancelled reason=composer_not_found armed=true`，证明语音键映射已恢复，但输入框扫描没有找到候选项。

## 根因

通用路径直接扫描最前面 App 的 Accessibility 树，但当前定制分支比官方主分支早 15 个提交，没有合入已验证的 web 内容树唤醒逻辑。Chromium / Electron 类 App 默认只暴露空外壳；未声明 `AXManualAccessibility` 或兼容的 `AXEnhancedUserInterface` 时，`focusComposer` 无论如何排名都没有可选输入框。原通用路径还只扫描一次，没有等待约 1–2 秒的建树时间。

## 修复

- 复用官方主分支的 `AXManualAccessibility` 主路径和 `AXEnhancedUserInterface` 降级路径。
- 通用最前面 App、预置 App 和自定义记录输入框共用同一声明函数。
- 通用路径使用 12 次、每次 250 ms 的有界重试；成功、失败或页面切换都会最终恢复语音键硬件映射。
- 不切换 App、不关闭弹窗、不使用固定屏幕坐标。

## 验证边界

- 定向自动化已覆盖两种声明属性、降级结果、日志节流、至少 2 秒的重试窗口、输入框排名与千问聚焦接线。
- 自动化不能代替真实 Electron / Chromium App 的建树时间和最终光标。用户验收需至少覆盖 Codex 与另一个聊天 App；多输入框页面聚焦错误时再补该 App 的定向规则。
- 2026-08-25 安装包真机日志：飞书 `com.larksuite.larkApp` 经有界重试后出现 `APP FOCUS succeeded`和 `QIANWEN FOCUS ready armed=true`，证明 Codex 白名单已取消且通用路径成立。微信 `com.tencent.xinWeChat` 仍以 `composer_not_found` 结束，需在用户确认的具体聊天页面采集 Accessibility 候选特征后再加定向规则。
- 后续只读结构确认：微信主聊天窗口只暴露标题栏，聊天区和输入框均不在 Accessibility 树中；唯一 `AXWebArea` 属于“版本更新”窗口，不能当作聊天框。因此微信前台时直接允许长按进入千问；短按在松开时仅对微信主窗口使用有最小尺寸门禁的窗口相对点击。
- 2026-08-25 微信真机验收通过：用户确认短按可定位聊天输入框，光标已在输入框时长按可立即启动千问。日志两次连续长按分别录得 2.465 秒和 7.318 秒，均为 `STREAM accepted → START → STOP → COMMAND UP → CONFIRM F20`，没有 `MIC_CLOSE` 或 `QIANWEN FOCUS`。
