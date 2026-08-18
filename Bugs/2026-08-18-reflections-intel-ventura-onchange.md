# 回眸页面阻断 Intel Ventura 构建

- 时间：2026-08-18
- 状态：已修复，Intel x86_64/macOS 13 交叉 Release 构建通过；等待 Intel 真机验收
- 影响范围：macOS Intel Ventura 发布线；Apple Silicon macOS 14 及以上不受该编译错误影响
- 功能点：回眸页面、Intel 发布构建
- 简单描述：回眸时间线使用 macOS 14 才提供的双参数 `onChange`，导致 `x86_64-apple-macosx13.0` Release 构建失败。
- 原始记录：`RELEASE_VARIANT=intel swift build -c release --triple x86_64-apple-macosx13.0` 编译日志

## 复现

在包含回眸功能的 `1.9.0` 集成分支执行 Intel Ventura 交叉 Release 构建。编译器在 `TranscriptHistorySection.swift` 的应用列表、当前应用、日期分组及横向滚动四处报告 `onChange(of:initial:_:) is only available in macOS 14.0 or newer`。

Apple Silicon 默认构建目标为 macOS 14，因此同一代码可以通过；错误只在明确使用 Intel Ventura 的 macOS 13 部署目标时出现。

## 日志与根因

构建日志精确指向四个双参数闭包。代码检查确认这些回调都不使用旧值，只需要变化后的值或单纯触发重新归一化，因此没有必须依赖 macOS 14 API 的行为。

根因是回眸功能在旧分支上仅完成 Apple Silicon 构建，移植到仍支持 Ventura 的双架构主线后，没有先执行 Intel triple 编译门禁。

## 修复

将四处回调改为 macOS 13 可用的单参数 `onChange(of:perform:)`，保持应用筛选、日期展开和自动滚动行为不变。新增源码回归断言，确保 Intel 发布线不再引入这些已知双参数回调。

## 验证

- 修复前：Intel x86_64/macOS 13 Release 编译稳定失败。
- 修复后：同一 Intel 交叉 Release 构建通过；源码防回归测试通过。主程序和 `SayAllMCP` Helper 均为 x86_64，最低系统版本为 macOS 13.0。
- 完整 Swift 测试、Self Test、Apple Silicon App 构建与验证需要继续保持通过。

## 验证边界

交叉编译只能证明源码和产物满足 x86_64/macOS 13 构建边界，不能替代 Intel Ventura 真机安装、启动、回眸页面点击、真实 MCP 客户端和 Developer ID 签名包验收。
