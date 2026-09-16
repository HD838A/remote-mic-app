# 一键切回动作：离屏生产视图证据

- 源码：`0a5c28565f8a5825af2234ef80d94d52d7aa7df7`。
- 使用 `scripts/build-app.sh` 的 Apple Silicon Debug 公开构建，未安装或替换本机 App。
- 使用 `REMOTE_MIC_SETTINGS_SCREENSHOT_OPEN_ACTION_EDITOR=1` 等既有截图环境变量；SettingsView 逻辑窗口 1020×1800，Retina 输出 2040×3600。
- 仅验证新动作候选按钮中英文完整显示和浅深色对比度；没有运行真实窗口、物理遥控器或系统切换，不能作为合入/发布验收，PR 保持 Draft。
- 英文页面中既有分类标题紧邻、其他旧按钮截断不属于本次更改。

| 文件 | SHA-256 |
| --- | --- |
| [harness-mapping-zh-light.png](harness-mapping-zh-light.png) | `939cfac37f3e0597c0aad89e708c4e83a2718076d75b8231c3afb7818583ff64` |
| [harness-mapping-zh-dark.png](harness-mapping-zh-dark.png) | `158353c2805e3d49f7bb8d2192f12f14e4dc01ad679d62cf2b03d7341e90a47b` |
| [harness-mapping-en-light.png](harness-mapping-en-light.png) | `99a94e938826cbea9ffa3a331d5caa1edc7b0864221c2960df0f481cc66294ef` |
