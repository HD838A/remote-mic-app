# 组合动作重录快捷键串改其他动作

## 复现

- 环境：macOS；组合动作模块来自私有 `GetSayAll/sayall-private-platform/packages/macos-button-profiles`。
- Routine A 第 2 步录入 `Ctrl+A`，Routine B 第 2 步录入或复用同一快捷键 Profile 并显示 `Ctrl+A`。
- 重录 Routine A 第 2 步为 `Ctrl+B` 并保存。
- 旧实现中 Routine B 第 2 步也显示并执行 `Ctrl+B`。

## 日志结论

- 现有宿主日志没有记录快捷键 Profile 内容或步骤正文；本问题通过无敏感内容的步骤 ID、Profile ID 和快捷键摘要测试复现。
- “收到录入事件”与“保存成功”不能证明只更新当前 Routine；旧实现的 Profile Store 对同 ID 使用替换语义。
- 诊断边界：真实第三方 App 内部快捷键处理不可观察，本修复只覆盖本地组合动作数据隔离。

## 根因

重录沿用步骤已有的 `shortcutProfileKey`。当 Routine A 与 Routine B 共享该 Profile 时，保存 Ctrl+B 会原地替换全局记录，所有引用方都会读取新值。

## 修复

在组合动作模块中加入 copy-on-write：重录已存在的快捷键时生成新的快捷键记录，并只将新记录绑定回正在编辑的步骤；其他 Routine 继续使用原快捷键。

## 验证

- 旧实现最小实验：复制步骤的 Profile 独立性断言失败，源与副本均为 `shortcut.shared`。
- 修复后：`swift test --disable-keychain --filter rerecordingSharedShortcutUsesCopyOnWriteAndKeepsOtherRoutineUnchanged` 通过。
- 待完成：私有包全量测试、注入公开宿主后的测试、真实遥控器和 Codex/Claude 等第三方 App 的人工流程。
