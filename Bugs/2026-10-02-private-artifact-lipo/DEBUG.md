# 私有构件双架构检查

## Observations

Xcode 27 本机从干净私有来源构建 8 个模块，构件 checksum 与来源检查通过。
当前 main 转换脚本在首个 MembershipCore 上报
`lipo: -verify_arch requires exactly one input file`，失败现场保留。

## Hypotheses

- H1（ROOT）：多架构参数被当前 lipo 解析为多个输入。支持：单一 binary 路径仍失败；试验分别检查两架构。
- H2：二进制不含 Intel。支持：校验失败；冲突：构建 lipo 已通过；试验读取 -info。
- H3：解包损坏或路径误配。支持：转换阶段失败；冲突：checksum 通过；试验精确路径单架构检查。

## Experiments

原 `lipo binary -verify_arch arm64 x86_64` 稳定失败；
换参数顺序仍失败；`-info` 显示 x86_64 与 arm64。
分别执行 `lipo binary -verify_arch arm64` 和 `lipo binary -verify_arch x86_64` 均成功。
只改变调用参数，不修改二进制或构件内容，无临时产品代码。

## Root Cause

当前 lipo 不接受本脚本的一次双架构校验调用；两架构都真实存在，不是构件缺失。

## Fix

对普通模块、Diagnostics 与 Sentry 分别校验 arm64 和 x86_64，两项均必须通过。
不放宽 checksum、来源、内容、大小、安全及资源门禁。不部署或发布 App。

## Validation

修复前失败、修复后同一完整构件转换通过；记录精确命令与结果在对应 PR。
不涉及真实设备、会员数据或 App UI。
