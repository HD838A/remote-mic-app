# 项目文档导航

本文只负责帮助开发者、维护者和自动化 Agent 快速定位文档，不定义新的产品或流程规则。规范层级、冲突处理方式和各文档边界以 [`AGENTS.md`](AGENTS.md) 为准。

## AI 与开发者阅读顺序

1. 先完整阅读 [`AGENTS.md`](AGENTS.md)，确认当前任务适用的硬门禁和规范入口。
2. 涉及分支、worktree、提交、PR 或合并时，阅读 [`BRANCH_MANAGEMENT.md`](BRANCH_MANAGEMENT.md)。
3. 开发新功能时，阅读 [`FEATURE_DEVELOPMENT.md`](FEATURE_DEVELOPMENT.md) 和目标功能目录中的 `PRODUCT_SPEC.md`。
4. 根据任务范围继续读取下方对应的专项规范、平台附件、测试手册或历史记录；不要把历史记录当成现行规则。

## 稳定规范入口

| 领域 | 权威入口 |
| --- | --- |
| 仓库硬门禁和规范层级 | [`AGENTS.md`](AGENTS.md) |
| 分支、worktree、提交、PR 和合并 | [`BRANCH_MANAGEMENT.md`](BRANCH_MANAGEMENT.md) |
| 新功能开发流程 | [`FEATURE_DEVELOPMENT.md`](FEATURE_DEVELOPMENT.md) |
| 文件命名 | [`FILE_NAMING.md`](FILE_NAMING.md) |
| 运行日志和复制诊断 | [`LOGGING.md`](LOGGING.md) |
| macOS 发布 | [`RELEASING.md`](RELEASING.md) |
| macOS 界面设计与验收 | 中文 [`design-qa.md`](design-qa.md)；[`design-qa.en.md`](design-qa.en.md) 仅为翻译 |
| PR 填写与检查项 | [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md) |

## 产品规范与跨平台合同

- 功能产品规范使用 `feature/<feature>/PRODUCT_SPEC.md`。当前包括：
  - [`feature/button-mapping/PRODUCT_SPEC.md`](feature/button-mapping/PRODUCT_SPEC.md)
  - [`feature/common-phrases/PRODUCT_SPEC.md`](feature/common-phrases/PRODUCT_SPEC.md)
  - [`feature/first-run-onboarding/PRODUCT_SPEC.md`](feature/first-run-onboarding/PRODUCT_SPEC.md)
- 平台附件使用 `feature/<feature>/platform-<platform>.md`，只能映射平台差异。当前 Onboarding 附件为：
  - [`feature/first-run-onboarding/platform-macos.md`](feature/first-run-onboarding/platform-macos.md)
  - [`feature/first-run-onboarding/platform-windows.md`](feature/first-run-onboarding/platform-windows.md)
- 当前跨硬件行为合同为 [`Testing/HardwareCompatibilityContract.md`](Testing/HardwareCompatibilityContract.md) 和 [`Testing/HardwareVoiceAudioContract.md`](Testing/HardwareVoiceAudioContract.md)。
- 功能目录结构和档案入口见 [`feature/README.md`](feature/README.md)。

## 测试、Bug 与历史证据

- 根目录 [`Testing/`](Testing/) 存放当前测试手册、跨平台合同、候选准备记录和历史测试报告。除明确命名为合同的文件外，测试手册只定义验证方法和证据。
- [`Bugs/README.md`](Bugs/README.md) 是 Bug 记录格式和索引；具体调查位于 `Bugs/`。
- [`TODO.md`](TODO.md) 只记录待办，不是现行产品规范。
- `feature/<feature>/README.md`、`development.md` 和 `testing.md` 保存功能档案、开发记录和历史验证边界，不覆盖 `PRODUCT_SPEC.md`。

## 用户、技术与支持文档

- 普通用户入口：[`README.md`](README.md)、[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)。
- 技术架构：[`TECHNICAL.md`](TECHNICAL.md)。
- AI 环境配置：[`AI_SETUP.md`](AI_SETUP.md)。
- 许可与归属：[`LICENSE.md`](LICENSE.md)、[`LOGO-LICENSE.md`](LOGO-LICENSE.md)、[`COPYRIGHT.md`](COPYRIGHT.md)、[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
- App 内帮助、安装说明和版本历史位于 `Resources/<language>.lproj/` 及 `Resources/` 下对应的本地化 Markdown。
- 带 `.en.md` 后缀的文件是英文翻译；规范冲突时以中文权威文件为准。

## 获取完整文档清单

文档会持续新增，导航页不重复维护每一份测试或历史文件。需要完整清单时，在仓库根目录执行：

```zsh
rg --files -g '*.md' | sort
```

按类别查找：

```zsh
rg --files feature -g 'PRODUCT_SPEC.md' -g 'platform-*.md'
rg --files Testing -g '*.md' | sort
rg --files Bugs -g '*.md' | sort
```
