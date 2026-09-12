# 方向键快捷键被伪 Fn 污染（Issue #190）

## 复现

在 macOS 普通按键映射页录入带 Command 的方向键快捷键。系统事件会同时带有 `maskSecondaryFn`，导致 `Command + Fn + 方向键` 被保存、展示并按原样注入；旧配置也会继续携带该伪修饰键。

## 日志与根因

复现只涉及本地快捷键事件，未读取第三方 App 私有数据。代码检查确认 `CustomKeyboardShortcut` 在初始化和旧配置读取时只做通用修饰键裁剪，没有针对方向键移除 macOS 自动附带的 `.function`。

## 修复

对 keyCode `123...126` 的快捷键统一移除 `.function`，并让展示、CGEvent flags 和执行路径都使用归一化修饰键；真实功能键仍保留显式 `Fn`。

## 验证

- `swift test --disable-keychain`：公开仓库 493 个测试通过。
- 回归测试覆盖方向键录入、旧记录读取、展示和执行 flags；非方向键显式 `Fn` 保留。

真实键盘与第三方 App 的最终验收仍需在 macOS 用户环境执行。
