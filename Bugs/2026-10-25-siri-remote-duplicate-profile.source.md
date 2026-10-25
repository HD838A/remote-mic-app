---
title: Siri Remote 重复设备卡片
template: doc
---

## 证据与边界

Build 262 截图显示同一指纹 `C08JV3H32330` 有两张卡片。
一张卡片显示未连接。
另一张卡片显示已连接。
两张卡片的型号和指纹相同。

这证明持久化 profile 出现重复项。
现有日志可以确认连接状态。
现有日志不能证明重复 profile 在哪一次启动中产生。

## 根因

`AppSettings` 加载 profile 数组后只恢复选中项。
加载路径没有按 HID 指纹清理重复 profile。
重连时重复项继续参与设备卡片展示。
因此同一 Siri Remote 可以显示两张卡片。

## 修复

加载时按非空 HID 指纹去重。
优先保留用户当前选中的 profile。
没有选中项时保留信息更完整的 profile。
合并型号、名称和非默认按键映射。
修正选中 profile ID。
记录去重数量和剩余数量。

## 自动化回归

测试写入两个相同指纹的 profile。
测试选中带有自定义映射的 profile。
重新加载设置后只保留一个 profile。
选中 profile ID 保持正确。
自定义映射保持不变。

## 验证与边界

运行 `swift test --disable-keychain --filter RemoteProfilePersistenceTests`。
5 项测试通过。
`git diff --check` 通过。
真实 Siri Remote 重连和旧安装数据迁移仍需在 Build 262 测试机验证。
本次不修改蓝牙协议、私有适配器或按键执行语义。

## 2026-10-25 追加证据与诊断日志

当前运行日志显示两张相同 A2854 卡片对应两个不同的非空 fingerprint。现有持久化去重只按 fingerprint 复用，因此不能按型号或显示名称合并。

本次增加脱敏诊断字段：私有 Siri 适配器记录 identity source、同一 identity 的接口计数和当前 active identity 数；宿主记录 profile_resolution=created 或 reused。日志不输出 fingerprint、序列号、地址或路径。

下一次现场重连后，按时间顺序检查 identity_source 是否改变，以及 profile_resolution 是否连续为 created。只有确认同一物理遥控器在重连时身份来源不稳定，才进入身份算法修复。当前不按名称盲合并。

自动化验证：私有 Siri Remote SwiftPM 测试 104 项通过；公开宿主定向测试待本分支构建后执行。真实 Siri Remote 重连验收未完成。
