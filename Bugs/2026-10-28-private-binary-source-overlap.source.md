---
title: 私有二进制与源码依赖冲突
template: doc
lang: zh
---

## 错误与证据

签名打包同时传入私有二进制目录和三个遥控器源码目录。
SwiftPM 报告同名 target 冲突，两个架构都在编译前退出。
触发模块为 Mac Remote、Siri Remote 和 Chromecast。

同一 Xcode 27 环境运行 `swift package --disable-keychain show-dependencies --format json`。
修改前退出码为 1，修改后为 0。
该实验确认依赖重复，不能据此认定此前测试停滞的根因。

## 最小修改

Package.swift 在存在二进制目录时，跳过三个源码 package 的注册。
打包脚本仍用源码目录核对 Tag 和构件 Commit。
二进制 product、能力标记和公开兼容层保持原有行为。

## 验证边界

复测公开、源码、二进制和二进制加源码路径四种依赖图。
最终签名、公证、安装包校验单独记录。
本记录不代表遥控器或第三方 App 的真机验收。
