# 私有邀请码页面显示本地化 Key 且文本编辑快捷键不可用

- 时间：2026-08-14
- 状态：候选修复完成，等待最终签名 App 人工验收
- 影响范围：包含 `sayall-ai` 或 `sayall-macro-platform` 的 macOS 预览构建
- 功能点：关于页邀请码入口、私有 SwiftPM 资源、macOS Edit 菜单
- 简单描述：邀请码页面把 `early_access.*` 显示为原始 key，输入区域过松，且 App 缺少标准 Edit 菜单，文本框不能可靠使用常用 Command 快捷键。

## 复现

1. 启动包含私有模块的预览构建。
2. 从“关于”页显示邀请码入口。
3. 观察标题、说明、状态、占位符、按钮和隐私说明。
4. 聚焦邀请码输入框，测试复制、粘贴、剪切、撤销、重做和全选。

错误行为：页面显示 `early_access.title`、`early_access.status.not_enrolled` 等原始 key；输入、状态和隐私说明占用多个松散区域；标准编辑快捷键缺少完整菜单入口。

正常行为：私有资源按当前语言显示；邀请码相关控件集中在一个紧凑区域；聚焦文本框按标准 Mac App 行为响应 `Command-C/V/X/Z`、`Shift-Command-Z` 和 `Command-A`。

## 日志与代码结论

该问题发生在页面渲染和 responder chain，不涉及资格网络请求。截图能够稳定证明本地化查找返回了 key 本身；无需资格服务日志即可缩小到私有资源 Bundle 和 App 菜单配置。

- `sayall-ai` 在最终 App 中按固定 `zh-Hans.lproj` 路径查找，但 SwiftPM 产物可能生成 `zh-hans.lproj`，查找失败时直接返回 key。
- `sayall-macro-platform` 已能从 `Contents/Resources` 解析 Bundle，但本地化读取仍需要兼容实际生成的语言目录名。
- 宿主只创建 App 与 File 菜单，没有标准 Edit 菜单项把编辑 action 交给当前 first responder。

## 修复

- 两个私有包显式兼容 `zh-Hans`、`zh-hans` 和英文资源，最终 App Bundle 不存在时回退 `Bundle.module`。
- 邀请码输入、验证、状态和隐私说明保留在同一紧凑卡片内，中文说明继续使用 12pt。
- 宿主增加标准 Edit 菜单，使用 nil target 将 `copy:`、`paste:`、`cut:`、`undo:`、`redo:` 和 `selectAll:` 交给聚焦文本框。

## 验证

- `sayall-ai`：`swift test`，25 项通过。
- `sayall-macro-platform`：`swift test`，30 项通过。
- 宿主注入两个私有包运行 `swift test --filter SettingsPageRegressionTests`，13 项通过。
- 三个工作区 `git diff --check` 通过。

自动化验证了资源解析与菜单配置，没有替代最终 Developer ID App 的真实页面操作。发布前仍需在中英文系统环境、`800 × 650` 窗口和真实键盘上复验全部文本、布局及快捷键。
