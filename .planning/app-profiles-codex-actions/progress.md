# 进度日志

- 第 8 阶段进行中：将应用专属动作移入独立分类，按所选应用 profile 显示并使用其名称；滚轮速度、方向、翻页步长和事件间隔改为 profile 独立设置。
- 已完成旧 profile/config 的默认值迁移、HID/手机遥控器路径的按前台应用读取，以及动作和翻页参数回归测试补充；待执行完整类型检查、测试、自测、打包、安装、重启和提交。
- 已完成源码类型检查、测试源码语法解析、`git diff --check` 和仓库自测 42/42；SwiftPM Release 构建成功。
- `dist/SayAll.app` 通过 `APP VERIFY PASS` 与 `codesign --verify --deep --strict`，已安装到 `/Applications/SayAll.app` 并重启；运行 PID 为 39460，安装包与构建产物 `RemoteMic` SHA-256 均为 `85b4a0dc930f14eda39cc6e4ab7b36cc051bbcf645eada74df625a013ed522d1`。
- 视觉检查确认 ChatGPT profile 下动作顺序为系统与媒体、应用专属动作、自定义动作，滚动设置显示为 ChatGPT 配置；第 8 阶段完成。

## 2026-08-22

- 开始实现按应用配置、Codex 动作和滚轮方向/速度设置。
- 已确认只在 `feature/voice-option-scroll-events` 工作副本内操作。
- 已创建本任务规划文件；当前处于源码分析阶段。
- 完成应用覆盖模型：`ApplicationMappingProfile` 按 bundle identifier 匹配，未匹配时回退设备默认映射。
- 完成 Codex 动作：停止生成、聚焦输入框、滚动到最新，并接入 HID 和手机遥控器路径。
- 完成滚轮速度 1...10、方向反转和 UserDefaults/导入导出持久化。
- 增加动作、delta、应用覆盖和持久化回归测试；源码自测 42/42 通过，修改后的主源码类型检查通过。
- Release 构建成功，`scripts/verify-app.sh dist/SayAll.app` 报告 `APP VERIFY PASS`。
- 已将新包安装到 `/Applications/SayAll.app`，签名校验通过，重启后的 `RemoteMic` 进程 PID 为 32057。
- 安装包与构建产物 `RemoteMic` SHA-256 相同；SwiftPM 测试目标仍因当前环境缺少 `Testing` 模块无法执行，仓库自测保持 42/42。
- 本轮新增 Codex Page Up / Page Down 动作，分别发送 key code 116 / 121；已补充中英文文案和 KeyboardInjector 回归测试，待完成构建、安装、重启和提交验证。
- Codex 翻页功能已完成 Release 构建、`APP VERIFY PASS`、安装和重启；安装包与构建产物 SHA-256 一致，运行进程已确认。工作区待提交。
- 根据测试反馈，将 Codex 翻页底层从 Page Up/Page Down 键事件改为前台窗口中心的大步长滚轮事件：wheelCount=2、独立步长 12 行、间隔 12ms；已更新可注入回归测试。
- 新版本已完成类型检查、自测 42/42、Release 构建、`APP VERIFY PASS`、安装和重启；安装包与构建产物 SHA-256 一致，运行进程 PID 为 36884。
