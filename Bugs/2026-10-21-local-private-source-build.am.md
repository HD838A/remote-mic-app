---
title: 本地测试包拒绝未发布的私有修复
template: doc
---
## 复现与根因
用户要求查看已提交的兑换弹窗修复。
在宿主主线运行私有源码检查，脚本报告：
`Private packaging requires a clean checkout of the manifest tag`。
源码检查把本地测试与正式发布都限定为清单 Tag。

## 修复范围
本地测试必须显式指定完整提交 SHA。
工作区必须干净，且具有根 Package.swift。
二进制与私有源码继续使用同一提交。
release 与 internalQA 渠道拒绝本地提交覆盖。
未提供提交 SHA 时，保留原有 Tag 校验。

## 验证与边界
运行 `python3 scripts/test-private-platform.py`，21 项测试通过。
覆盖本地干净提交、错误 SHA、脏工作区与正式渠道拒绝。
运行 `zsh -n scripts/build-app.sh`，语法检查通过。
本机固定提交预检通过。
完整 App 的资源、签名和启动结果记录在本次构建目录。
这些检查不能替代真实遥控器与支付验收。
