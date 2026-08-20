# Resend 邮件工作交接

> 交接日期：2026-08-21

> 范围：仅处理 Resend 邮件服务，不处理 Cloudflare D1、Worker、Access、活动配置或其他客户端。

## 已确认信息

- 邮件服务商：Resend
- Resend 登录方式：GitHub 账号 `hd838a`
- 发件域名：`sayall.app`
- 发件地址：`redeem@sayall.app`
- Staff Worker 目标域名：`redeem.sayall.app`
- 活动一：`mks-260821-plus-3`，Plus，90 天
- 活动二：`mks-260821-12`，Plus，365 天
- 真实验收邮箱：已由用户在当前会话提供；不在公开仓库中重复记录
- Access 允许邮箱：已由用户在当前会话提供；不在公开仓库中重复记录

## 当前状态

- 已打开 Resend GitHub 登录入口。
- GitHub 页面要求登录 `hd838a` 并授权 Resend。
- 当前浏览器没有可复用的 GitHub 登录会话。
- 用户尚未完成 GitHub 登录和 Resend 授权。
- 尚未添加或验证 `sayall.app` 域名。
- 尚未创建 Resend API Key。
- 没有任何 API Key、密码、验证码或 Secret 写入仓库、日志或聊天交接内容。

## 下一步

1. 在浏览器打开 <https://resend.com/login>。
2. 选择 GitHub 登录，使用 `hd838a` 完成登录和授权。
3. 在 Resend 控制台添加 `sayall.app`。
4. 读取 Resend 生成的 SPF、DKIM 等 DNS 记录；DNS 配置由负责 Cloudflare 的其他会话处理。
5. 等待 Resend 显示域名验证成功。
6. 创建仅用于发送邮件的 API Key，建议命名为 `sayall-membership-staging`。
7. 不要把 API Key 粘贴到聊天或 Git；通过安全的 `wrangler secret put EMAIL_PROVIDER_API_KEY` 流程写入目标环境。
8. 使用 `redeem@sayall.app` 发送一次登录验证码邮件和一次活动兑换码邮件。
9. 只记录送信结果、Outbox ID、Provider message ID 和 request ID，不记录验证码、兑换码或邮件正文。

## 当前阻塞

- 阻塞点是 GitHub 登录/Resend OAuth 授权，需要用户在浏览器中完成。
- 如果 Resend 要求邮箱验证、组织授权或账单设置，先停下并让用户确认，不要绕过验证。
- API Key 创建属于持久化访问凭据操作，创建前应确认目标环境和权限范围；Key 创建后不得在聊天中展示。

## 非目标

- 不在本交接中创建 Cloudflare D1。
- 不运行 Membership migration。
- 不部署或修改 Worker、Access、DNS。
- 不执行真实活动发码。
- 不修改 Mac、iOS、Watch、Web 或 Relay。
