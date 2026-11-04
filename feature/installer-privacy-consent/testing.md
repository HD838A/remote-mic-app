# 验证记录

当前状态：资源、脚本和构建产物自动化验证通过；真实 Installer 的“同意/不同意”、语言切换、覆盖升级和签名候选包验收尚未完成。

人工步骤统一记录在 [Testing/InstallerPrivacyConsent.md](../../Testing/InstallerPrivacyConsent.md)。

## 已完成验证

- `xmllint --noout` 通过：`apple-silicon.xml`、`intel.xml` 均包含 `<license file="License.txt"/>`，其余结构未变。
- 使用真实 `Distribution` 和 `productbuild --resources packaging/doubao-driver/distribution/Resources` 构建测试产品包，`pkgutil --expand` 后确认：
  - `Resources/zh-Hans.lproj/License.txt`
  - `Resources/en.lproj/License.txt`
  - 两份正文与官网 `policy.json` 对应语言逐字一致。
- `scripts/verify-installer-privacy-policy.py` 离线校验通过：锁文件日期、两份正文 SHA-256、标题和日期一致。
- 用 `source_commit` 为 40 位提交的锁文件副本执行 `--remote --policy-json <官网产物>` 通过；当前仓库锁文件记录 `source_commit=working-tree`（官网改动尚未提交、部署），因此对当前锁执行 `--remote` 会按设计失败并提示先从线上重新同步。
- `scripts/verify-installer-privacy-policy.py --package <测试包>` 通过：展开包内许可声明和两份本地化正文均一致。
- 用现有 `dist/Install SayAll.pkg` 的两个真实组件包（扁平化后）配合当前 `Distribution` 和 `Resources` 重建产品包，`scripts/verify-doubao-driver-pkg.sh <包> install` 全部通过，包括许可声明、两份本地化正文、payload、脚本、架构和签名检查。该包未使用 Developer ID 签名，也未公证。
- 反向验证通过：
  - 修改快照正文一个字符后，校验以非零状态失败并报告 `license sha256 does not match the lock file`。
  - 移除 `Distribution` 的 `<license .../>` 后，校验失败并报告缺少许可声明。
  - 修改官网 `policy.json` 一个字符并重新计算其 `sha256` 后，`--remote` 比较失败并打印首个差异。
- 官网仓 `npm run test:legal` 通过；`npx astro build` 生成 14 个页面，`dist/privacy/index.html`、`dist/en/privacy/index.html` 和 `dist/privacy/policy.json` 与 `public/` 源文件字节一致。
- 2026-11-05 在本机 macOS 27.0.1 用测试产品包打开系统 Installer：许可页出现在“简介”之后，左侧步骤高亮“许可”，显示简体中文正文、更新日期、语言下拉和“打印…/保存…/返回/继续”；正文首段与 `policy.json` 一致。该版本没有显示“同意/不同意”按钮，按钮文案由系统决定，显式同意语义仍需在目标系统上人工确认。
- 官网 `policy.json` 当前记录：中文 `sha256` `788f0b08cef0782b83f9c201892a698595e3c19e3dd50d585a0239f2c6e3bef2`，英文 `sha256` `5484611d14cb65dc425c9498d825bc95267cb95e1e41b4c6b3f303a0106ada6b`，更新日期 `2026-11-05`。中文正文约 4.2K 字符，英文约 13.3K 字符。

## 尚未完成边界

- 已在 macOS 27 确认许可页顺序、中文正文和日期渲染；尚未确认英文界面、完整滚动到底、同意操作后的实际安装、拒绝后的文件系统与 receipt、覆盖升级和旧版 macOS 的按钮文案。
- 尚未用 Developer ID 签名、公证、staple 的 Apple Silicon 与 Intel 候选包执行安装、覆盖升级和卸载回归。
- 尚未确认其他系统语言是否按预期回退英文。
- `installer -pkg` 与 MDM 安装不会显示许可页，这是系统行为，不是本功能的验收通过条件。
- 官网改动尚未部署到生产域名，`https://sayall.app/privacy/policy.json` 在部署前不可用；发布前必须先部署，再从线上 `policy.json` 重新同步，把锁文件的 `source_commit` 从 `working-tree` 改为非预览值（线上同步为 `unknown`，干净的官网 checkout 为 40 位提交），并复验 `--remote`。
