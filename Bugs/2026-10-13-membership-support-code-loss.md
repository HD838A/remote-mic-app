# 会员会话错误详情丢失

## 证据与根因

基线 `e3ebb7bc`。公开宿主与私有 Host Adapter 均将服务错误映射为无详情枚举，因此数字 code 和请求 ID 无法到达宿主日志。私有记录包含 `support_code`，但最终发送过滤器缺少该字段，导致记录被拒绝。

## 修复

私有 Adapter 新增带详情的会话接口，并保留旧接口。公开宿主保留本地化错误分类，同时将脱敏 code 和请求 ID 写入本地日志及复制摘要。私有 Package 保留会话事件，并允许最终发送过滤器接受 `support_code`。

## 验证与边界

私有测试使用 HTTP 错误响应验证 `-1101`、`-1201` 和缺少 code 的旧响应。公开测试验证日志字段和复制摘要；非法字段使用稳定 fallback。两仓完整测试及构建结果见 PR。线上复现、Sentry 实际接收和安装升级未由这些测试证明。

## 2026-10-13 历史验证结果

- `swift test --disable-keychain`：公开构建 842 项、67 个套件通过。
- 同命令注入经过校验的私有构件及遥控器 Package：907 项、74 个套件通过。
- `scripts/test.sh`：48 项通过。
- 私有会员完整测试通过；双架构 XCFramework 构建、源码泄漏检查和运行检查通过。
- 打包初次发现 Xcode 覆盖率数据含绝对路径；使用仓库外的覆盖率关闭配置重新构建后通过，没有修改产品源码或降低检查。
- 治理、依赖固定、Markdown 相对链接和 `git diff --check` 通过。
- 私有依赖提交已 Push，对应 `GetSayAll/sayall-private-platform#191`。宿主 PR 合入前须先完成该依赖 PR 的评审。

## 2026-10-22 主线复核

- 基线：`0c3363a3edacec62186b94775882fbfc54368028`。保留主线的私有依赖版本 `2.2.7`，不恢复旧提交固定值。
- 公开 `swift test --disable-keychain -j 4`：928 项、73 个套件通过。独立自检 `scripts/test.sh`：48 项通过。
- 固定版本私有源码组合的宿主定向测试：63 项通过。该组合不启用会员二进制分支，不能替代该分支编译。
- 私有 `2.2.7` 会员包的 Host Adapter 与服务客户端定向测试：26 项 XCTest 和 8 项 Swift Testing 通过。均使用合成响应，没有请求生产服务。
- 补充控制字符和越界错误码测试。确认非法字段回退，不输出原始响应。
- 现有 `2.2.0` 二进制构件因缺少主线所需的 `RemoteMicBaseBindingSummary` 未通过集成编译。须使用当前版本的完整构件重跑，不能以旧构件或公开测试代替。
- 真实扫码失败、实际 Sentry 接收及安装升级仍未验收。候选保持 Draft。

## 2026-10-23：2.2.9 二进制宿主集成

- 用户指定使用私有 Swift Package `2.2.9`。从干净的 tag 提交 `d76f635ed6368d7f3d2021d2a6c187c54f5d19fa` 构建双架构 XCFramework，再通过 `SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH` 注入。仓库依赖清单仍固定 `2.2.7`，本次不升级清单。
- 私有四个 Package 的完整测试通过，保留 2 项既有跳过。双架构构建、消费端编译、资源归档、来源和摘要校验通过。
- 宿主验证提交：`6e7f13f03af373d6601865daf8e01f34b8a8dbf0`。`scripts/build-app.sh` 的 Apple Silicon Release App 构建通过。App 包含真实会员模块、诊断接口和资源，`codesign --verify --deep --strict` 通过。
- `swift test --disable-keychain -j 4 --scratch-path .build/pr649-private-2.2.9` 首次因测试包缺少私有资源 bundle 中断。将准备后的四个资源 bundle 复制到本地 XCTest 包的 `Contents/Resources`，再加 `--skip-build` 重跑：939 项 Swift Testing、74 个套件，以及 4 项 XCTest 全部通过。会员错误码、复制摘要和诊断上传测试通过。没有修改产品源码或测试断言。
- 最新主线 `807b71dba39fdab9e9a5d0c22c1cb5a403cc1f1e` 的新增改动不改变会员失败映射；`git merge-tree --write-tree HEAD origin/main` 无冲突。本次验证仍针对上述 PR 提交，不是合入后主线验证。
- 当前版本二进制的宿主集成编译阻挡已解除。App 仅用于本地编译验证，采用 ad-hoc 签名，未启动、未公证、未分发。真实扫码失败、Sentry 实际接收和安装升级仍未验收；PR 保持 Draft。
