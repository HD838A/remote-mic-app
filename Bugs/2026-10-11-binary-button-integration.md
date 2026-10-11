---
title: 私有二进制包缺少统一按键配置
subtitle: 2026-10-11 · Build 245 实际窗口与 SwiftPM 清单证据
template: doc
lang: zh
---

## 错误证据

Build 245 使用固定私有二进制组件。实际窗口的组合动作管理页显示两个已存动作。按键页的自定义动作区却没有这些动作。

动作库可读，不能将此问题归因于库文件损坏。该包不通过实际绑定验收。

## 根因与实验

Package.swift 只通过源码目录中的 UnifiedButtonConfiguration.swift 判断统一接口是否可用。二进制集成禁止同时提供源码目录，因此该判断始终为 false。

实际 SwiftPM dump-package 显示宿主和测试目标均缺少 SAYALL_UNIFIED_BUTTON_CONFIGURATION。宿主 libraryActions 因此走空数组兼容路径；引用位置及其他统一接口也未启用。

新增回归实际求值公开与二进制配置。修复前，二进制配置在宿主和测试目标各失败一次。修复后，27 项 BuildSigningTests 通过。

此前源码集成通过，因为源码标记存在。此前包校验只证明模块、签名和公证，不证明统一接口进入最终宿主。

## 最小修复

- Package.swift：私有二进制或具备统一接口的源码组件均启用统一配置。
- BuildSigningTests.swift：验证清单实际输出；不下载私有组件，不依赖其源码。
- Testing/UnifiedButtonConfiguration.md：增加二进制构建和最终包点击验收。
- TODO.md：记录修复与未完成边界，不提前勾选硬件验收。

不修改动作格式、私有组件、付费策略、语音手势或音频协议。公开无私有权限构建继续关闭该可选接口。

## 验证与日志边界

执行 swift test --disable-keychain --filter BuildSigningTests。二进制 Release 构建和全量公开测试单独记录结果。

最终签名包必须显示前十项；搜索名称或 ID 后更新；选择、关闭、重开和重启保留绑定；同一动作的所有使用位置均须可见。随后执行真实 Sparkle 升级。

此修复恢复既有统一绑定日志。最终点击须核对 select_combination 的请求及 stored 回读阶段。stored 不表示实体遥控器或第三方工具已执行。

构建条件没有运行时取消、超时或重试。日志不得记录搜索内容、动作名称、动作 ID 或设备身份。真实硬件与文字上屏仍待现场验证。


## 修复后实际窗口

公开完整测试848项、BuildSigningTests 27项、自检48项通过。Apple Silicon及Intel私有二进制Release编译通过。

内部Developer ID App在1020×772生产窗口完成实际点击。前十项显示、名称/ID搜索、选择保存、两个使用位置、未绑定入口及正常重启保留通过。使用12个合成QA动作；退出后恢复原用户配置。原始截图及摘要见[清单](../Screenshots/binary-button-integration/manifest.json)。

内部App未公证，不用于分发。最终公证包与真实Sparkle安装仍待验证。实体遥控器与第三方结果未验收。
