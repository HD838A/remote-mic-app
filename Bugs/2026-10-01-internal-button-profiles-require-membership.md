# 内部测试包的键位方案错误要求开通会员

- 时间：2026-10-01
- 状态：候选修复完成，自动化与源码 Package 集成验证通过；待最终 Developer ID 内测包人工验收
- 影响范围：包含键位方案但不包含会员服务的 macOS 内部测试构建
- 功能点：键位方案访问决策与构建审计标记

## 复现条件

使用 Build 229 同类内部配置构建：包含组合动作和键位方案，不提供可用会员服务。打开“键位方案”并尝试编辑或使用方案。

错误行为：页面把宿主的 `.unavailable` 访问决策当成会员门槛，要求先开通会员。正常行为是：仅限显式内部测试包，键位方案直接开放；公开、Preview 和 Stable 构建仍按正常会员决策或完全隐藏。

## 日志结论

该包未配置会员模块，宿主访问决策稳定为 `.unavailable`；键位方案 Package 正常存在且页面可见，因此不是资源缺失或加载失败。历史提交 `3db710dba59bf87ccbfd014b2d1576e382671c1c` 曾提供 `SAYALL_TEST_BUTTON_PROFILES_FREE=1`、编译条件和 `SayAllButtonProfilesTestAccess` 审计标记，但该提交未进入当前主线，拆分后的 `SayAllButtonProfiles` 集成也没有等价机制。

## 根因

当前 `MacroFeatureIntegration.updateButtonProfilesAccess` 无条件转发会员访问决策；源码键位方案包虽然可以独立注入，宿主没有受审计的内部覆盖入口。构建和验证脚本也没有标记或限制这种测试权限，无法保证它只进入不含会员的内部包。

## 修复

- 恢复显式环境变量 `SAYALL_TEST_BUTTON_PROFILES_FREE=1`，只为 `RemoteMic` 目标定义同名编译条件。
- 编译条件开启时，把键位方案访问决策固定为 `.allowed(validUntil: .distantFuture)`；未开启时保持现有会员语义。
- 免费测试模式必须使用组合动作和键位方案源码 Package，禁止统一私有构件，从构建入口排除会员实现与资源。
- App 写入 `SayAllButtonProfilesTestAccess` 标记；验证脚本检查该标记必须同时满足键位方案已包含、私有会员构件未包含、会员资源不存在。
- 使用独立 SwiftPM scratch flavor，避免与普通付费/会员构建复用旧产物。
- 发布控制面 fixture 显式清理该测试变量，避免调用方环境把内部测试权限带入普通发布缺依赖门禁。

## 验证

- 修复前新增 `internalButtonProfileTestAccessIsExplicitAndExcludesMembershipArtifacts`，在主线代码上按预期失败。
- 公开构建不设置测试变量，现有行为和测试保持不变。
- 使用本地 `macos-combination-actions` 与 `macos-button-profiles` 源码 Package，在开启测试变量后执行 `swift test --disable-keychain` 和 Release build。
- 使用 `scripts/build-app.sh` 生成内部 App，并以 `REQUIRE_SAYALL_BUTTON_PROFILES_TEST_ACCESS=1 scripts/verify-app.sh` 验证标记与资源边界。
- `git diff --check` 通过。

## 自动化与最终包边界

自动化可以证明访问决策编译分支、Package 依赖、Info.plist 标记和会员资源缺失。仍需在最终 Developer ID 签名、公证并 staple 的内测包中人工打开键位方案，确认无需登录或开通会员即可创建、切换和执行真实遥控器方案。
