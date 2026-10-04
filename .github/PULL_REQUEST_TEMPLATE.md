## 变更摘要

说明用户问题、目标、范围和明确不做事项。

## 变更类型

- [ ] 新功能
- [ ] Bug 修复
- [ ] 文档、测试或内部维护

> 新功能 PR 必须完整遵守 [新功能开发规范](https://github.com/HD838A/remote-mic-app/blob/main/FEATURE_DEVELOPMENT.md)；分支和提交遵守 [分支与提交管理策略](https://github.com/HD838A/remote-mic-app/blob/main/BRANCH_MANAGEMENT.md)；仓库专项门禁遵守 [仓库开发规则](https://github.com/HD838A/remote-mic-app/blob/main/AGENTS.md)。Bug 或文档 PR 可将明确不适用的项目标记为 N/A，但不得跳过适用门禁。

## 新功能开发基线与查重

- [ ] 不适用：此 PR 不是新功能。
- [ ] 已执行 `git fetch origin main`，并从最新 `origin/main` 创建本功能的独立分支和持久化 worktree。
- [ ] 已在提交 PR 前检查最新 `origin/main`，记录影响判断，并按需同步和验证。
- [ ] 已扫描全部 Open PR 标题和标签，详细检查相关候选的描述、文件和必要 Diff。

开发起点 `origin/main` SHA：

Open PR 查重日期、查询结果及相关链接：

## 隐私与跨应用边界

- [ ] 未读取、解析、复制或依赖第三方 App 的私有文件、数据库、沙盒数据、历史记录、私有运行库、私有协议或未公开格式。
- [ ] 第三方 App 集成仅使用公开 API、公开协议、用户可见的辅助功能界面或用户明确选择的文件。

## UI 实际运行截图

- [ ] 此 PR 没有用户可见 UI 变更。
- [ ] 此 PR 包含 UI 变更，已在下方附上本次 Commit 的生产 UI 实际运行截图，并覆盖必要语言、浅色/深色、窗口尺寸和关键状态。

截图对应 Commit、版本/构建、窗口尺寸和生成方式：

在这里直接粘贴 GitHub 图片附件或持久化证据链接。设计稿、孤立替代视图、本地不可访问路径或文字声明不能代替实际运行截图。

## 实现与验证

列出修改的模块和文件，并说明每项修改的必要性。

- 自动化测试：
- 构建与静态检查：
- 脱敏日志验证：
- 实际运行与截图：
- 真实硬件、系统权限、音频或第三方 App 验收：
- 未覆盖边界：

## 文档与兼容性

- [ ] 已检查并按需更新 `TODO.md`。
- [ ] 面向用户的新功能已新增或更新 `Testing/` 测试手册。
- [ ] 已遵守 `LOGGING.md`，并验证受影响的成功、失败、取消、超时、重试和恢复路径。
- [ ] 已检查旧版本、默认配置、Feature Flag、共享协议、持久化、硬件和平台兼容性。
- [ ] PR 只包含本功能和直接必要的修改，没有无关重构或其他功能。
- [ ] 新增或恢复的工程辅助文件不含临时探针、手工 trace、一次性采集、实验包构建或启动器。

新增工程辅助文件的长期职责、复用现有入口的评估及维护方式（同时填写 helper_purpose，没有新增时写 N/A）：

## 核心治理文件变更

- [ ] 本 PR 未修改 `AGENTS.md`、`BRANCH_MANAGEMENT.md`、`FEATURE_DEVELOPMENT.md` 或 `.github/PULL_REQUEST_TEMPLATE.md`。
- [ ] 本 PR 确需修改核心治理文件，已在提交信息中加入 `[governance-change]`，并在变更摘要中列出变更前后规则、影响范围、迁移方式和明确不做事项；该变更不与无关产品或发布工作混合。

## 规范变更对照与 CI 授权

下方稳定字段供检查脚本读取。每个字段只填写一次。普通 PR 使用 `kind=product` 或 `maintenance`；独立治理 PR 使用 `kind=governance`，并填写具体前后规则、文件范围、迁移及不做事项。正文可以使用表格补充逐项对照。

治理本地检查结果填写 `validation_result=pass|pending|fail`；Ready 必须为 pass。治理批准使用 `approval_basis=approved-plan` 或 `reviewed-result`，填写批准来源和批准范围。已批准具体方案且实施一致时，无须再次确认；未获具体批准时使用 `pending` 并保持 Draft。`plan_changed` 必须反映批准后是否新增范围或风险；变化后仅原方案批准不足以 Ready。

CI 默认使用 `ci_mode=default`。仅有当前 PR 的明确用户指令时，使用 `no-wait`、`skip` 或 `allow-failure`，并填写授权、范围和真实未验证项。例外不免除其他门禁，也不取消已运行 CI。大文件预授权在正文记录类型、路径、用途、总预算及余额。

```governance
kind=maintenance
before=N/A
after=N/A
files=N/A
scope=N/A
migration=N/A
excluded=N/A
product_files=false
documentation_synced=true
approval_basis=pending
approval=N/A
approval_scope=N/A
plan_changed=false
validation=N/A
validation_result=pending
ci_mode=default
ci_authorization=N/A
ci_scope=N/A
ci_unverified=N/A
helper_scope=N/A
helper_purpose=N/A
```

新增工程辅助文件时，填写 `helper_scope=permanent` 和具体 `helper_purpose`。没有新增时保留 N/A。字段中不得填写凭据或用户数据。

兼容性、迁移、回滚和已知风险：

## PR 状态

- [ ] 所有必须证据已经补齐，可以进入合入评审。
- [ ] 仍有验证或截图待完成，因此保持 Draft。
