---
title: 遥控器按键反馈问题
subtitle: 常用语、快捷键、前台状态和方案继承
lang: zh
template: doc
theme: shadcn
date: 2026-10-28
baseline: 59260d55
status: 候选修复，真实设备待验收
---

## A 用户现象

- 常用语开启键第二次按下应关闭面板，却显示未配置常用语。
- 微信中打开常用语后，输入控件失去焦点，插入失败。
- Chrome 的 Command + Shift + H 偶发无效。
- 网易云音乐冷启动后，键位方案不能立即控制播放。
- 键位方案未配置的双击和长按没有继承基础按键映射。

## B 证据和边界

- 常用语和键位方案的确定性根因位于私有 Package；公开宿主只负责路由和基础映射回退。
- Chrome 的历史证据显示 Home 原生事件可能早于 HID 报告。公开宿主当前只能记录事件提交和观察结果，不能把提交成功当成 Chrome 已接受。
- 网易云的等待逻辑已检查完成启动、激活和可见窗口。日志使用同一个 `operation_id` 记录 `requested`、`launch_submitted`、`launching`、`running_not_frontmost`、`frontmost_no_visible_window`、`matched` 和 `timed_out` 阶段。媒体键还记录 `system_media_submitted`，但最终选择哪个播放器属于系统和第三方 App 的不可观察状态。
- `BUTTON PROFILE` 日志现在区分 `hid`、`mobile`、`apple_remote`、`chromecast` 和 `host` 来源，并记录 `configured` 或 `missing` 以及 `handled` 或 `unhandled`。
- 本轮没有读取未由用户明确指定的加密 `.rmlog`，不读取第三方 App 私有数据。

## C 修复边界

- 常用语开启键在面板所有者路径中关闭面板，不再继续进入短语选择。
- 打开面板时保存原前台输入控件；插入前尝试恢复焦点，然后重新执行前台、可编辑性和安全字段检查。
- 方案层开放单击、双击和长按。缺少某一触发方式的配置返回空值，由宿主继承基础映射；显式禁用仍覆盖继承。
- Chrome 和网易云仍需要真实设备和第三方 App 验收。没有该证据时只报告自动化结果和未知外部结果。

## D 验证

- 私有常用语路由回归通过。
- 私有键位方案二级手势继承回归通过。
- 公开宿主现有 Chrome 快捷键事件构造和原生按键时序测试保留，未扩大第三方 App 断言。
- 真实微信、Chrome、网易云和遥控器验收待用户环境完成。
