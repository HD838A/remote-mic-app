---
title: HID 诊断窗口过期后仍记录普通按键
template: doc
---

## 证据与根因

已有日志出现大量 `HID FILTER miss armed=false`。
这条日志不表示按键被吞。
`recentArmed` 只在下次 arm 时清理过期条目。
旧判断只检查数组非空，因此窗口可持续到下次 arm。

## 最小修复

诊断条件检查条目的实际过期时间。
停止监听时清空诊断窗口。
原有按键匹配、按住处理和媒体事件规则保持不变。
时间与日志入口可注入，测试不创建系统 event tap。

## 自动化回归

模拟 arm 后输入一个不匹配按键。
有效窗口内保留诊断。
窗口到期后，100 次普通事件都透传且不写 miss。
测试另覆盖匹配按下、匹配释放、停止清理及合成事件绕过。
测试不会向系统投递按键。

## 验证与边界

运行 `swift test --disable-keychain --filter 'KeyboardEventSuppressorTests|ShortcutHardwareModifierStateTests|EventTapPortTests'`。
自动化结果和构建记录见 PR。
真实遥控器、媒体键和连续语音仍需现场回归。
本次不增加定时器，也不增加逐事件日志。
