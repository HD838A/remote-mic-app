# Onboarding 错误拒绝 BlackHole 2ch

- 时间：2026-08-19
- 状态：候选修复完成，等待真实 BlackHole 验收
- 影响范围：首次 Onboarding 音频设备页、语音测试页与完成页

## 复现

在 `1a36c634` 候选中同时提供 MiRemoteV 2ch 与 BlackHole 2ch，音频页只展示 MiRemoteV 2ch；定向测试还明确断言 `BlackHole2ch_UID` 不能满足设备门禁。因此使用 BlackHole 2ch 的用户无法继续，即使该设备在主设置页和生产音频链路中可用。

## 日志检查

这是产品支持范围被错误收紧的确定性策略问题，不依赖用户现场时序。没有对应的新现场日志，因此未把旧 `runtime.log` 当作本次证据；复现依据是提交中的页面筛选逻辑和失败断言。

## 根因

修复 Beosound 等普通输出错误通过时，把允许范围从“全部系统输出”过度收紧成“仅 MiRemoteV 2ch”，没有保留产品确认支持的 BlackHole 2ch。

## 修复

1. 音频页只展示 MiRemoteV 2ch 与 BlackHole 2ch。
2. 选择任一受支持设备都能满足设备门禁；实体遥控器仍要求生产音频输出 Ready，iPhone/网页仍在下一页验证按需音频。
3. Beosound、系统扬声器和其他普通输出继续被拒绝。
4. 手动键盘文字不能通过语音测试的修复保持不变。

## 验证

- Onboarding 定向测试覆盖 MiRemote 与 BlackHole 通过、Beosound 与内建扬声器拒绝、受支持设备失效阻塞。
- 页面截图夹具同时提供两种受支持设备，用于检查浅色和深色平铺布局。

## 验证边界

自动化只能证明设备识别、选择和流程门禁。真实 BlackHole 2ch 的 Core Audio 输出、豆包/微信/Typeless 文字上屏以及实体遥控器、iPhone、网页版完整链路仍需按测试手册验收。
