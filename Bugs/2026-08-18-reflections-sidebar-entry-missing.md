# 回眸页面缺少侧边栏入口

- 时间：2026-08-18
- 状态：已修复，等待 `800 × 650` 组合页面人工验收
- 影响范围：准备中的 macOS 1.9.0 本地回眸功能
- 功能点：设置侧边栏与本地语音转写记录

## 复现

在合入回眸与 MCP 的总集成基线 `d6f7dba5` 上检查生产 `SettingsView`：

```sh
git show HEAD:Sources/RemoteMic/SettingsView.swift \
  | sed -n '/private static let sidebarSectionOrder/,/^    ]/p'
```

结果包含 `.mapping`、`.macros`、`.statistics`、`.connection`、`.privateFeature`、`.permissions` 和 `.about`，但没有 `.transcripts`。`visibleSections` 只过滤并渲染该顺序数组，因此即使 `SettingsSection.transcripts` 和 `transcriptHistoryPage` 已存在，用户也无法从侧边栏进入“回眸”。

原 `SettingsPageRegressionTests.sidebarUsesExplicitProductOrder` 只断言旧页面顺序，没有要求 `.transcripts`，所以测试错误地通过。

## 日志检查

这是由静态页面枚举决定的确定性导航缺陷，进入页面前没有用户事件，也没有对应运行时错误日志。源码中的 `sidebarSectionOrder → visibleSections → ForEach` 已足以确认入口不可达；没有把缺少日志写成运行时正常。

## 根因

回眸提交增加了页面枚举、页面内容和静态页面测试，但没有把 `.transcripts` 加入唯一的侧边栏产品顺序数组；原顺序测试也沿用了功能加入前的期望列表，未覆盖新增页面可达性。

## 修复

- 只在 `.statistics` 后加入 `.transcripts`，保持其他侧边栏顺序不变。
- 更新现有顺序回归，明确要求 `.mapping → .macros → .statistics → .transcripts → .connection → .permissions → .about`。
- 不改变回眸页面布局、Feature Flag、记录开关、MCP、AI、组合动作或其他侧边栏入口。

## 验证

- 修复前使用上述只读命令稳定复现 `.transcripts` 缺失。
- `swift test --filter 'OnboardingFlowTests|PreferredInputSourceMonitorTests|TranscriptArchiveStoreTests|TranscriptCaptureCoordinatorTests|SayAllMCPAuditLogTests|SayAllMCPAuthorizationStoreTests|SayAllMCPHistoryStoreTests|SayAllMCPIntegrationConfigTests|MCPClientIntegrationServiceTests|AppSharingTests|FeedbackLinkTests|SettingsPageRegressionTests|BuildSigningTests|LocalizationTests'`：114 项、14 个 suite 全部通过；其中顺序回归已明确覆盖 `.statistics → .transcripts → .connection`。
- `scripts/verify-release-dependency-pins.sh`：通过，AI、组合动作和 MacRemote 三项依赖在 CI、预览与签名发布 workflow 中保持一致。
- `git diff --check`：通过。
- `800 × 650` 全侧边栏点击与真实语音历史仍属于后续组合人工门禁，不能由源码顺序测试代替。
