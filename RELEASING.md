# macOS 发布流程

本流程适用于无线麦SayAll.app 的公开 macOS Preview 和 Stable。当前会话是唯一的发布协调者；不依赖名为“SayAllMac发布管理”的固定命令或任务。

## 合法目标与不变量

- Preview：普通版本从精确 `origin/main` SHA 构建一次；紧急 Hotfix 只允许从当前稳定 Tag 派生的精确 `origin/hotfix/vX.Y.Z` SHA 构建。两者都必须完成真实 UI 升级后才能发布公开 Pre-release。
- Stable：用户明确指定一个已经发布并验证通过的 Pre-release，将它改为正式版；不重新构建。
- 本地测试包：只为验证、不发布时，可以从任意分支或工作树打包。它不参加 Preview/Stable 候选、不上传 Release、不冒用 Preview/Stable 的版本号与已冻结 Build 号；但它仍是「一次打包」，必须按下方 Build 号不变量先递增自己的 `CFBundleVersion`。基线约束的放宽只对「不发布」这一种用途成立。
- Build 号不变量：任何打包前都必须先递增 `CFBundleVersion`，再执行构建、签名、公证或上传。Preview、Hotfix、本地测试包和私有内部 Draft 一律适用，不存在「先打包、需要时再补号」或「只有 Preview 才升号」的例外。递增必须写进源码并被记录：本地测试包和私有 Draft 在独立的打包 worktree 与打包分支里递增并提交，不把递增留在公开 `main` 工作区。**不得为了让工作区变干净而回滚、复用或跳回旧 Build 号**；一个 Build 号只能对应一个已产出的包，已经用掉的号即使没有对应源码提交也不能再次使用，需要继续往前递增。**Build 号的唯一记录是远端已发布的标签**：私有 Draft 的标签形如 `v<版本>-local.<build>`，下一次的起点取远端该形态标签的最大值加一。`Resources/Info.plist` 只保存源码里的起点值，不跟随打包递增，因此**不得**把 `plutil` 读到的数字当作基线——2026-11-02 就因为按 plist 的 270 递增，撞上了已被 `v2.0.0-local.271`–`280` 占用的号段。打包前用 private-draft-release skill 的 `increment_macos_build.sh --plist <Info.plist> --repo <分发仓库>`，它会取远端最大标签与 plist 的较大值再递增；远端不可查时必须先人工确认最大值，不得直接对 plist 加一。**Build 号跨版本连续递增**：升级 `CFBundleShortVersionString` 不重置它——Draft 取远端所有 `v*-local.<build>` 标签的最大值（不限版本），Preview 取 main 上当前 `CFBundleVersion` 之后的下一个可用号。Draft 的版本号同样取自打包 worktree 的 `Resources/Info.plist`，**不固定**为某个值：`v2.0.0-local.N` 只是主线当前恰好在 2.0.0，切到 2.1.0 后 Draft 就是 `v2.1.0-local.N`。
- 发布 Workflow 只能从精确 `origin/main` 运行。普通新候选源码只能来自 `main`；`hotfix/vX.Y.Z` 是唯一允许的新候选源码例外。`release-main` 冻结为只读历史，但已公开的旧 Pre-release 可按兼容晋升门禁完成正式化。
- 发布基线：Draft 与 Pre-release 只能从最新 `origin/main`（外加只含 Build 号递增与 `packaging/**` 政策锁的打包提交）构建，入口门禁见 `scripts/verify-release-baseline.sh`。构建来源写进 App 的 `Info.plist`，发布说明的 `Commit：` 必须来自实际构建树，不得手写。
- 私有内部 Draft：使用 private-draft-release skill 的独立路径，目标仓库固定为 GetSayAll/SayAll，不在公开源码仓库创建内部 Draft。
- 私有内部 Draft 的资产必须先暂存再上传：`scripts/prepare-private-draft-assets.sh <暂存目录> <架构=产物目录> [<架构=产物目录> ...]` 把每个架构的 DMG 与安装包复制成规范名 `SayAll-<版本>-<Build>-<AppleSilicon|Intel>[-Installer].<ext>`，并写出 `staged-assets.json`（名称、SHA-256、字节数）。**不得**把构建目录里的原始文件名直接上传：`gh release upload` 保留本地文件名并会把空白改名（`Install SayAll.pkg` 会变成 `Install.SayAll.pkg`），丢掉 Build 号与架构标识，上传后也无法按文件名回读校验。**每个架构必须覆盖同一组资产种类**，少一个架构的安装包即停止，不得只发布其中一个架构。上传后按 `staged-assets.json` 里的 SHA-256 逐个回读比对，不能按文件名找资产。
- “发布正式版”不是独立构建命令。没有指定现有 Pre-release 时，只能准备 Preview 或报告缺少授权。
- stable latest 不写死版本号。Preview 开始前、公开后和失败恢复前后都必须动态读取 `releases/latest`，确认其为正式稳定版且前后一致；流程不得修改 stable feed。

普通发布只保留一个版本元数据 PR、一次受保护 staging、一次真实 Sparkle UI 验收和一个无 Apple 凭据 publication workflow，不再同步第二条发布主线。Hotfix 只增加一个从当前稳定 Tag 派生的 `hotfix/vX.Y.Z` 和发布后同步回 `main` 的 PR。没有 release/pre-* 候选分支、qualification、Release Guard、编号 rerun、watchdog 或 SLO ledger 状态机。

## 发布前准备

1. 记录用户请求时间 request_started_at 和 request_id。T_ready 表示源码已进入精确 `main` 或已批准 Hotfix 分支、源码分支 CI 和依赖 pin 已通过、版本/Build/Release Notes 已冻结的时刻；Preview 和 Stable 从 T_ready 起均以 30 分钟为纯发布目标。重试不重置时间，也不以时间目标替代签名、公证、staple 或 UI 验收。
2. fetch `origin main --tags`，确认发布控制 worktree 干净、HEAD 与 `origin/main` 精确一致。普通源码必须是同一 `main` SHA；Hotfix 源码必须是 `origin/hotfix/vX.Y.Z` 的精确 HEAD，并由脚本验证当前稳定 Tag、版本和线性历史。
3. 检查产品 Commit 已经通过普通 PR 合入 main。若用户指定 Commit 尚未合入，先在独立集成分支重放指定改动，逐个解决机械冲突，完成普通 PR、双架构 CI 后再继续；冲突涉及产品取舍时报告并暂停该取舍，不接触 Apple 凭据。
4. 检查 `config/release-dependencies.json` 与受保护 workflow 使用相同的私有依赖版本标签，同时确认公开 `Package.swift`、`Package.resolved` 不解析私有仓库；运行 `scripts/verify-release-dependency-pins.sh`。
5. 运行 `scripts/verify-release-ready-main-ci.sh`，确认 Apple Silicon 与 Intel Ventura 的源码分支 push CI 都完成无私有权限也可执行的 Swift tests、项目 self-test 和 Release build。官方发布还须在私有仓库或维护者本机完成同一宿主 Commit 与固定私有 Tag 的集成测试和双架构 Release build。公开 CI 使用公开依赖执行。私有源码验证日志保留在私有环境。脚本名为历史兼容名称，发布控制面 fixture 只能证明其覆盖的流程。

Mac Remote 与其他 macOS 私有组件使用同一个私有 Swift Package。CI 和发布通过私有平台的统一 SemVer 标签解析包；不再把平台子目录伪装成独立远程 Package。无私有依赖的公开构建继续使用现有兼容层。私有平台版本必须从 `main` 发布。`2.3.0` 起以标准 `X.Y.Z` Tag、main 祖先关系和根 `Package.swift` 校验来源；私有仓库已停用根 `VERSION`。更早的不可变 Tag 保留历史 `VERSION` 一致性校验。回退发布流程时须同时回退清单、workflow 和验证脚本；旧版本通过对应的不可变标签回退。

私有 Tag 与 XCFramework 由私有仓维护者在本机产出，本仓库只消费其 Tag 与构件摘要，**不消费任何私有 CI Artifact**：私有仓托管任务全部未执行（额度、账单等原因）不改变这里的发布判定，也不构成「发布未完成」的理由。反之，本仓库的 CI 与 Release 也不得反向成为私有构件的中转站。

### 打包前发布私有 Mac 包

`build-app.sh` 默认使用 `SAYALL_PRIVATE_PLATFORM_MODE=public`，使用公开兼容层完成打包，整个公开路径只访问公开依赖。显式提供私有组件路径表示选择私有集成。官方公证入口显式选择 `required` 模式，缺少任何必需组件即停止。私有源码路径只允许用于本机开发，分发渠道只消费固定 Tag 的已发布二进制。

打包用的新 worktree 里没有 `Apps/MobileWeb/.private/`（该目录被 `.gitignore` 排除、不入库），**打包前先从主工作区把它复制过来**，否则会在 DMG 阶段报 `Developer ID app is missing a production Web Remote relay URL`。

双架构可以在本机并行打包：`PARALLEL_RELEASE_VARIANTS=1 scripts/notarize-release.sh --all` 会同时跑 Apple Silicon 与 Intel 两条 lane。两条 lane 会争用私有平台准备锁（`scripts/prepare-private-platform.py`），此时后到的一条会**等待**前一条释放（`SAYALL_PREPARE_LOCK_TIMEOUT_SECONDS`，默认 600 秒），而不是像以前那样立刻失败。实测并行两架构约 203 秒、串行约 386 秒。

并行时两条 lane 的输出会交错在同一个终端，失败时难以判断是哪条 lane 出问题。因此并行模式会额外把每条 lane 的完整输出分别写到 `RELEASE_VARIANT_LOG_DIR`（默认 `.build/release-logs/`）下的 `apple-silicon.log` 与 `intel.log`；终端实时输出照旧，退出码仍取 lane 自身。排查失败时先看这两个文件，目录可用 `RELEASE_VARIANT_LOG_DIR` 覆盖。

打包耗时的大头不是公证。同一 worktree 热缓存重跑整条 arm64 lane 只要约 193 秒，其中 Apple 公证只占约 50 秒到 2 分钟（从提交到 accepted）；真正的长尾是冷构建——新 worktree 里 `.build` 与 DerivedData 全空，约 10 分钟。因此优化方向是编译缓存，不是公证并行。

`scripts/notarize-release.sh` 里已有 `PARALLEL_PACKAGE_NOTARIZATION=1`，会把安装包与卸载包的公证并行提交。按上面的实测，它最多只省下几十秒到两分钟，默认仍为 `0`；除非打包时特别在意这两分钟，否则不必开启。需要真正压缩打包时间时，先看 opus 构建是否命中跨 worktree 缓存（`scripts/build-apple-remote-opus.sh`，产物缓存在 `~/Library/Caches/com.getsayall.apple-remote-opus/<opus 版本>/<变体>/`），以及是否复用了同一份 `.build` 目录。

有读取权限时，按以下顺序准备：

1. 将 Mac 私有改动通过私有 PR 合入 `GetSayAll/sayall-private-platform` 的 `main`。只比较根 SwiftPM 清单、Mac Remote、组合动作、键位方案、常用语、会员与诊断、Siri Remote、Chromecast 和私有构建工具。网页、服务端、纯 Markdown/HTML 文档和 SwiftPM `Tests/` 测试变化不触发 Mac 包升级。测试变化不进入分发构件，不得据此强制新 Tag 或阻止既有不可变 Tag 的集成。新增 Mac 模块时同步 `scripts/prepare-private-platform.py` 的路径范围。
2. 若上述内容相对最新数字 Tag 有变化，按私有仓库 `docs/release/tagging.md` 发布新的标准 SemVer Tag。`2.3.0` 起不再升级根 `VERSION`。默认升 patch；破坏性接口按 SemVer 升 major。不得给未合入源码或脏工作区打发布 Tag。
3. 在维护者本机运行 `python3 scripts/prepare-private-platform.py release` 核对最新私有 `main`。`2.3.0` 起，存在未发布 Mac 变化时停止，并要求先由私有发布者完成测试、构建与新 Tag 发布；不从停用的 `VERSION` 推导新版本。更早版本保留历史发布兼容路径。测试使用 Debug 模式以保留现有测试接口；正式构建保持 Release 模式。全部本地 SwiftPM 命令使用 `--disable-keychain`。脚本在推送前复核远端 main，并在推送后复核 Tag Commit。没有 Mac 变化时复用原 Tag；不创建 `private-vX.Y.Z`，不移动已有 Tag。
4. 私有 Tag 发布后，运行 `scripts/update-private-dependency-versions.sh --publish` 更新宿主清单；该命令不能替代 `2.3.0` 起的私有发布步骤。该命令在宿主普通 PR 分支执行。私有 Tag 发布成功后，再更新 `config/release-dependencies.json`，验证并通过宿主 PR 合入。Tag 写权限与只读权限不同；无写权限时请有发布权限的维护者完成私有发布。
5. 运行宿主官方打包入口。`release` 与 `internalQA` 渠道通过 `check-release` 和 `artifacts` 验证固定 Tag，并消费该 Tag 的持久发布附件。

官方路径使用只读 GitHub API 验证 annotated Tag、其 Commit 与私有主线的祖先关系和根 Package 清单。主线关系查询使用不包含文件 diff 的 compare 后续页。固定二进制 Tag 及其摘要属于已冻结输入，私有主线后续变化进入下一候选。私有源码发布和本机自动准备仍执行其现有未发布变化检查。

下载后验证发布方 `.sha256`、压缩包、`SHA256SUMS` 和所有构件。`provenance.source_commit` 必须与 Tag Commit 相同，并声明来源干净。prepared package 复用时重新核对其来源和内容摘要。官方路径的读取凭据、附件、来源或摘要出现问题时立即停止。

受保护 staging 使用 `SAYALL_PRIVATE_RELEASE_READ_TOKEN` 读取发布附件。它在公开 runner 上只准备二进制、资源和 Helper。私有源码的测试与构建在私有仓库的 `macos-host-integration.yml` 或维护者本机执行，记录精确宿主 Commit、私有 Tag/Commit、配置和结果。验证记录用于审计，正式构件始终来自 Tag 的持久发布附件。

canonical payload 在上传 Actions Artifact 前执行内容扫描。恢复 staging 和 publication 继续通过同一 verifier 复验。ZIP、安装包及嵌套归档出现私有源码、开发接口、原始 XCFramework、dSYM、日志、凭据或未批准的本机路径时停止上传。

构件准备和签名构建的详细输出保存在 runner 的受控临时日志中，公开日志只记录阶段结果。SDK 接口校验失败和编译错误也使用此输出边界。公开 Artifact 仅包含规定的最终资产和脱敏来源记录。

本机测试未发布的私有修复时，显式设置 `SAYALL_BUILD_CHANNEL=local` 和 `SAYALL_LOCAL_PRIVATE_SOURCE_COMMIT=<完整 SHA>`。手动提供同一干净提交的私有源码路径与 prepared artifacts；构建脚本继续校验二者的 SHA 相同。此入口不创建 Tag，不修改版本清单；`release` 和 `internalQA` 渠道拒绝该提交覆盖。未指定完整 SHA 时，本地渠道仍执行原有 Tag 校验。

### 发布基线门禁与构建来源

Draft 与 Pre-release 必须由「最新 `origin/main` + 允许的打包提交」构建。打包分支当场从 `git fetch origin main` 之后的 `origin/main` 切出，只允许两类提交：`Resources/Info.plist` 的 Build 号递增，以及 `packaging/**` 下的政策快照锁。不得复用功能分支、旧打包分支或已合并的发布分支。

`scripts/notarize-release.sh` 在入口调用 `scripts/verify-release-baseline.sh`，断言：

- `origin/main` 是 `HEAD` 的祖先——方向不能反，只比较 diff 会把「落后 main」看成「只有几个无害的打包提交」；
- `origin/main...HEAD` 只改上面两类文件；
- 工作树干净；
- 显式给出的 `--require <合并提交>` 都在构建树里。

失败时脚本直接退出，不产出包。CI 的 Preview 打包会把基线钉到 dispatch 指定的 `EXPECTED_COMMIT`——源码身份已由 `verify-public-release-source.sh` 校验，而 dispatch 之后 `main` 可能前进，不能再按当时的 `origin/main` 判定。手工核对：

```bash
scripts/verify-release-baseline.sh --require <本次要发布的合并提交>
```

2026-11-05 的 `v2.0.0-local.284` 就是从旧功能分支 `5107cc62` 打的，比当时的 `origin/main 01606521` 少 11 个合并提交（含 #881 卡片修复），而发布说明手写了 `01606521`，两者对不上；事后靠 DMG 摘要才追到打包 worktree。因此另外三条同时成立：

- **构建来源写进产物**：`build-app.sh` 往 App 的 `Info.plist` 注入 `SayAllSourceCommit`（实际 HEAD）与 `SayAllBaselineCommit`（构建时的 `origin/main`）。
- **发布前从产物读回**：`scripts/verify-release-asset-source.sh --asset <DMG/PKG/App> --expected-commit <SHA>` 打开产物、读取 App 的 `SayAllSourceCommit` 并与构建树比对；不一致或缺失即停止。private-draft-release skill 在上传前对每个 macOS 资产调用它。
- **发布说明的 `Commit：` 行由脚本生成**：`scripts/render-private-draft-notes.sh` 按实际构建树与基线改写该行（保留第一个 `；` 之后的内容），不得手写 `origin/main` 的 SHA。
- **Preview 同样读回**：`scripts/package-macos-release-in-actions.sh` 在签名与公证之后、上传之前，对两个架构的 DMG、安装器与 `.app` 逐个调用 `verify-release-asset-source.sh --expected-commit "$EXPECTED_COMMIT"`；CI 缓存或复用旧 `dist` 时会在这一步停下。

### 安装器隐私政策同步

安装包的许可页正文来自官网政策，不在本仓手工编辑：

1. 在私有官网仓修改 `docs/product/policies/privacy.md` 与 `en/privacy.md`，更新 `subtitle` 日期；运行 `node apps/official-sites/sayall-app/scripts/sync-legal-pages.mjs` 与 `node tools/sync-payment-policies.mjs`，部署网站并确认 `/privacy/policy.json` 已更新。页面、`policy.json` 和 sitemap 日期由同一次生成完成，两个官网镜像字节一致。
2. 在本仓运行 `scripts/sync-installer-privacy-policy.py`。默认读取线上 `policy.json`；本机也可用 `--policy-json` 指向私有仓构建产物。提交两份 `License.txt`、`privacy-policy.lock.json` 和必要的文档变更。本地脏工作树同步会把 `source_commit` 记为 `working-tree`，发布校验会拒绝；发布前必须从已部署的线上 `policy.json` 或干净的官网 checkout 重新同步，不能保留 `working-tree`。
3. 打包前运行 `scripts/verify-installer-privacy-policy.py --remote`。`notarize-release.sh` 已在发布构建开始时执行同一检查；官网日期或正文与快照不一致时立即停止，必须显式同步快照并走新的普通 PR 和更高 Build。
4. 不得手工修改 `License.txt`、跳过远程校验，或把网络失败当作无需校验。系统许可页只在图形安装器中显示；`installer -pkg` 与 MDM 安装不会征得同意，也不能作为同意记录。

### Hotfix 准备

只有用户明确要求紧急修复时才使用 Hotfix：读取 GitHub 当前 `releases/latest`，从该 Tag 的精确 Commit 创建 `hotfix/vX.Y.Z`。版本必须是同一 major/minor 的更高 patch；分支只包含该修复、直接相关测试和版本元数据，并保持线性历史。Hotfix 发布完成后必须把修复通过普通 PR 同步回 `main`。不得用 Hotfix 承载一般功能、积压 Bug、依赖升级或发布流程重构。

## Preview 版本元数据

版本元数据必须通过普通 PR 合入 main：

1. 从最新 origin/main 创建普通开发分支和隔离 worktree。
2. 准备中英文 ReleaseHistory、Info.plist 的 CFBundleShortVersionString 和 CFBundleVersion：

   scripts/prepare-preview-release.sh <requested-version> <build> <zh-notes> <en-notes>

3. 脚本只修改这三个文件，并检查 Release Notes 不含内部入口、邀请码、凭据或实现细节。若 Tag、Release 或公开分发资产已经占用请求版本，只递增最后一位并选更高 Build；公开资产占用检查覆盖 10 个 CDN 固定路径，只有 HTTP 404 才算可用，2xx/3xx 视为占用，认证、权限、5xx、超时或其他未知响应 fail closed。单纯的 CI、Runner、GitHub、Apple 或网络故障不占用版本，不得升版本。
4. 运行 git diff --check、Swift/脚本测试和必要的 UI/功能测试，创建普通 PR 合入 main。合入后重新 fetch，记录用于 staging 的精确 `origin/main` SHA；不再同步到其他发布分支。

ReleaseHistory 的版本标题由 `scripts/sync-release-history-labels.mjs` 按 GitHub Release 状态统一标记：正式版使用“正式版 / Stable”，公开候选使用“预发布 / Pre-release”。同步工作流会在 Release 状态变化时运行，并每三天兜底检查一次，也可以手动触发；官网只同步这两份已标记的主仓库文件，不在官网单独判断版本渠道。

元数据 PR 合入后不再创建版本候选分支。产品内容变化必须回到普通产品 PR；公开身份产生后不能覆盖旧 Tag 或资产。Hotfix 的元数据与紧急修复一起位于对应 Hotfix 分支，不另建候选分支。

## Preview staging：受保护的唯一签名入口

AI 整理在本次分发协议中保持关闭。`include_ai=true` 在接触发布凭据前停止，并明确要求先建立已发布二进制协议。本机开发仍可在 `local` 渠道显式接入源码组件。
普通版本从与 `origin/main` 相同的 main worktree 执行；Hotfix 从与远端完全一致的 `hotfix/vX.Y.Z` worktree 执行：

    scripts/stage-macos-preview.sh preview

脚本先做无秘密检查：合法源码分支与精确 SHA、Hotfix 稳定基线、版本/build、stable latest、源码分支 CI、依赖版本、目标仓库、显式 GH_TOKEN 静态门禁和 10 个 CDN 固定路径全部为 HTTP 404。随后始终以 `--ref main` dispatch .github/workflows/mac-release-package.yml，输入 mode、source_branch 和 expected_commit；Workflow 再次独立验证。smoke 只用于受保护流程检查，不创建公开身份。

受保护 workflow 的 package job 才能读取 Apple/Match/Notary/Sparkle 凭据，并且必须：

- 在 mac-release Environment 内使用只读 Match、隔离临时 Keychain 和最小权限；
- 按 `config/release-dependencies.json` 读取固定 Tag 的持久二进制附件并验证来源与摘要，缺少权限、Tag、附件或组件即停止。
- 独立构建 Apple Silicon/macOS 14 与 Intel Ventura/macOS 13 两条 lane；
- 对 App、Framework、XPC、Helper、Installer、PKG 和 ZIP 完成 Developer ID 签名、Apple 公证、staple、Gatekeeper 和权限/符号链接校验；DMG 可以作为内部构建中间产物，但不进入公开下载资产。
- 使用独立 SwiftPM scratch/output，独立提交可并行的 PKG 公证；
- 生成 canonical public bundle、staged-assets.json 和 stage record；
- 上传不可变 payload artifact 与 stage record；
- 不创建 Tag、GitHub Release、appcast 公开地址或任何产品分支。

签名阶段内部 supervisor 1200 秒，单个架构变体预算为 1140 秒，公证阶段预算为 600 秒，GitHub step 硬上限 1800 秒。超时只终止本次阶段并保留第一份错误日志；不静默重打或以升版本掩盖基础设施故障。

## 真实 Sparkle UI 验收

受保护 staging 成功后，在公开 Tag/Release 建立前执行：

1. scripts/prepare-staged-preview-ui-test.sh 下载指定 Run、attempt 和 artifact ID，不使用 latest artifact；同时动态下载并验证发布开始时记录的 stable latest 公开归档。
2. 用本地固定 feed，只把生产 appcast 的不可变 URL 前缀替换为本地地址，确保 enclosure 是 staging 的同一 ZIP。
3. 使用稳定版 App 的真实 Sparkle UI 完成 check、download、install、首次启动、退出和二次启动；验证版本/Build、Team ID L3QHLDRPAY、公证、Gatekeeper、Sparkle helper 的 0755 权限和 Versions/Current 链接。
4. 检查没有新增崩溃报告、应用可以再次启动，并用 scripts/record-preview-ui-attestation.sh 生成结构化证明。仅运行 Sparkle CLI probe、单元测试或静态解压不能替代真实 UI 安装；该步骤未完成时不得公开 Preview。
5. scripts/record-preview-ui-attestation.sh verify 必须重新核对 stage record、manifest、production/test appcast 摘要和安装结果。

### 脚本合并后的入口与 CI 边界

合并只改变工程入口，不改变双架构资产、签名、公证、staple、来源、真实 UI 或公开字节门禁：

| 原入口 | 当前入口 |
| --- | --- |
| package-macos-release-variants.sh | notarize-release.sh --all；不带参数仍执行单架构 |
| resolve-release-dependencies.sh | verify-release-dependency-pins.sh resolve [json\|github-output] |
| verify-release-workflow-gh-token.sh | verify-release-dependency-pins.sh tokens |
| verify-preview-ui-attestation.sh | record-preview-ui-attestation.sh verify |
| test-prepare-preview-release.sh | test-macos-release-flow.sh metadata |
| test-verify-release-ready-main-ci.sh | test-macos-release-flow.sh ready-ci |

test-macos-release-flow.sh 默认运行原 flow、元数据和 CI 证明 fixture。生成 UI 证明和 publication 中的独立验证仍在不同阶段执行；Apple 凭据入口与无凭据上传边界保持不变。

macOS CI 和发布证明共用 verify-release-control-plane-diff.sh 的分类。公开 CI 包含 Ubuntu 分类、公开 Mac 测试及双架构构建、两个架构 summary，Repository governance 独立执行。公开 Job 清空私有路径并使用公开模式。私有集成测试在私有仓库中保留免费与付费两种配置，每种配置以 macOS 13 最低部署目标运行完整 native tests，再构建 Apple Silicon/macOS 14 与 Intel/macOS 13 Release。发布证明仍要求实际产品步骤通过，summary 只汇总适用结果。
BuildSigningTests 按相关源码、资源、构建、安装、依赖或 workflow 变更执行，不在私有配置重复运行。产品变更时，公开 Job 用 --skip-build 复用已编译测试产物；纯发布控制面变更时由同一公开 Job 在 Mac 编译并验证，不再创建独立 Release script checks。summary 门禁要求所有适用检查成功。未知路径以及 mac-ci.yml、产品构建/签名/安装脚本变更仍走完整产品验证，不能因扩展名为 .sh 豁免。减少 Job 和重复 native tests 不保证单次墙钟耗时，仍须用实际 CI 记录比较排队与执行时间。

仅修改开发启动入口 script/build_and_run.sh 时，不触发产品构建或发布检查；该入口不在 CI 中执行，其改动不能冒充新的产品验证证明。发布只允许继承经核对无产品变化的既有双架构证明。

文档、上述手工入口及精确治理 allowlist（verify-repository-governance.sh、repository-governance.yml）的单类改动在 Ubuntu 分类和检查，不启动 Mac、Swift 或私有 checkout。required contexts 保持原名，但只表示适用检查通过，不表示产品重新构建。混合产品、未知路径、mac-ci.yml 和分类器自身改动仍走完整矩阵。发布遇到快速检查时，必须核对同分支 first-parent 的成功双架构产品证明及整个祖先差异；产品差异不得继承。PR 新提交可取消旧 PR CI；main/Hotfix 按 SHA 隔离并保留必要验证，不因新 Push 取消 running 或替换 pending。

2026-10-02 已移除 RC003 专用实验包构建、两个 RC003 启动器、Siri 手工蓝牙 trace、旧语音验收和 Chromecast 旧日志监听工具；这些一次性或过时工具不是当前产品、测试包或日志收集入口。现行测试包使用统一签名、公证流程，日志收集按 Testing/RuntimeLogging.md 执行。历史 Bug 文档中出现的旧工具名称只保留为当时的调查证据。

## Preview publication：无 Apple 凭据

在真实 UI attestation 通过后，从精确 `origin/main` 的干净控制 worktree 执行：

    scripts/publish-staged-preview.sh <preview-ui-attestation.json>

它只 dispatch .github/workflows/mac-preview-publication.yml。该 workflow：

- 只在 `main` 上运行，显式配置 GH_TOKEN，不声明 mac-release Environment，不读取 secrets；
- 目标仓库固定为 `HD838A/remote-mic-app`，并验证触发事件的 `github.sha` 仍是精确 `origin/main`；
- 按 Run/attempt/artifact ID 下载并验证同一 staged payload；
- 创建或复用与 source SHA 完全一致的轻量 Tag；
- 创建或恢复公开 Pre-release，上传 manifest 中的完整 10 项 payload 加 candidate-provenance.json；
- 对已有资产做大小和 GitHub digest 比较，只补缺失项，发现字节不同即 fail closed；
- 若远端 Tag 尚不存在，创建 Tag 前最后一次确认该版本的 10 个 CDN 固定路径全部返回 HTTP 404；任一已占用或未知响应都不创建 Tag。已有 Tag 的幂等恢复跳过占用检查，继续执行固定 Tag/CDN 字节复验；
- candidate-provenance.json 的 `stagedAt`/`publishedAt` 固定取受保护 staging 的时间戳；重试同一 staging 身份不会因当前时间变化而生成不同字节；
- 从 GitHub 固定 Tag URL 和 download.sayall.app 固定 Tag URL 下载每项公开资产并逐字节比较；
- 确认 releases/latest 仍为发布前记录的正式稳定版，且 Release 为非 Draft、Pre-release。

publication 失败时先查询远端状态。若 Tag、Release、资产和摘要已经正确，只重做缺失的公开验证；不要删除 Release、移动 Tag、重签名或重复上传不同字节。公开 Pre-release 的标题和正文与本次候选不一致时也必须 fail closed，不能在重试中覆盖 Release Notes。任何 Tag/Release 查询的认证、网络或非 404 错误都必须 fail closed，不能被当作“版本可用”。

## Stable promotion

只有用户明确给出要晋升的现有 Pre-release Tag（例如 v1.9.11）时才执行：

    scripts/promote-preview-release.sh v1.9.11

脚本和 mac-stable-promote.yml 必须先确认：

- Release 存在且当前是公开 Pre-release；
- candidate-provenance.json、Tag Commit 和 source Commit 一致；
- 当前 schema 5 的普通候选 Tag Commit 已包含在 `origin/main`，Hotfix 候选仍是对应远端 Hotfix 分支的精确 HEAD 并绑定当前稳定基线；历史 schema 4 候选则必须包含在冻结的 `origin/release-main`。
- 10 项 payload 与 provenance 的大小、SHA-256、GitHub digest 完全一致。
- provenance 中的 sourceRunId/sourceRunAttempt 指向成功的 `.github/workflows/mac-release-package.yml` `workflow_dispatch` Run，且 Run 的 `head_branch=main`、`head_sha=sourceWorkflowCommit`、attempt 完全一致；sourceBranch/sourceCommit 则绑定实际源码。signedArtifactId/digest 指向同一 Run 的未过期 payload artifact，另有唯一未过期的 Preview stage-record artifact，记录 `mode=preview` 并与 provenance 的源码、控制面、artifact、manifest、Tag 和时间戳一致。
- 目标仓库固定为 `HD838A/remote-mic-app`，Stable promotion 也只从精确 `origin/main` 控制面执行。晋升按 provenance schema 验证候选身份：schema 5 使用当前 `main`/Hotfix 规则，schema 4 仅允许已公开且可追溯到冻结 `release-main` 的历史候选；未知 schema 或不完整 provenance 一律拒绝。

随后唯一的远端突变是 gh release edit --prerelease=false --latest。Tag、Release Notes、appcast、ZIP、PKG 和 provenance 均保持原字节；晋升不重新构建、签名、公证、staple 或上传。若上一次突变已成功且该 Tag 已是 `releases/latest`，重试只做完整只读复验，不再次突变；所有候选晋升共享一个并发锁，并在突变前再次核对 stable latest。

## 故障分类与重试

| 故障 | 处理 |
| --- | --- |
| 产品代码或版本输入未就绪 | 普通版本回到 main PR；紧急修复回到对应 Hotfix 审核，不能先进入 mac-release Environment |
| Runner、GitHub、Apple、网络或审批失败，尚无公开身份 | 在同一合法源码 SHA、版本、Build 上重试同一 stage；复用成功 artifact |
| staging 已成功，UI 或 publication 失败 | 保留 artifact，修复对应控制面后重新验证；不重签、不升版本 |
| Tag/Release/公开资产已存在且内容需要改变 | 新建普通产品/元数据 PR，选择新的可用版本和更高 Build；旧身份不可修改 |
| stable promotion 条件不满足 | 保持 Pre-release，报告精确缺口；绝不从其他分支重建正式包 |

## 发布后报告

报告 source Commit、版本、Build、两个架构、Run/attempt/artifact ID 与摘要、测试结果、签名/公证/下载字节验证、Sparkle UI 证明、Release 状态和 stable latest。分别报告从 request_started_at 到结果的总耗时，以及从 T_ready 起的 Preview/Stable 纯发布耗时；说明任何未执行的真实硬件、第三方 App 或可见 UI 验收。不得在日志、提交、Release Notes 或聊天中输出证书、私钥、密码、P8、Match 凭据或 Token。

## Release Notes

```governance-policy
G-NOTES.content=user-visible
G-NOTES.unpublished=excluded
```

- 只记录普通用户能够看到或受益的功能、体验、兼容性和可靠性变化。
- 不写提交标题、哈希、CI、文档维护、测试数量、签名、公证、分支规范或发布流程。
- 已撤回、删除或从未公开的版本不进入 App 内版本历史。
