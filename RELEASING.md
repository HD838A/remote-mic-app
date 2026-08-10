# macOS 发布分支规范

## 分支职责

- 功能、修复和用户可见文案先通过 Pull Request 合入 `main`。
- macOS 预览候选使用一次性的 `release/pre-vX.Y.Z` 分支。
- 候选分支必须从最新 `origin/main` 创建，只允许包含版本号、Build、对应版本历史和测试手册目标版本等发布元数据。
- 不得在候选分支直接开发功能、合入其他开发分支或混入尚未验收的工作树内容。
- 每个版本只使用一个候选分支；失败候选保持 Tag 和 Release 不变，修复后递增版本与 Build，并创建新的候选分支。
- 候选分支在正式晋升完成前必须保留在远端，供来源校验、自动合并和 Release 守卫使用。

## 预览候选流程

1. 将计划发布的功能通过 PR 合入 `main`，等待 macOS CI 通过。
2. 从最新 `origin/main` 创建 `release/pre-vX.Y.Z`。
3. 只修改 `Resources/Info.plist`、中英文 `ReleaseHistory.md`，以及确有必要的 `Testing/*.md` 目标版本。
4. Push 候选分支。GitHub Actions 自动执行分支来源校验、Swift Testing、Self Test、Release 编译和临时 App 打包。
5. 使用受信任发布机的 readonly Match、随机密码隔离 Keychain、独立 P8 凭据仓库和 Sparkle 私钥完成签名、公证与正式候选制品构建。
6. Tag、远端候选分支和发布资产必须解析到同一个提交。GitHub Release 必须保持 Pre-release，稳定 `latest` 不得变化。
7. 从公开 Release 重新下载全部资产并逐字节复核；使用公开稳定版执行固定候选 appcast 的真实 Sparkle 更新。

GitHub 自动生成的 CI App 只用于验证打包结构，不是已签名、公证的公开安装包。完整签名发布在受保护的 CI 发布环境完成前，继续使用既有无交互发布机流程。

## 正式晋升

- 只有用户明确指定具体版本并要求正式发布时才允许晋升。
- 先通过 PR 将原候选提交合入 `main`，保留原 Tag 和原资产，不重新构建。
- 晋升前必须证明 Tag 提交已包含在 `origin/main`，并复核 `candidate-provenance.json` 中的分支、提交和资产摘要。
- 正式晋升只修改现有 GitHub Release 的分类和 `latest` 状态，不替换任何候选资产。
- GitHub 页面上的人工“设为正式版”只视为晋升请求；Release 守卫会先恢复为 Pre-release，校验候选来源，创建或复用候选分支到 `main` 的 PR、显式调度必需 CI 并启用 Auto-merge。CI 成功后，受保护的晋升工作流确认带授权标签的 PR 已合入 `main`，再只晋升原 Tag 和原资产。
- 晋升脚本从候选的 `candidate-provenance.json` 读取版本和 Build，不依赖 `main` 当时的 `Info.plist`；因此后续开发已经提高版本号时，仍可安全晋升较早的已验收候选。

## Release Notes

- 只记录普通用户能够看到或受益的功能、体验、兼容性和可靠性变化。
- 不写提交标题、哈希、CI、文档维护、测试数量、签名、公证、分支规范或发布流程。
- 已撤回、删除或从未公开的版本不进入 App 内版本历史。
