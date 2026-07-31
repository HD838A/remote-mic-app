# TODO

- [ ] Windows 版本
- [x] ~~自动聚焦输入框~~（已完成：打开 Codex、Claude、cmux 后自动聚焦其输入区域）
- [x] ~~配置导入导出~~（已完成：支持版本化 JSON 导入导出全部个性化设置；本地使用统计不随配置迁移）
- [x] ~~按键一次后长时间语音输入~~（已测试：遥控器硬件不支持，必须长按语音键才能持续收音）
- [x] 新增 pre-release 发布，避免未实测的功能被检测到更新
- [ ] 解决组合快捷键配置问题，例如配置 Command + Space 唤起 Spotlight
- [ ] 支持苹果遥控器，方便海外用户购买和使用
  - 已完成 SiriRemoteForge、Wand、siri-remote-steamos、SiriRemoteVibe 及其他相关开源项目的可行性研究；当前总体首选 SiriRemoteForge，建议按“按键 → 触摸/滚动 → 麦克风高级组件”分阶段验证。
  - 详细结论见 [SiriRemoteForge 与“无线麦”集成评估](Research/SiriRemoteForge/README.md)。
  - 三个新增候选的源码、Release 和验证对比见 [候选项目深度对比与最终选型](Research/SiriRemoteForge/candidate-comparison.md)。
