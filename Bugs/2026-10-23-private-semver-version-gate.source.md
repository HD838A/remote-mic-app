---
template: doc
title: 私有 SemVer Tag 被历史 VERSION 校验拒绝
lang: zh
---
## A 证据与根因

私有发布者从 `2.3.0` 起停用根 `VERSION`。
宿主仍要求 Tag 与该文件相同。
新 Tag 因此在构建开始前被拒绝。

隔离 Git 回归已复现相同错误。
旧实现报错 `Private tag must match VERSION`。
本问题发生在发布前置，不涉及用户运行日志。
它不是会员功能本身的根因。

## B 修复与验证边界

`2.3.0` 起以标准 Tag 和精确提交验证来源。
main 祖先关系和根 SwiftPM 清单检查继续执行。
更早 Tag 保留原 VERSION 契约。
有未发布 Mac 变化时，要求私有发布者先发新 Tag。
宿主不从停用文件推导新版本。

执行 `python3 scripts/test-private-platform.py`。
回归覆盖新旧版本、未合入 Tag 和缺少根清单。
原错误用例在修复后通过。
权限降级、来源、脏工作区与过期 pin 检查继续执行。

该回归只证明发布前置契约。
最终二进制集成、签名、公证和真实账号验收另行记录。
