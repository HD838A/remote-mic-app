# 统一按键设置设计稿

状态：用户已确认并授权实施，2026-10-03 源码候选已按下列四图开发。

## 确认顺序

1. [按键页的组合动作选择区](01-mapping-action-picker-light-v4.png)：保留原遥控器画布，只扩展原有自定义动作区。
2. [基本设置](02-action-basic-light-v3.png)
3. [编排步骤](03-action-steps-light-v3.png)
4. [测试与保存](04-action-review-light-v4.png)

组合动作编辑隐藏库列表，修改先留在草稿，最后保存；测试可选，不自动绑定。
键位方案保留现有摘要和逐步配置，仅补硬件适配。原始按键截图保留为
[reference-mapping-original.png](reference-mapping-original.png)。
撤回的中间方案只在本地历史留存，不作为当前设计或提交资产。

## 验证

四张设计图为生成的视觉参考，原始 PNG 已持久保存，逐张查看并验证块校验、解压、格式、尺寸和 SHA-256；
它们不能证明生产字体、真实窗口交互或硬件通过。运行证据见[UI 验证记录](../../unified-button-configuration/README.md)。

| 文件 | 像素尺寸 | SHA-256 |
| --- | --- | --- |
| [01-mapping-action-picker-light-v4.png](01-mapping-action-picker-light-v4.png) | 1442 × 1091 | `4498b1c65ff5df68c1035313d2e410fbcc10f522ed90ec4138f462e763e68679` |
| [02-action-basic-light-v3.png](02-action-basic-light-v3.png) | 1442 × 1091 | `99fad4f01822cbfe26532c2e08a210502095831795484d6b6292a332f9cacdba` |
| [03-action-steps-light-v3.png](03-action-steps-light-v3.png) | 1442 × 1091 | `45bc28428fca743367e49a40797e7b8a6764529593cd4415f7d57622e50305bc` |
| [04-action-review-light-v4.png](04-action-review-light-v4.png) | 1442 × 1091 | `f6d6cc7133f709982126df822e9299bd1f1ff5639b91eca761ba4890bd690233` |
| [reference-mapping-original.png](reference-mapping-original.png) | 1822 × 1278 | `d419cfaab66545ff8cec30fb1be7e40a28f07fa8863544ed00ce2eec0b076e1b` |

详细流程与范围记录位于私有营销仓库 `projects/remote-mic-app/research/unified-button-configuration/v1/scope-revision.md`。
