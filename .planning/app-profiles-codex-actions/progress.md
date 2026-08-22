# 进度日志

- 第 8 阶段进行中：将应用专属动作移入独立分类，按所选应用 profile 显示并使用其名称；滚轮速度、方向、翻页步长和事件间隔改为 profile 独立设置。
- 已完成旧 profile/config 的默认值迁移、HID/手机遥控器路径的按前台应用读取，以及动作和翻页参数回归测试补充；待执行完整类型检查、测试、自测、打包、安装、重启和提交。
- 已完成源码类型检查、测试源码语法解析、`git diff --check` 和仓库自测 42/42；SwiftPM Release 构建成功。
- `dist/SayAll.app` 通过 `APP VERIFY PASS` 与 `codesign --verify --deep --strict`，已安装到 `/Applications/SayAll.app` 并重启；运行 PID 为 39460，安装包与构建产物 `RemoteMic` SHA-256 均为 `85b4a0dc930f14eda39cc6e4ab7b36cc051bbcf645eada74df625a013ed522d1`。
- 视觉检查确认 ChatGPT profile 下动作顺序为系统与媒体、应用专属动作、自定义动作，滚动设置显示为 ChatGPT 配置；第 8 阶段完成。
- 第 9 阶段完成：微信语音动作移入应用专属分类，按 `com.tencent.xinWeChat` 过滤，并在微信 profile 中显示为“微信 发语音消息（按住右 Option）”。已恢复 UI 到原先的 ChatGPT profile。
- 第 10 阶段完成：取消微信语音动作只能绑定电源键的限制；实体 HID 与手机/网页遥控器入口均支持任意按键按住/松开发送 Right Option 状态。UI 已在微信 profile 的上键编辑器中验证动作可选，并恢复到 ChatGPT profile。
- 第 11 阶段开始：用户确认微信对话中的语音气泡单击可播放；开始新增独立的“播放收到的语音消息”动作，保留现有微信发语音/语音转文字逻辑不变。
- 已新增 `wechatPlayVoiceMessage` 动作、双语文案、Accessibility 语音节点播放器、动作过滤/注入测试和 `Testing/WeChatVoiceMessagePlayback.md`；旧 `wechatVoiceMessage` 按住右 Option 行为未改动。
- `swiftc -parse Sources/RemoteMic/*.swift Tests/RemoteMicTests/*.swift`、`git diff --check` 和两份 `.strings` `plutil -lint` 通过。
- `swift build`、`SKIP_SWIFT_PACKAGE_BUILD=1 scripts/test.sh` 均被本机 Swift 6.3.3 与 SDK Swift 6.3.2 版本不匹配阻塞，尚未宣称编译或单元测试通过。
- 通过同时重定向 Swift/Clang module cache 后，Debug 主目标完整编译通过；Swift Testing 目标因环境缺少 `Testing` 模块失败；纯 Swift 自测 `passed=42 failed=0`。
- Release 构建、`APP VERIFY PASS`、深度签名校验和安装包主程序 SHA-256 校验通过；已安装并启动 `/Applications/SayAll.app`，日志确认 `APP START version=1.9.8`。
- SayAll UI 已验证微信 Profile 的应用专属动作显示“微信 播放收到的语音消息”，并将 TV 键单击临时配置为该动作；安装新包后 macOS 辅助功能授权失效，现场遥控器测试等待重新授权。
- 第 11 阶段实测完成：TV 键事件被正确接收并触发微信播放动作；微信未暴露语音气泡 AX 节点，加入鼠标位置回退并修正 AppKit/Quartz 垂直坐标转换。用户确认修正后的短按可播放语音，且单次按键只产生一次点击。
- 坐标回退仅允许点击当前微信窗口内容区域，不使用固定坐标；Release 构建、APP VERIFY、42/42 自测和安装后现场播放验证均通过。

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
