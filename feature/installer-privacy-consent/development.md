# 开发记录

## 关键设计

```text
官网政策源 privacy.md / en/privacy.md
  → tools/sync-payment-policies.mjs（校验源稿、两站镜像和小程序正文）
  → apps/official-sites/sayall-app/scripts/sync-legal-pages.mjs
  → 两站 /privacy/、/en/privacy/ 页面 + sayall.app 的 /privacy/policy.json
  → scripts/sync-installer-privacy-policy.py
  → Resources/<lang>.lproj/License.txt + packaging/doubao-driver/privacy-policy.lock.json
  → Distribution <license file="License.txt"/>
  → productbuild / productsign / notarize / staple
```

许可正文不手工维护。官网构建从 Markdown 生成页面和 `policy.json`；本仓同步脚本只消费 `policy.json`，校验其中每个语言的 `sha256` 后再写入快照和锁文件。发布脚本在构建安装包前拉取线上 `policy.json`，与快照逐字比对，不一致立即失败。

“绝对一致”的边界是发布时刻：签名后的安装包无法跟随官网后续修改。正文顶部保留更新日期，末尾保留官网地址，用户可据此确认自己同意的版本。官网更新政策后必须重新同步本仓并发布新包，旧包继续保留其内置版本。

## 涉及文件

- `packaging/doubao-driver/distribution/apple-silicon.xml`、`intel.xml`：增加 `<license file="License.txt"/>`。
- `packaging/doubao-driver/distribution/Resources/zh-Hans.lproj/License.txt`、`en.lproj/License.txt`：官网政策逐字快照。
- `packaging/doubao-driver/privacy-policy.lock.json`：更新日期、政策 URL、每种语言的正文 SHA-256，以及同步来源的 `source_commit`。干净 checkout 记录 40 位提交，脏工作树记录 `working-tree`（`--remote` 会拒绝发布），无法取得时为 `unknown`。
- `scripts/sync-installer-privacy-policy.py`：从线上或本地 `policy.json` 更新快照与锁；`--check` 只检查不写入。
- `scripts/verify-installer-privacy-policy.py`：离线校验快照、锁和展开后的 PKG；`--remote` 校验线上政策。
- `scripts/build-doubao-driver-pkg.sh`：打包前确认许可资源存在并运行离线校验。
- `scripts/verify-doubao-driver-pkg.sh`：安装包校验阶段检查许可声明、两份本地化文本和逐字一致性。
- `scripts/notarize-release.sh`：签名发布流程在构建 PKG 前增加 `privacy-policy-remote-verify` 阶段。
- 私有官网仓 `tools/sync-payment-policies.mjs`：唯一源稿校验器，比对两站镜像的内嵌源稿并生成小程序正文。
- 私有官网仓 `apps/official-sites/sayall-app/scripts/sync-legal-pages.mjs`：从 `docs/product/policies/privacy.md` 生成两站页面正文、`policy.json` 和 sitemap 日期；保留线上政策页视觉壳，`--check` 纳入 CI。它是手动运行的内容同步器，不挂在构建前置，避免在 Cloudflare 构建时改写已提交页面。

## 常用命令

改官网政策后，先在私有仓重新生成两站页面与 `policy.json`：

```bash
cd ../sayall-private-platform
node apps/official-sites/sayall-app/scripts/sync-legal-pages.mjs
node tools/sync-payment-policies.mjs
```

从私有仓本地产物同步（推荐，避免依赖线上部署时序）：

```bash
scripts/sync-installer-privacy-policy.py \
  --policy-json ../sayall-private-platform/apps/official-sites/sayall-app/public/privacy/policy.json
```

从线上同步：

```bash
scripts/sync-installer-privacy-policy.py
```

只检查本仓快照是否落后：

```bash
scripts/sync-installer-privacy-policy.py --check
```

离线校验快照、锁和真实安装包：

```bash
scripts/verify-installer-privacy-policy.py
scripts/verify-installer-privacy-policy.py --package dist/SayAll-<version>-<build>-AppleSilicon-install.pkg
```

校验官网当前政策与快照逐字一致：

```bash
scripts/verify-installer-privacy-policy.py --remote
```

## 失败行为

- `policy.json` 缺少语言、版本不支持、更新日期格式错误、正文不以换行结束或 `sha256` 不匹配时，同步脚本拒绝写入。
- 快照、锁、展开包正文任一哈希不一致时，离线校验失败；安装包校验脚本一并失败。
- 线上政策日期或正文与快照不一致时，发布流程在构建 PKG 前停止，必须显式同步快照、提交 PR 并重新发布，不能在现场修改文本绕过门禁。
- 网络不可达、`policy.json` 返回非 JSON 或 HTTP 错误时 fail closed；不得把网络失败当作“无需校验”。

## 兼容与签名

`productbuild --resources` 会把 `Resources/<lang>.lproj/License.txt` 写入产品包，并被后续 `productsign`、公证和 staple 视为包内容；许可资源不改变组件包、安装脚本、payload、Bundle ID、receipt 或卸载逻辑。锁文件位于 `packaging/doubao-driver/`，不进入安装包，只用于本仓审计。

## 已知限制

- 系统许可页只在图形安装器显示；命令行和 MDM 安装不会征得同意，也不会留下同意记录。
- 系统按钮文案随 macOS 版本变化：macOS 27 实测许可页会弹出“同意/不同意”确认面板（另有“阅读许可”），许可页底部是“打印…/保存…/返回/继续”。本仓只能控制许可正文，不能自定义按钮或增加勾选框。
- 其他系统语言目前没有本地化资源，Installer 预期回退英文，仍需人工确认。
- 许可页是系统 UI，无法自定义按钮文案、布局或同意记录。
