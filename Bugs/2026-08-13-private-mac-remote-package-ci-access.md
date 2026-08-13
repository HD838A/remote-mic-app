# GitHub Actions 无法读取私有 Mac 远控组件

- 时间：2026-08-13
- 状态：已修复，两架构 CI 验证通过
- 影响范围：Apple Watch Mac 入口 PR 的 Apple Silicon 与 Intel Ventura CI，以及后续预览候选和正式签名流程
- 功能点：`SayAllMacRemote` 私有 Swift Package 依赖访问
- 简单描述：本地测试和 Release 构建通过，但 GitHub runner 无法匿名克隆私有组件，导致两架构都在 `swift test` 解析依赖时退出。
- 原始记录：GitHub Actions Run `31714444168`，Jobs `94495435712`、`94495435819`。

## 复现

在未配置 `GetSayAll/sayall-mac-remote` 访问凭据的 GitHub Actions runner 上执行：

```zsh
swift test
```

Apple Silicon 与 Intel Ventura 都在测试编译前失败：

```text
fatal: could not read Username for 'https://github.com': terminal prompts disabled
error: 'sayall-mac-remote': Failed to clone repository
```

正常边界：CI 应以只读凭据检出固定 revision `da7f0bcd94af1478c9572ec558771f85ec306480`，SwiftPM 使用该本地 checkout；不应在日志、源码、缓存或构建产物中暴露部署私钥。

## 日志结论

两条架构任务均已完成仓库 checkout、私有 AI 组件 checkout、格式与仓库边界检查。失败发生在 `swift test` 拉取依赖阶段；公开 Sparkle 依赖可正常获取，只有私有 `sayall-mac-remote` 返回认证错误。没有执行到测试用例、项目自检或 Release 构建，因此不能把失败归因于产品代码或架构兼容性。

## 根因

`Package.swift` 固定了私有组件的 HTTPS revision，但现有工作流只为 `GetSayAll/sayall-ai` 配置了独立部署密钥。GitHub Actions runner 没有本机凭据，也禁止交互式输入用户名，所以 SwiftPM 无法解析新增私有依赖。本地环境已有该仓库访问权限，因而此前本地验证没有暴露这个 CI 边界。

## 修复

- 为主仓 Actions 配置一把仅对 `GetSayAll/sayall-mac-remote` 有读取权限的独立部署密钥。
- PR CI、预览候选和正式签名工作流都显式检出固定 revision，并通过 SwiftPM 本地 mirror 使用该 checkout，不改写 `Package.resolved`。
- 普通开发环境未设置该路径时仍使用固定远端 revision；不改组件版本，不扩大密钥权限，也不复用 Apple 签名或公证凭据。
- 增加构建签名回归断言，防止三条工作流后续遗漏组件 checkout、路径配置或固定 revision。

## 验证

要求重新执行原始失败的 Apple Silicon 与 Intel Ventura PR CI，并继续通过：

- `swift test`；
- 核心首次语音旅程门禁；
- `./scripts/test.sh`；
- 两架构 Release 构建。

同时本地配置相同的 SwiftPM mirror 后运行 Swift 测试和 Release 构建，确认 `Package.resolved` 保持不变，并检查 `git diff --check`、仓库边界与敏感信息扫描。此 Bug 只涉及依赖认证和构建输入，不证明真实 Apple Watch 发现、授权、按键或麦克风已经验收。

本地已确认：211 项 Mac 测试通过；Build Signing 12 项通过；Apple Silicon 与 Intel Ventura Release 构建通过；组件精确为 `da7f0bcd94af1478c9572ec558771f85ec306480`；`Package.resolved` 未改变；仓库边界、diff 和敏感信息检查通过。最终状态仍以重新触发的 GitHub Actions 两架构结果为准。

GitHub Actions Run `31715653640` 已完成重验：Apple Silicon Job `94499588630` 与 Intel Ventura Job `94499588743` 均通过私有组件 checkout、SwiftPM mirror、Swift 测试、核心首次语音旅程门禁、项目自检和 Release 构建。认证失败已由同一原始用例从失败变为通过。
