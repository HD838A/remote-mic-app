# 安装器隐私政策同意

## 为什么开发

macOS 安装包会一次性安装 App、兼容麦克风和可选的 Siri Remote 组件，并要求管理员授权。安装前必须让用户看到与官网一致的隐私政策，并由用户明确选择同意或拒绝。此前 `Distribution` 没有许可步骤，用户可以在未阅读政策的情况下直接继续安装。

## 用户可见行为

- 安装器在“简介”之后插入系统许可页，展示当前语言的完整隐私政策。macOS 27 实测：许可页会弹出系统“同意/不同意”确认面板，点“同意”才能继续安装，点“不同意”取消安装并退出安装器；许可页底部另有“打印…/保存…/返回/继续”。按钮文案由系统 Installer 决定，本仓不能自定义。
- 许可正文跟随安装器语言提供简体中文和英文；其他系统语言目前预期回退英文，仍需人工确认。
- 正文顶部显示官网政策更新日期，末尾给出官网在线版本地址，便于用户核对当前版本。
- 许可正文是官网政策的逐字快照，不添加摘要、改写或额外法律语句；任何文字差异都会在发布前校验中失败。
- 官网政策已统一覆盖 Mac App、iPhone 与 Apple Watch 客户端、小程序和官网，并写明个人中心使用量统计的上传范围、用途与默认状态。

## 范围

- Apple Silicon 与 Intel 两个 `Distribution` 都引用同一份 `License.txt` 资源。
- 官网私有仓的中英文 `privacy.md` 是唯一可编辑源；`tools/sync-payment-policies.mjs` 校验两端源稿一致，`scripts/sync-legal-pages.mjs` 生成两站页面、`policy.json` 和 sitemap 日期。
- 本仓保存中英文许可快照与 `privacy-policy.lock.json`（正文 SHA-256、更新日期、政策 URL、同步来源提交）。
- 打包前校验快照与官网构建产物一致；发布签名前再次联网校验官网当前政策与本仓快照逐字一致。

## 非目标

- 不记录“谁在何时同意”，不新增账号、设备标识或同意回执上报。系统许可页只提供本地交互。
- `installer -pkg`、MDM 或其他命令行安装不会显示许可页，也不能作为用户已阅读政策的证据。
- 不改变 App 内“权限与隐私”、诊断、回眸或会员页面；不改变 `terms`、`refund` 页面。
- 不把私有官网源码、私有构件或未公开数据带入公开仓库；本仓只保存公开政策正文。

## 数据边界

许可页只读取安装包内的静态文本，不读取用户数据、不联网、不上传。政策正文本身是公开内容，不含个人信息、设备身份或凭据。

## 权威来源与同步

```text
sayall-private-platform/docs/product/policies/privacy.md        （中英唯一源）
  → tools/sync-payment-policies.mjs（校验源稿与小程序正文）
  → apps/official-sites/sayall-app/scripts/sync-legal-pages.mjs
  → getsayall-com + sayall-app 的 /privacy/、/en/privacy/ 与 sayall.app 的 /privacy/policy.json
  → 本仓 scripts/sync-installer-privacy-policy.py
  → Resources/{zh-Hans,en}.lproj/License.txt + privacy-policy.lock.json
  → Distribution <license file="License.txt"/>
```

不得手工编辑 `License.txt` 或许可页文案；只能通过同步脚本从官网产物更新，并在同一个 PR 中提交正文差异和锁文件。

## 验证边界

自动化已验证 `productbuild` 资源解析、展开包内的中英文许可文件、锁文件哈希和正文逐字比对；真实 Installer 的许可确认、语言切换和中止安装仍需按 [测试手册](../../Testing/InstallerPrivacyConsent.md) 在签名候选包上完成人工验收。
