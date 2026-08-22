# 进度日志

## 2026-08-22

- 开始实现遥控器滚轮事件映射。
- 完成源码分析：动作枚举和映射 UI 自动发现新动作；HID 重复机制可复用；事件注入接缝为 `KeyboardInjector.send`。
- 新增 `scrollUp` / `scrollDown` 动作、本地化文案，以及基于 `CGEvent` line unit 的滚轮事件注入。
- 新增滚轮 delta 回归测试，验证向上为 `+5`、向下为 `-5`，并保留按住重复能力。
- 协议自测通过 42/42；Release 构建完成，`scripts/verify-app.sh` 报告 `APP VERIFY PASS`。
- 已安装并重启 `/Applications/SayAll.app`，进程重新启动成功。
- 界面检查确认“系统与媒体”分类显示“滚轮上”和“滚轮下”。
