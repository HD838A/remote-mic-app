# 固定遥控 UI 依赖的宿主协议编译失败

## 复现与日志

PR #554 初次 [macOS CI](https://github.com/HD838A/remote-mic-app/actions/runs/37033966932)
的免费组合动作、收费键位两组私有集成均在 Swift 编译阶段失败。
宿主为 `4d28efb5d371964bf299680ea1962aeedbbf1a48`，固定遥控镜像
为 `010c0baddb04461f090263c98ce42a77aafe5ccd`。

编译器在 `SettingsView.swift` 的 protocol conformance 报
`BridgeAppModel does not conform to WebRemoteSessionModel`，
指出缺少 `isWebRemoteMembershipBypassAvailable` 和
`setWebRemoteMembershipBypassEnabled`。这不是网络、Secret 或会员拒绝。

## 根因

新规范组件已移除独立免检开关的协议要求，但 CI/发布依赖仍固定到旧镜像。
宿主删除协议见证后，与旧镜像无法编译。此前“新 Remote 源码 + 原会员二进制”
通过并不能证明旧 Remote 镜像兼容。

## 最小修复

宿主保留只供旧协议 conformance 的两个接口：availability 恒为 false，
setter 是 no-op。旧 UI 也不显示开关；没有恢复独立状态、持久化或开关操作，
授权仍只依据当前服务环境。新组件不依赖这两个接口。

不更新发布依赖 pin、不修改 CI、不引入旧 VPS。正式生效仍需构建新 Remote、
统一会员私有构件及宿主；旧镜像的小程序取码规则仍为旧行为，不能作为新功能包交付。

## 验证与回滚

先更新现有回归断言，修复前两项断言失败；补接口后重跑相同断言及集成构建。
本地 `swift test --disable-keychain` 的同一过滤用例通过；公开全量
788 项 / 60 suites 通过。注入与固定 Commit 相同 tree 的旧 Remote
镜像后，`swift build --disable-keychain` 通过，全量测试 792 项 /
61 suites 通过。边界、治理及差异检查通过。新组件生产 UI 没有变化，
原始截图对应的 UI 字节仍适用；补充接口仅被旧协议消费。
最终 CI 状态记录在 PR #554，未通过前保持 Draft，不以重试旧 SHA 冒充修复。
没有数据迁移；回滚本项宿主提交可恢复原接口。
本记录只涉及编译合同，不证明真实微信扫码、音频或完整 App 验收。
