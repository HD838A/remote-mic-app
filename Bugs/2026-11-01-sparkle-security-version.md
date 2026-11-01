# Sparkle 更新组件停留在已知漏洞版本

- 时间：2026-11-01
- 状态：依赖升级及本机 arm64 Release 编译完成；真实安装更新未验收
- 影响范围：使用 Sparkle 2.9.4 的 macOS App，包括公开兼容包
- 功能点：检查更新、下载与安装更新
- 简单描述：依赖锁文件仍选择 Sparkle 2.9.4，未包含上游已发布的更新安装安全修复。

## 错误证据与日志边界

检查基线 `ca899c4240c410af8039f303c9c004f023f670da`：
`Package.swift` 的最低版本和 `Package.resolved` 的实际版本均为 2.9.4。
这次是构建前依赖审计，没有用户被利用的现场日志，也未运行漏洞利用程序。
不据版本命中推断 SayAll 已发生提权或任意文件覆盖。

上游已公开确认：

- [GHSA-3x7w-j75x-ppq5](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5)：系统域安装时的路径检查与移动竞态，2.9.6 修复；需要本地攻击条件。
- [GHSA-4v99-qgq9-6pxp](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp)：root 更新程序的缓存路径符号链接问题，2.9.6 修复；不能据此声称普通用户模式必然可利用。
- [GHSA-gmj2-gq3j-vqmj](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-gmj2-gq3j-vqmj)：增量更新中的符号链接可能导致目标目录外文件被覆盖，2.9.5 修复；其攻击模型要求更新签名密钥已泄露。

## 根因确认与最小修复

依赖版本与上游公告的受影响区间直接匹配，根因是尚未采用修复版本，
不需要在用户机器上触发危险安装来确认。将最低版本提高到 2.9.6，
显式解析该版本，并提交 SwiftPM 生成的锁文件。

[2.9.6 发布说明](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)
列出上述安装安全修复。它保留现有公开 API 和框架结构，本次不改更新 feed、
签名公钥、自动检查策略、日志字段或安装脚本，也不修改其他审计发现。
`TODO.md` 没有对应的未完成安全升级条目；其中旧版硬件构建结果按历史证据保留。

## 验证

- `swift package --disable-keychain resolve`：通过；先用精确版本生成初始锁文件，再恢复最低版本约束重新解析，锁定 2.9.6 / `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`。SwiftPM 已完成公开二进制摘要校验。
- `swift build --disable-keychain --sdk <macOS-26.5-SDK> -c release --triple arm64-apple-macosx14.0`：通过，编译耗时约 102 秒。
- `swift test --disable-keychain --sdk <macOS-26.5-SDK> --triple arm64-apple-macosx14.0 --filter 'UpdateInformationTests|BuildSigningTests'`：本地未执行测试。App Debug 编译通过，测试目标因本机 Command Line Tools 不含 XCTest 而编译失败；完整测试由 Xcode CI 执行，结果以本 PR 检查为准。
- `scripts/verify-repository-governance.sh`、依赖版本与 Commit 一致性检查、`git diff --check`：通过。
- 本地 App 打包使用单独打包分支递增 Build 后执行 `SAYALL_PRIVATE_PLATFORM_MODE=public RELEASE_VARIANT=apple-silicon scripts/build-app.sh`，并执行 `scripts/verify-app.sh`；具体产物及验收结果随 PR 与本地包交付，不将原始构建日志入库。

本机默认 macOS 27 SDK 还缺少其 SwiftUI `@State` 声明所要求的 `SwiftUIMacros` 插件。
仓库外最小实验在 27 SDK 失败、在已安装的 26.5 SDK 通过，未引用 Sparkle，确认该阻挡
与本次依赖升级无关。测试和构建单次指定 `SDKROOT` 为 26.5 SDK；未修改系统 SDK
链接、全局工具链或业务源码。编译中的现有弃用及 CLT 搜索路径警告不作为新修复处理。

## 验收边界

本机缺少 Developer ID 签名身份，产物只作为 ad-hoc 签名、未公证的本地公开兼容包，
不作为官方发布候选。测试与构建不能证明真实更新安装、漏洞利用复验、硬件语音或
私有组件已经验收。正式分发仍按 `RELEASING.md` 完成签名、公证和真实 Sparkle 更新验证。
