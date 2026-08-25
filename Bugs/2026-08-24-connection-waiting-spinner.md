# 连接页等待状态无进度指示、TestFlight 按钮组使用魔法数字对齐

## 复现

- 环境:macOS 27,「系统设置 → 蓝牙/网络」等待态对照;`dist/SayAll.app` 调试构建。
- 操作:「连接与语音」分别开启 iPhone、Apple Watch、网页版连接等待;观察 iPhone 区的 TestFlight 操作行。
- 实际结果:等待中只有橙色文字状态,没有系统惯例的 spinner;TestFlight「打开页面 / 复制链接」按钮组用 `Spacer(minLength: 42)` 手工缩进,42pt 魔法数字不属于三类对齐中任何一种,图标列宽变化时会错位。
- 预期结果:等待中状态旁显示系统 `ProgressView`;操作行对齐分区左边线,不用魔法数字。

## 日志结论

纯界面问题,无专用日志;连接状态机本身正常(runtime.log 事件序列正确)。

## 根因

- `connectionOptionRow` 只渲染文字状态,没有等待中的进度指示参数。
- TestFlight 行在历史布局中用手工 42pt 缩进对齐文字列,未跟随原生设置重构的对齐网格。

## 修复

- `connectionOptionRow` 新增 `isWaiting: Bool = false`,`connectionStatusLabel` 在等待时前置 `.controlSize(.small)` 系统 `ProgressView`(对辅助功能隐藏,状态文字本身已表意)。
- iPhone 行:`isWaiting = isPhoneRemoteConnectionEnabled && !isPhoneRemoteConnected`;Apple Watch 行同理;网页版新增 `isWebRemoteWaiting`(`.connecting / .waitingForPhone / .awaitingApproval`)。
- TestFlight 行移除 `Spacer(minLength: 42)`,按钮组对齐分区左边线,与下方邀请卡同一边线。

## 验证

- 修复前:等待态无 spinner,42pt 魔法数字存在。
- 修复后结构门禁:四个 `isWaiting` 接线断言、`Spacer(minLength: 42)` 不再出现;31 项定向测试、344 项全量测试、成品构建与完整性校验通过;真实窗口连接页(遥控器已连接、MiRemoteV 2ch 已选)渲染正常。

## 验证边界

真实「等待扫码 / 等待批准」状态需要 iPhone/Watch/网页版现场,代理侧未触发实际等待态 spinner,按测试手册人工复核。
