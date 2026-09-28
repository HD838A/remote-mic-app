# 签名发布未预构建 Siri Remote Opus 依赖

- 时间：2026-09-28
- 状态：候选修复完成，等待 GitHub Actions 签名 smoke 验证
- 影响范围：包含私有 Siri Remote 功能的双架构受保护 macOS 发布流程
- 不影响范围：不含私有 Package 的公开构建与普通用户运行时

## 复现与日志

在 `main@ae2f82fd1358bc3db5f89d8bcf79b18238e8fea9` 触发受保护的签名
smoke（Run `36439741807`）。私有 Siri Remote Package 已正确检出，两架构 Swift
编译和 App stage 均完成，但后续安装器构建失败：

```text
Apple Remote audio helper requires a compatible libopus;
run scripts/build-apple-remote-opus.sh or set SAYALL_OPUS_LIBRARY
```

在 Apple Silicon 本机运行 Intel Opus 构建可进一步复现第二层问题：configure
识别为交叉编译，目标文件为 `x86_64`，但 libtool 最终链接仍调用未绑定目标
架构的 clang，因而按宿主 `arm64` 链接并报告架构不匹配。

## 根因

受保护发布 workflow 会构建包含 Siri Remote helper 的 App 和安装器，却没有在签名
阶段前为 Apple Silicon 与 Intel 分别准备 `libopus.0.dylib`。

原构建脚本还要求宿主架构等于目标架构。仅增加 configure 的 `--host` 和把
`-target` 放入 `CFLAGS` / `LDFLAGS` 不足以稳定约束 libtool 的最终 dylib 链接；
libtool 生成的 `archive_cmds` 使用 `CC`，最终链接可能丢失目标参数。

## 修复

1. 受保护发布 workflow 在读取签名身份前，分别构建 Apple Silicon 与 Intel Opus。
2. 交叉编译时向 configure 传入目标 host triplet。
3. 把 `-target` 和 `-isysroot` 固定进 `CC`，确保编译、configure 探测和 libtool
   最终链接使用同一目标；`CFLAGS` 只保留优化参数。
4. 发布流程静态测试守护两个架构的 workflow 调用、交叉编译 host 和目标编译器。

## 验证

- `RELEASE_VARIANT=intel ./scripts/build-apple-remote-opus.sh`：通过；产物为
  `x86_64`，最低系统版本为 macOS 13.0。
- `RELEASE_VARIANT=apple-silicon ./scripts/build-apple-remote-opus.sh`：通过；产物为
  `arm64`，最低系统版本为 macOS 14.0。
- `zsh -n scripts/build-apple-remote-opus.sh scripts/test-macos-release-flow.sh`：通过。
- `./scripts/test-macos-release-flow.sh`：通过。
- `git diff --check`：通过。

## 验证边界

本地验证只证明 Opus 双架构构建和发布流程静态合同。只有修复合入 `main` 后，
对精确 main SHA 运行受保护签名 smoke 并完成 Developer ID 签名、公证、staple、
Gatekeeper 和最终产物检查，才能确认发布阻塞已关闭；它仍不能替代 Siri Remote
实体硬件和音频链路验收。
