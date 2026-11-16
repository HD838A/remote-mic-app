# 待验证 App 的输入框聚焦提示气泡重复且干扰

- 时间：2026-11-16
- 状态：候选修复
- 影响范围：“聚焦与翻页”页面、打开自定义 App 的普通按键动作
- 简单描述：打开一个尚未验证输入框聚焦的导入 App 时，每次都会弹出“输入框聚焦还没有验证”提示。页面已经显示“待学习或验证”，用户不需要额外气泡。

## 现象与证据

用户现场：按下绑定到“打开自定义 App”的按键后，底部出现：

```text
输入框聚焦还没有验证
本次只执行打开 App，不会自动聚焦输入框。
```

该 App 的“聚焦与翻页”条目已经显示“待学习或验证”。用户明确表示不需要这个提示。

代码来源：提交 `20d38b31` 在 `BridgeAppModel.performExternalConfiguredAction` 中为 `focus=skipped reason=verification_pending` 增加了 `presentCustomApplicationVerificationNotice()`。

## 根因

待验证状态已经在页面中以“待学习或验证”持续显示。动作执行时再弹一次警告：

- 重复同一个信息；
- 每次打开 App 都出现，干扰正常使用；
- 让用户误以为本次打开失败或需要额外操作。

实际上动作成功执行，只是按设计跳过尚未验证的输入框聚焦。

## 修复

- 移除 `presentCustomApplicationVerificationNotice()` 调用和实现。
- 保留 `focus=skipped reason=verification_pending` 诊断日志，第三方结果边界仍可审计。
- 移除 `button_mapping.pending_verification.*` 中英文文案和截图夹具。
- 更新回归：待验证 App 打开成功、`focusAllowed=false`、不出现提示气泡。
- 更新 `Testing/CustomApplicationFocus.md` 用例 1A：页面“待学习或验证”是唯一提示。

## 验证

- `swift test --disable-keychain -j 4 --filter 'BridgeAppModelActionRegressionTests|LocalizationTests|SettingsPageRegressionTests'`：**95 tests / 3 suites passed**。
- 公开模式全量 `swift test --disable-keychain -j 4`：**1497 tests / 111 suites passed**。
- 公开 `swift build --disable-keychain -j 4` 通过；`scripts/verify-repository-governance.sh` 通过；`git diff --check` 通过。
- 真实边界：真实第三方 App 前台切换、输入框焦点和实体遥控器仍需按测试手册执行。

## 边界

- 不改变“待验证 App 只打开、不自动聚焦”的执行语义。
- 不删除页面上的“待学习或验证”状态，也不自动把导入配置标为已验证。
- 不改变动作失败提示；真正打开失败仍显示“按键动作未完成”。
