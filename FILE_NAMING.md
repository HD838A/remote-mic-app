# 仓库文件命名规范

## 适用范围

本文规定本仓库新增或重命名文件、目录时的命名方式。规范根据仓库现有结构整理，目标是让路径可理解、同类文件可预测，同时避免为了形式统一而批量改写已有链接、脚本、发布资产或兼容名称。

判断一个名称是否清晰时，必须查看完整的仓库相对路径，不能只看文件 basename。例如：

- `feature/first-run-onboarding/PRODUCT_SPEC.md` 表示“首次使用设置向导功能的权威产品规范”，目录已经提供 Onboarding 作用域，文件名只需表达文档角色。
- 不应改成 `feature/first-run-onboarding/ONBOARDING_PRODUCT_SPEC.md`，因为这会重复目录已经表达的作用域。
- 如果文件位于仓库根目录，`PRODUCT_SPEC.md` 会缺少产品或功能作用域，不应使用这种名称。

## 基本原则

1. **路径共同表达语义**：目录名表达领域或功能，文件名表达该目录内的角色、对象或变体。
2. **不重复作用域**：父目录已经准确限定功能时，文件名不重复功能名。
3. **脱离上下文仍可定位角色**：通用 basename 只用于约定明确的入口或角色文件，例如 `README.md`、`PRODUCT_SPEC.md`、`development.md` 和 `testing.md`。
4. **同类使用同一形式**：同一目录层级、同一用途的文件保持一致的大小写、分隔符和后缀顺序。
5. **兼容边界优先**：Bundle ID、可执行文件、安装包、发布资产、外部协议、系统约定文件和历史公开链接不得仅为统一命名而修改。
6. **不批量追溯改名**：本规范主要约束新增文件和本次工作明确涉及的重命名；历史文件只有在收益明确、引用可完整迁移且兼容性不受影响时才调整。

## 目录与文档命名

| 位置或用途 | 命名方式 | 示例 |
| --- | --- | --- |
| 仓库固定入口 | 使用生态约定或项目既有的大写名称 | `README.md`、`AGENTS.md`、`TODO.md`、`LICENSE.md` |
| 根目录全仓规范、流程或技术参考 | `UPPER_SNAKE_CASE.md` | `BRANCH_MANAGEMENT.md`、`FILE_NAMING.md`、`LOGGING.md`、`RELEASING.md`、`TECHNICAL.md` |
| 功能目录 | 小写 `kebab-case` | `feature/first-run-onboarding/`、`feature/local-transcript-history/` |
| 功能目录入口 | 固定为 `README.md` | `feature/first-run-onboarding/README.md` |
| 功能级权威规范 | 固定角色名 `PRODUCT_SPEC.md`；功能作用域由目录提供 | `feature/first-run-onboarding/PRODUCT_SPEC.md` |
| 功能开发与测试补充 | 小写固定角色名 | `development.md`、`testing.md` |
| 功能平台附件 | `platform-<platform>.md`，平台标识使用小写 | `platform-macos.md`、`platform-windows.md` |
| `Testing/` 测试手册 | PascalCase，并包含可识别的功能或场景 | `FirstRunOnboarding.md`、`OnboardingConfigSummaryScreenshots.md` |
| `Bugs/` Bug 记录 | `YYYY-MM-DD-<scope-or-symptom>.md`，后半段使用小写 `kebab-case` | `2026-08-29-onboarding-voice-test-focus-and-diagnostics.md` |
| Shell 脚本 | 小写 `kebab-case.sh`，名称以动作开头 | `build-app.sh`、`verify-app.sh`、`prepare-preview-release.sh` |
| GitHub workflow | 小写 `kebab-case.yml` | `mac-ci.yml`、`mac-preview-publication.yml` |
| JSON Schema | 小写角色名加 `.schema.json` | `analysis.schema.json`、`result.schema.json` |

只有当目录不能准确提供作用域，或者同一目录中会出现多个同名角色时，才在文件名中增加领域名称。例如 `Testing/` 汇集全项目测试手册，因此必须使用 `FirstRunOnboarding.md`，不能使用含义不明的 `Onboarding.md` 或 `testing.md`。

## 源码与资源文件

- Swift 源文件继续遵循类型或主要职责的 PascalCase，例如 `OnboardingFlow.swift`、`AudioOutput.swift`。
- 新增内部技术文件名优先使用 ASCII，避免空格；大小写和分隔符遵循所在目录的既有类别。
- 面向用户直接分发、需要本地化辨识的资源可以使用中文文件名，例如现有安装说明；代码引用必须使用精确路径。
- 截图和静态资源使用稳定的英文 `kebab-case` 基名，并把平台、语言、外观或状态作为从通用到具体的后缀；不得依赖 Finder 显示名区分文件。
- 由系统、第三方工具、构建系统或公开协议规定的文件名保持其要求，不套用本规范强制改写。

## 多语言文件

- 当前中文主文档使用基础文件名，例如 `README.md`、`TECHNICAL.md`。
- 英文对应文件在扩展名前增加 `.en`，例如 `README.en.md`、`TECHNICAL.en.md`。
- 同一组文档的目录、基础名称和用途必须一致，语言代码不能放在目录名或文件名开头。
- 新增其他语言前必须先确定仓库统一的语言代码和回退规则，不能在不同目录混用不同格式。

## 名称选择流程

新增文件前依次确认：

1. 文件是否属于现有功能、测试、Bug、脚本、workflow 或根目录全仓规范。
2. 父目录是否已经完整表达功能或领域作用域。
3. 是否存在该类别的固定角色名或命名模式。
4. 完整相对路径是否能唯一、准确地说明内容，且没有重复作用域。
5. 名称是否会影响外部链接、构建脚本、Bundle、发布资产或系统约定。

如果仍无法归类，应先在本规范中补充类别或记录明确例外，再创建文件；不得在相邻目录中引入另一套大小写或分隔符风格。

## 重命名检查

重命名文件或目录时必须：

- 搜索并更新代码、Markdown、脚本、workflow 和配置中的全部仓库内引用。
- 检查大小写敏感与不敏感文件系统上的行为，避免只改变大小写导致 Git 漏记。
- 运行 Markdown 相对链接检查和 `git diff --check`。
- 检查是否触及公开 URL、发布资产、安装路径、Bundle、协议字段或其他兼容边界。
- 在 PR 中说明旧名称、目标名称、重命名原因和兼容性影响。

## 当前明确例外

- `design-qa.md` 是已有根目录历史名称；本规范不要求为了格式统一而重命名。
- `Resources/` 中已有中文说明文件属于用户直接阅读的本地化资源，不要求改为 ASCII。
- `Remote Mic`、`RemoteMic`、`Remote-Mic-*` 等历史兼容名称继续服从 `AGENTS.md` 的产品命名规范，不因文件命名统一而修改。
