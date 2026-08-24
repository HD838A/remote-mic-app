# macOS Release 资产矩阵测试手册

## 适用范围

- 适用分支：使用 `candidate-provenance.json` 定义 macOS 公开资产矩阵的 `main`、开发分支及其后续 `release/pre-v*` 候选，也适用于私有 GitHub Draft 中的可安装 macOS 测试资产。
- Apple Silicon：`arm64`、macOS 14 及以上。
- Intel：`x86_64`、macOS 13 及以上。
- 本手册验证发布资产、安装入口、Sparkle、CDN 与历史兼容；不授权创建 Tag、Release、签名或公证。

## 测试前准备

1. 使用干净的独立 worktree，并固定到待测提交。
2. 准备两架构已完成 Developer ID 签名、公证和 staple 的产物；无凭据开发回归可使用结构等价的 ad-hoc 产物检查脚本结构，但 ad-hoc 产物不得上传为私有 Draft、公开 Pre-release 或正式版。
3. 安装 `jq`、`rg`、`gh`，并确认可访问 GitHub Releases 与 `https://download.sayall.app`。
4. 不输出或复制 Apple 私钥、P8、Match 密码、Keychain 密码、Sparkle 私钥或部署密钥。

## 用例 1：新候选资产集合由 provenance 唯一定义

1. 运行发布 dry-run 或检查 staging manifest。
2. 核对资产名称：两套 DMG、两套 ZIP、`appcast.xml`、`appcast-intel.xml`、两套架构卸载 PKG、共享 `.zh.txt`/`.en.txt`、一个合并的 `Remote-Mic-<版本>.dmg.sha256` 和 `candidate-provenance.json`。
3. 确认没有 `Remote-Mic-<版本>-Installer.pkg` 或 `Remote-Mic-<版本>-Intel-Installer.pkg` standalone 资产，也没有 `-Intel.zh.txt` / `-Intel.en.txt` 重复说明。

预期结果：`payloadAssets` 中名称唯一、路径安全并完整覆盖除 provenance 自身外的每个公开资产；GitHub 上传集合严格等于 `payloadAssets + candidate-provenance.json`，实际数量由该 manifest 报告。

失败判定：存在缺少、额外或重复资产，provenance 自引用、名称包含路径分隔符，缺少任一架构更新链，或 standalone Installer PKG 再次进入公开清单。

## 用例 2：DMG 内安装器仍完整可用

分别对 Apple Silicon 与 Intel DMG：

1. 验证 DMG 签名、公证、staple、Gatekeeper 和 HFS+ 结构。
2. 只读挂载 DMG，确认根目录仅有对应的 `Install Remote Mic.pkg`。
3. 对内嵌 PKG 验证 Developer ID Installer、架构 Distribution、最低系统提示、payload 中 App/驱动、权限和符号链接。
4. 在对应真实架构 Mac 上打开 Installer.app，检查正常安装；再在错误架构 Mac 上确认安装前显示中英文架构提示且不删除现有 App。

预期结果：移除 standalone 上传不改变 DMG 内安装器字节、信任链或安装行为。

失败判定：DMG 缺少安装 PKG、出现第二个普通入口、内嵌 PKG 未签名/未公证、错误架构未被拒绝，或安装前删除已有 App。

## 用例 3：两套 Sparkle 更新链与共享说明

1. 确认 Apple Silicon appcast enclosure 指向无 `Intel` 后缀的 ZIP，Intel appcast 指向 `-Intel.zip`。
2. 确认两个 appcast 都只引用共享的 `Remote-Mic-<版本>.zh.txt` 与 `.en.txt`。
3. 验证两个 enclosure 的 Ed25519 签名及 appcast 整体签名。
4. 从当前正式版分别用架构匹配的固定候选 feed 发现更新，检查版本、Build、最低系统和更新说明。

预期结果：两架构不会串包，共享说明按中英文显示，旧稳定 feed 保持不变。

失败判定：Intel appcast 引用已不发布的 `-Intel.zh.txt`/`.en.txt`、任一说明 404、签名失败或 Sparkle 选择错误架构 ZIP。

## 用例 4：合并 SHA-256 清单

1. 下载两个 DMG 和 `Remote-Mic-<版本>.dmg.sha256`。
2. 确认清单恰好包含两个 DMG 的精确文件名和 SHA-256。
3. 运行 `shasum -a 256 -c`，确认两项都通过。

预期结果：清单稳定排序并同时验证两架构 DMG；provenance 还应记录清单自身及所有其他 payload 的摘要。

失败判定：遗漏架构、文件名与 Release 不一致、摘要不匹配或清单引用 standalone Installer PKG。

## 用例 5：GitHub/CDN 公开字节

1. 从 provenance 生成唯一排序的公开资产 manifest，并从 GitHub 固定 Tag URL 下载其中全部资产。
2. 从 CDN 固定 Tag URL 下载 manifest 中的同名全部资产，使用最多四路有界并发。
3. 对每一项执行逐字节比较和 SHA-256；对 Apple Silicon DMG额外验证 `HEAD`、`Range` 和 CDN 响应标记。

预期结果：GitHub、CDN 与 staging 均和 manifest 精确同集合且全部为相同字节；任一下载或集合比较失败会使父流程失败。

失败判定：抽样验证、忽略单项失败、CDN 名称白名单拒绝合并校验文件，或公开字节与 provenance 不一致。

## 用例 6：历史 Release 兼容

1. 读取历史 `v1.8.25` 的资产清单与 `candidate-provenance.json`。
2. 从 GitHub 与 CDN 固定 Tag URL 下载历史资产，不修改、删除或替换该 Release。
3. 使用当前发布解析函数确认 Release 资产严格等于该历史 provenance 自身记录的 payload 加 provenance；已晋升的历史 Release 还必须存在且验证 `stable-promotion.json`。

预期结果：旧 URL 继续返回原字节，旧候选仍可按其自身 provenance 晋升；新旧候选都不依赖当前实现的固定数量常量。

失败判定：新代码把当前数量强加给历史 Release、旧 URL 404、忽略历史 provenance 的缺少/额外资产，或为兼容而放宽新候选的精确集合门禁。

## 用例 7：私有 Draft 远端复验

1. 使用私有仓库创建保持 `Draft=true`、`Pre-release=false` 的内部测试版本，不发布、不改变稳定 `latest`。
2. 上传前对最终 DMG/PKG/App 验证 Developer ID Application / Installer、Team ID `L3QHLDRPAY`、Hardened Runtime、嵌套 `codesign --deep --strict`、`stapler validate` 与对应类型的 `spctl`；ZIP 解压后验证内部资产，不对 ZIP 自身执行 staple。
3. 创建 Draft 后重新下载每项资产，比较 GitHub digest、本地 SHA-256 和完整字节，再对下载副本重复步骤 2。
4. 分别使用 ad-hoc App、错误 Team ID、缺少 Hardened Runtime 和无 staple 票据的夹具运行门禁，确认均在上传前失败；再使用纯非 macOS 资产确认不会被错误要求 Apple Team ID。

预期结果：只有正确签名、公证且远端字节一致的 macOS 资产能进入私有 Draft 保留清理阶段；证书、私钥和 notary 凭据值不出现在输出中。

失败判定：私有 Draft 允许 ad-hoc、只验证本地不验证下载副本、只比较摘要不验证签名公证、ZIP 不解压，或纯非 macOS Draft 被 Apple 门禁误伤。

## 稳定功能回归

- README 与故障排查不再引导用户下载未来不存在的 standalone Installer PKG 或单架构 `.dmg.sha256`。
- 两架构卸载 PKG 仍独立签名、公证、可下载，并只移除兼容麦克风边界内的内容。
- 正式晋升继续复用候选 Tag 和原字节，不重建、不替换资产。
- stable latest 与预览版分类规则不变。

## 日志收集

- 保存 provenance、staging 文件名、manifest 报告的数量、大小和 SHA-256；不要记录凭据值。
- 保存 GitHub/CDN 每项下载结果、比较结果和失败的 URL 文件名。
- 保存 appcast enclosure、版本/Build、架构、最低系统和签名验证结果。
- 安装失败时保存 Installer 日志、目标架构、系统版本和最终结果，不只记录“收到事件”或“开始安装”。

## 自动化、代理实测和用户实测边界

- 自动化可证明 manifest/provenance 精确集合、历史 provenance 解析兼容、文件名、摘要、appcast URL、失败传播和 DMG/PKG 静态信任链。
- 代理可在无凭据环境完成脚本 dry-run、历史公开资产下载和结构验证；这些结果不等于新的 Developer ID 候选已经签名、公证。
- 只有受保护工作流能证明最终签名、公证字节；只有真实 Apple Silicon 与 Intel Mac 的 Installer.app、Sparkle UI、安装、卸载和错误架构界面才能完成真实环境验收。
