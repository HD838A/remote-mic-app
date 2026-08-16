# 键位方案验证摘要

- 自动化：私有 Swift Package 完整 `swift test`、`swift build`；公开宿主注入私有模块后的完整测试和构建。
- UI：组合动作与键位方案入口、本地化、中文最小 12pt、无长下拉/Sheet/Popover；系统 App 选择器除外。
- 人工：真实遥控器、双设备、Codex/Claude/cmux/网易云前后台、锁屏、权限撤销、稳定语音和最小窗口。
- 失败日志必须区分前台 App 事件、方案解析、绑定解析、动作开始和用户可见结果，不能把监听到事件等同于功能成功。

完整步骤见 [Testing/ButtonProfiles.md](../../Testing/ButtonProfiles.md)。
