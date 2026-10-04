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

## 2026-10-05 合入前同步

最新主线已停用遥控分发镜像。冲突解决保留主线的私有 Monorepo 结构，并将其固定到已合入 #107 的 `527e16ed0e12701a0fc22de945052e160c4c7e62`。没有恢复旧镜像。公开构建 819 项测试通过；当前遥控源码与既有私有构件的设置和向导 120 项测试通过。截图入口补充会员语言同步，使其与正式 App 的语言观察一致。截图只证明静态界面；当前提交的真机支付及完整发布包仍需另行验收。
