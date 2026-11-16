# 私有发布构件把本机构建路径带进 2.0.3 发布 App

## 状态

已修复并验证：2.0.3 staging run `43757992029` 通过，publication run `43763008826` 已发布 `v2.0.3` Pre-release。

## 影响范围

- 2.0.3 Preview 发布候选的 Apple Silicon 主程序与 Helpers。
- Intel 分支在同一内容检查中通过。
- 用户功能和运行时行为不受影响；问题只阻断发布内容门禁。

## 错误证据

`macOS Signed Release Staging` run `43749947640` 的两次尝试都在 `verify-app.sh` 的内容检查阶段失败：

```text
RELEASE STATUS lane=apple-silicon stage=app-content-macos result=failed exit=14
RELEASE STATUS lane=apple-silicon stage=app-content-helpers result=failed exit=14
RELEASE STATUS lane=intel stage=app-verify-pre-notary result=passed
```

`exit=14` 对应检查器中的 `/Users/*` 本地路径分类。CI 日志只报告固定组件标签，不输出命中的路径或文件内容。

同一提交在本地用 2.12.2 私有构件重建后，未签名/Ad-hoc 主程序与 Helpers 的本地路径扫描为 0；2.0.2 已发布 App 的 Apple Silicon 主程序与 Helpers 扫描同样为 0。说明失败发生在发布流水线实际使用的私有预构件与最终 App 组合中，而不是应用业务代码的静态字符串。

## 根因

当前 2.12.2 私有发布包中的 Helpers 是带本机构建路径的预构建二进制。2.0.2 当时使用的 Helpers 是另一份更小的干净构件；2.0.3 staging 实际准备出的 2.12.2 Helpers 含有 `/Users/...` 构建路径（包括 `Develop` 与 `Library/Caches` 分类），最终 App 的内容门禁因此拒绝 Apple Silicon Helpers。

主程序同时命中同类路径；公开日志只给出组件标签，未暴露具体对象，因此不能把命中对象归因到某一个私有模块。问题不是已确认的 2.0.3 Swift 业务代码字符串，也不是签名或公证；内容检查发生在公证之前。清洗步骤因此同时覆盖主程序、Helpers 和 Frameworks。

## 修复

新增 `scripts/sanitize-release-paths.py`，在 App 完成复制、裁剪和 `strip` 之后、签名之前：

1. 只处理 `Contents/MacOS`、`Contents/Helpers`、`Contents/Frameworks`、`Contents/Library` 中的 Mach-O。
2. 把 `/Users/...` 前缀替换为等长的 `/build/...`，保持文件长度、偏移和 Mach-O 结构不变。
3. 保留内容门禁明确允许的公开 `sentry-cocoa` 路径。
4. 处理 `/tmp/remote-bridge` 与示例设备地址等其他被拒绝内容。
5. 重新扫描固定组件；仍有拒绝内容时构建失败，且日志只输出组件名和计数，不输出路径。

`scripts/build-app.sh` 在签名前调用该脚本。私有依赖仍是 2.12.2，未修改私有构件、产品行为、签名身份或更新链路。

## 验证

- `python3 scripts/test-private-platform.py ReleaseContentTests.test_release_path_sanitizer_preserves_layout_and_public_sentry_paths` 通过。
- 使用 2.12.2 私有构件重建 Apple Silicon App，`build-app.sh` 输出 `SANITIZE RELEASE PATHS result=passed`；主程序与 Helpers 的本地路径扫描为 0。
- PR CI 与合并后 main CI 通过。
- 2.0.3 staging run `43757992029` 的 Apple Silicon/Intel 签名、公证、内容门禁通过。
- Sparkle 真实 UI 从稳定版 1.9.21 更新到 2.0.3/build 323，首次启动、退出和二次启动通过；公开 Pre-release 的 Apple Silicon 与 Intel ZIP 摘要、签名、公证和 Gatekeeper 复验通过。

## 验证边界

该修复只清除最终 App 中的本机构建路径字符串，不改变私有构件内容、业务逻辑、权限、音频、HID 或更新行为。staging 会继续执行签名、公证、内容门禁和双架构验证；真实 Sparkle UI 验收仍不能由本地扫描或单元测试替代。
