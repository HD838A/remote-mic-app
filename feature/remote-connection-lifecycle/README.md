# 遥控器连接生命周期与手动恢复

- 状态：实现候选，验证结果见 PR，真实设备验收待完成。
- 产品行为见 [PRODUCT_SPEC.md](PRODUCT_SPEC.md)。
- [测试手册](../../Testing/RemoteConnectionRecovery.md)；[根因与验证边界](../../Bugs/2026-11-15-bounded-remote-recovery.md)。
- 设计原稿与完整评审保存在私有资料仓库 [v2](https://github.com/GetSayAll/private-marketing-toolkit/tree/55cdecc/projects/remote-mic-app/research/remote-connection-lifecycle/v2)。
- 可公开查看的设计预览见 [PR #1072 设计附件](https://github.com/HD838A/remote-mic-app/pull/1072#issuecomment-6894791880)；这是 HTML 原型，不能替代生产截图或真机证据。
- 用户于 2026-11-15 要求先提交文档和设计，再开发并更新原 PR；2026-11-16 改为自动化通过后合入，由用户随后完成真机测试。
- 完整研究和实施讨论仅在私有资料仓库维护；公开仓库保留产品行为与验证边界。

## 统一卡片修订

用户确认的自包含 [HTML 设计稿](design/cards.html) 已按明确指令纳入仓库；对应生产组件为 `RemoteDeviceCard`。行为见 [产品规范](PRODUCT_SPEC.md#统一遥控器卡片)，验证见 [卡片手册](../../Testing/ConnectedRemoteCards.md#统一卡片与整体状态候选2026-11-16)。本轮为实现候选，真实组件安装、权限、硬件与语音验收仍需单独完成。

## 连接新的设备入口

用户确认的自包含 [HTML 设计稿](design/connect-new-device.html) 已纳入仓库。连接页“设备”卡片在“连接过的设备”上方提供“连接新的设备”，使用无边框平面入口行，点击重新运行现有设置向导；没有 Apple Remote 卡片或历史档案时入口仍可见。除设备卡片内的型号或名称外，新增区域使用“设备”泛称。生产截图与真实向导回归结果见 PR。
