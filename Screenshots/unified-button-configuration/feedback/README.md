# 用户反馈修复的实际运行截图

2026-10-03，本轮构建的生产 SettingsView 隐藏交互入口，独立 Bundle ID 内部副本、隔离 UserDefaults 与合成动作数据。窗口 1020 × 772 pt，原始 CUA JPEG 为 2040 × 1544 px；无裁切、缩放、重压缩，摘要见 [清单](actual-manifest.json)。

- actual-basic-selected-*：全部动作直接展示与首动作明确选择反馈。
- actual-steps-*：添加步骤、配置和排序；步骤列表可滚动访问底部动作。
- actual-review-* / actual-saved-*：最后统一保存、回到库。
- actual-navigation-0..5-*：依次按键、组合动作、键位方案、回眸、连接、设置，light/dark 对应浅/深色。

20 张逐一查看：标题、导航、主要控件及窗口几何保持；按键特色画布没有改动。设置和连接的长内容通过页面滚动访问。内部 UI 副本不作为用户安装包；最终本地包单独验证 Developer ID、公证、staple 和 Gatekeeper。

用户原始反馈 PNG 仅留存本地，不提交；原始用户配置副本读取只输出脱敏计数，不记录其界面或参数。真实遥控器及目标 App 结果见测试手册的未验收边界。
