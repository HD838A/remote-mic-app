# 私有遥控包固定提交导致会员连接 CI 编译失败

## 复现与日志

Mac 宿主 PR #566 的 macOS CI run `37140537589`，两项私有组合均失败。日志显示 `WebRemoteSessionState` 缺少 `membershipRequired`，`WebRemoteSessionView` 不接受 `membershipRequiredView`。公开构建使用当前兼容模块，私有构建使用固定的旧镜像，因此不能用公开构建通过代替私有组合通过。

## 根因与修复

`config/release-dependencies.json` 的遥控包固定提交早于会员入口合同更新。业务事实源在私有 Monorepo；先从已提交的 Package 同步兼容分发镜像，再更新宿主固定提交。没有在镜像独立开发，也没有删掉宿主对新合同的调用。

## 验证与边界

- 新镜像47项测试、Intel macOS13 Release构建通过。
- 宿主使用新镜像与私有方案源码，798项 Swift Testing测试、63 suites通过。
- release依赖检查通过；CI完整双架构结果另行记录。
- 此修复不改变界面；既有UI截图、完整Onboarding和真机会员支付门禁继续保留。
