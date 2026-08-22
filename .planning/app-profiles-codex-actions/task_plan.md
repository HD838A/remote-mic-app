# 按应用配置与 Codex 动作

## 目标

在现有遥控器映射和滚轮动作基础上，增加按前台应用选择配置、Codex 专用动作（停止、聚焦输入框、滚动到最新），以及滚轮方向和速度设置；保留现有设备配置、语音和 Command-Tab 行为。

## 阶段

- [completed] 1. 分析现有配置、前台应用解析、动作注入和设置 UI
- [completed] 2. 实现应用配置和 Codex 动作
- [completed] 3. 实现滚轮方向/速度配置
- [completed] 4. 增加回归测试并验证迁移兼容性
- [completed] 5. Release 构建、安装、重启和运行验证
- [completed] 6. 新增 Codex Page Up / Page Down 翻页动作
- [completed] 7. 将 Codex 翻页改为定位窗口的大步长滚轮事件

## 成功标准

- 可为默认配置和至少 Codex 配置分别设置遥控器动作。
- 前台 Codex 应用使用 Codex 配置，其他应用继续使用默认配置。
- Codex 动作可以停止生成、聚焦输入框、滚动到最新。
- 滚轮方向和速度设置可以持久化，并影响滚轮事件。
- 现有 RC003 语音、微信电源键、Command-Tab 和原有滚轮动作不回归。
- Codex 配置可将遥控器左键/右键分别绑定为上一页/下一页。
- Codex 翻页使用前台窗口中心、wheelCount=2、独立步长和短事件间隔。

## 约束

- 不引入 DriverKit、root helper 或 Codex 私有接口。
- 兼容已有 UserDefaults / 导出配置，缺省字段使用默认值。
- 每个阶段记录源码发现、错误和验证结果。

## 遇到的错误

| 错误 | 处理 |
|------|------|
| 默认 `swift build` 因 CLT/SDK Swift 版本不匹配及缓存权限失败 | 使用临时模块缓存，并通过 `--disable-sandbox` 完成 Release 构建 |
| 首次 `open -a /Applications/SayAll.app` 返回 -609 | 校验签名和 Info.plist 后重新注册并启动，进程已运行 |
| `swift test --disable-sandbox` 在测试目标导入 `Testing` 时失败 | 主应用已完整编译；仓库自测 42/42 通过，测试源码本身已纳入构建尝试，环境缺少 Testing 模块 |
