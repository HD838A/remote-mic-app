# Codex 切换框第 6～9 项显示占位名称

- 时间：2026-08-29
- 状态：已修复；真实 Codex 数据读取和单页 9 项界面已在候选中经用户验收，修复已整理为面向原作者 main 的 PR
- 影响范围：ChatGPT/Codex 切换框

## 复现条件与边界

1. Codex 侧边栏的对话行显示 `Command + 1`～`Command + 9`。
2. 在 SayAll 中触发“ChatGPT 项目切换”并进入第二页。

错误行为：第二页显示 `项目6`～`项目9` 占位文字，而不是 Codex 侧边栏相同快捷键对应的对话标题。

正常行为：SayAll 的 1～9 项标题和顺序逐项等于 Codex 侧边栏 `Command + 1`～`Command + 9` 的对话行；选择后仍发送相同的数字快捷键。

## 日志与现场证据

- 第一版候选的现场日志为 `source=codex_state resolved=4 accessibility=0 persisted=4`，选择框显示 9 项只是补位。
- 用户第二张截图证明快捷键附着在项目文件夹下的对话行和 Recents 对话行上，不附着在项目文件夹名称上。
- `.codex-global-state.json` 的 `project-order` 只有 4 个项目文件夹，但 `thread-project-assignments`、项目展开状态和 `projectless-thread-ids` 描述了侧边栏分组。
- `state_5.sqlite` 的 `threads` 表保存对话 `name/title`、可见性和最近活动顺序。

## 根因

第一版候选把“项目文件夹名称”误当成 `Command + 数字` 对应的名称，只读取 `local-projects/project-order`。这最多返回 4 个文件夹名，无法产生截图中的 9 个对话标题。

## 修复

- 从全局状态读取项目顺序、项目展开状态、线程到项目的分配和项目外线程集合。
- 从线程数据库只读取得 `id`、`name/title`、归档状态、预览是否存在和 `recency_at_ms`；SQL 只判断预览非空，不读取预览正文。
- 按项目顺序遍历已展开项目，每个项目内按最近活动降序，再接项目外 Recents；标题优先使用用户命名的 `name`，否则使用生成的 `title`，最多取 9 项。
- 内部状态读取成功时不再补 `项目6`～`项目9`；数据不可读时才回退到原 Accessibility 方案。
- 9 条记录全部传给同一个列表，移除分页状态和页码；面板高度按 9 行计算，避免末项裁切。
- 日志只记录来源和数量，不记录对话标题、线程 ID、项目 ID、路径或正文。

## 验证

- 纯函数测试覆盖项目顺序、项目内最近顺序、用户命名优先、Recents、折叠项目、归档线程和无预览线程。
- 直接编译生产 `CodexProjectPicker.swift`，对当前真实状态执行聚焦测试，返回的 9 条标题与用户截图逐项一致：`CODEX SIDEBAR SHORTCUT TITLES PASS count=9`。
- SwiftPM 生产构建通过；完整 Swift Testing 目标仍受本机 CommandLineTools 缺少 `Testing` 模块阻断。
- Apple Silicon Release 构建、`verify-app.sh` 全项、深度签名、SQLite 动态链接、安装后二进制一致性和启动均通过。
- 第二版候选已安装到 `/Applications/SayAll.app`，版本 `1.9.16 (137)`；上一候选备份在 `/Users/mac/Documents/ChatGPT/SayAll/.backups/SayAll.app.before-thread-title-fix-20260829-011645`。
- 安装后真实触发日志为 `source=codex_state resolved=9 accessibility=0 persisted=9` 和 `shown items=9`，证明运行中的 App 已从新数据源取得 9 条标题，而不是用占位补齐。
- 此前单页候选的 Debug 与 Release 构建通过，候选包和安装包的资源、深度签名、版本及二进制一致性校验通过，并已启动 `/Applications/SayAll.app`。
- 替换前的可用版本备份在 `/Users/mac/Documents/ChatGPT/SayAll/.backups/SayAll.app.before-single-page-20260829-012432`。
- 面向原作者 `origin/main` 的精简 PR worktree 已重新完成生产构建；只保留项目切换动作、状态读取、单页列表、SQLite 链接、测试与权限登记，不带入其他定制功能。

## 验证边界

生产读取器已经用当前真实 Codex 数据证明能生成截图中的 9 条标题，安装后运行日志也证明读取到 9 项。用户随后确认安装候选测试成功：9 条真实标题可以在同一页完整显示，原始“只能读取 5 个名称”和第二页占位问题均不再复现。精简 PR 分支已在最新 `origin/main` 上重新构建通过，但尚未再次安装。

完整 Swift Testing 目标仍受本机 CommandLineTools 缺少 `Testing` 模块阻断；这不影响本次已完成的生产构建、真实状态读取、安装包验证、运行时日志和用户可见界面验收，但后续开发环境恢复后仍应补跑完整测试集。

## 修复经验

1. **先确认快捷键绑定的语义实体。** 界面名称写着“项目切换”不代表数字快捷键绑定的是项目文件夹。本次截图证明 `Command + 1`～`Command + 9` 实际绑定项目内对话和 Recents 对话；如果只按功能名称猜数据模型，会在错误层级上得到稳定但错误的结果。
2. **Accessibility 的可见结果不等于完整排序。** AX 只能稳定取得当前已暴露的部分行，无法还原全部 9 项时，应明确区分“没有数据”和“数据不完整”，不能用 `项目6`～`项目9` 占位伪装成读取成功。
3. **还原侧边栏必须组合状态与数据库。** 全局状态负责项目顺序、展开状态、线程归属和 Recents 集合，线程数据库负责标题、归档、预览存在性与最近活动时间；任何单一来源都不足以还原数字快捷键顺序。
4. **内部状态访问必须最小化且可降级。** 只读已登记字段，SQL 只判断预览是否存在，不提取正文；日志只保留来源和数量。文件缺失、格式变化或解析失败时回退到 AX，不让第三方私有格式变化阻断原有功能。
5. **权威数据可用后应删除历史补偿结构。** 原来的两页设计是“只能取得 5 条”的限制产物。确认可以稳定读取 9 条后，继续保留分页只会增加状态和操作成本，因此直接移除分页、页码和切页逻辑，并按实际行数计算面板高度。
6. **验证要覆盖数据、运行包和用户界面三层。** 纯函数测试验证排序规则，真实 Codex 状态验证 9 条标题，安装后日志验证运行中的 App 确实走新数据源，最终由用户确认单页完整显示；只通过其中任意一层都不能代表问题已解决。
