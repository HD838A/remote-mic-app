# Match 精确 SHA 检出导致空 orphan 分支

- 时间：2026-08-24
- 状态：已修复，本地自动化通过；等待受保护 pipeline qualification 复验
- 影响范围：macOS 受保护签名与公证工作流；只影响 Match 身份导入，不影响产品代码
- 原始记录：成功 Run `32544500043`；失败 qualification Run `32661452961`

## 复现

1. 使用 `actions/checkout` 按完整 Commit `2e271768593821611c54f3d1b376f39e503f53be` 检出 Match 仓库。
2. 确认 checkout 为 detached HEAD，且本地没有 `refs/heads/main`。
3. 把该 checkout 作为 `file://` Git URL 交给 Fastlane Match，同时指定 `git_branch=main` 和 `readonly=true`。
4. Match 显示仓库解密成功，随后立即报告找不到 `developer_id_application`，没有进入证书安装和签名探针。

正常边界：Match 必须只消费已审核的精确 Commit，同时其二次本地 clone 必须能看到一个指向该 Commit 的 `main`；不得回退到可漂移远端分支，也不得关闭 readonly 创建新证书。

## 日志结论

成功与失败 Run 使用相同的 macOS Runner image、Xcode 26.3、Fastlane 2.237.0、Team、Bundle ID、Match 参数和 Match Commit。该 Commit 的 Git 树同时包含 Developer ID Application 与 Installer 的加密证书容器。

成功 Run 按默认 `main` 检出 Match 仓库，随后安装两类身份并通过 isolated Keychain 签名探针。失败 Run 只 fetch 精确 SHA 并 detached checkout；Match 在“Successfully decrypted certificates repo”之后直接报告身份不存在。失败发生在证书导入前，因此不是 Keychain ACL、partition list、证书有效期或 Runner 抖动。

## 根因

Fastlane 2.237.0 会再次 clone `MATCH_GIT_URL=file://<checkout>`，并只通过 clone 后的 `origin/main` 判断 `git_branch=main` 是否存在。精确 SHA checkout 没有可发布的本地 `refs/heads/main`，所以二次 clone 也没有 `origin/main`。Fastlane 随后执行 `git checkout --orphan main` 和 `git reset --hard`，得到空工作树；解密空树不会报错，但后续找不到任何签名身份。

本地无秘密夹具已复现：detached checkout 原本包含 6 个证书文件，但二次 clone 看不到 `origin/main`；按 Fastlane 的 orphan 分支逻辑处理后证书文件数变为 0。

## 修复

- 保留 Match 仓库的完整 Commit pin。
- 在验证 checkout HEAD 后，于 Runner 的临时本地仓库建立 `refs/heads/main`，并明确指向同一个已验证 Commit。
- 在接触 Apple 凭据前，通过 `file://` 的 `git ls-remote` 再确认 Match 二次 clone 可见的 `main` 仍是该 Commit。
- `package-macos-release-in-actions.sh` 增加 fail-closed 门禁：本地 `main` 不存在或不等于 pinned HEAD 时，在解密 Match 密码前退出。
- 无秘密回归测试模拟 detached 精确 SHA checkout、建立固定本地 `main`、二次 `file://` clone，并验证 Application 与 Installer 两类目录仍存在。

## 验证

已执行：

```zsh
actionlint .github/workflows/mac-release-package.yml
zsh -n scripts/package-macos-release-in-actions.sh scripts/test-release-pipeline-optimization.sh
./scripts/verify-release-workflow-gh-token.sh
./scripts/test-release-pipeline-optimization.sh
swift test --filter BuildSigningTests
git diff --check
```

本地门禁全部通过，其中 `BuildSigningTests` 为 17/17。最终真实边界仍需由同一 PR 新 Head、新 pipeline digest 和同一 qualification alias 的受保护 Developer ID/Notary Run 证明；本地验证没有读取或使用发布凭据。

## 影响与兼容性

修复只创建 Runner 临时 checkout 的本地 Git ref，不修改 Match 远端、证书字节、产品 Bundle ID、签名身份、App/PKG/DMG 内容或发布版本。现有 readonly、isolated Keychain 和资格验证边界保持不变。
