# 小程序连接码超时（-1101）

日期：2026-10-11

## 现象

App 2.0.0 取小程序连接码失败。用户界面显示“小程序码暂时无法加载”。现场加密日志记录 4 次超时，耗时分别约为 8.0 秒、8.0 秒、8.0 秒和 9.4 秒，最终支持码为 `-1101`。

## 证据

- 现场加密日志中的 Mac 取码请求在约 8.0 至 9.4 秒后超时；当时客户端使用 8 秒预算。
- 修复后的 Mac 取码请求和 Relay 调用 ECS 网关均使用 30 秒预算。
- ECS 网关在缓存未命中时先请求微信 `stable_token`，最多等待 5 秒，再请求微信小程序码，最多等待 8 秒。
- 原来的 ECS 冷路径最大预算约为 13 秒，超过旧 Mac 的 8 秒和旧 Relay 的 10 秒。
- 使用合成有效请求探测生产网关时，缓存命中路径约 2.2 秒成功。该结果与“缓存命中正常、冷路径或外部响应慢时超时”的证据一致。
- 现场日志没有保存服务端阶段、HTTP 状态或请求关联号。无法从旧日志进一步区分当时是微信取 token 慢还是取码慢。

根因是端到端超时预算不一致。Mac 在服务端完成冷启动路径前已经停止等待。`-1101` 表示客户端请求超时，不表示会员初始化失败。

## 修复

私有平台包：

- Mac 及其他宿主网络请求统一使用 30 秒超时。
- Relay、微信 token 和小程序码请求统一使用 30 秒超时，覆盖冷路径并保留网络开销。
- Mac 本地加密日志增加请求开始、token 缓存命中/未命中、响应 HTTP 状态、响应类型、响应字节数、实际耗时、超时、网络错误和稳定支持码。
- 服务端日志增加短生命周期请求号、阶段、环境版本、HTTP 状态、响应字节数、耗时和稳定失败分类。日志不记录 token、scene、响应正文或用户身份。
- 小程序取码错误码固定为 `-1100` 至 `-1107`。本次超时为 `-1101`。

## 验证

- `swift test --disable-keychain --package-path packages/macos-remote --filter WebRemoteMiniProgramCodeTests`：13 项通过。
- 私有包 `npm run typecheck:wechat-gateway`：通过。
- 私有包 `npm run test:wechat-gateway`：8 项通过。
- 私有包 `npm run build:wechat-gateway`：通过。
- 私有包 `npm run typecheck:cloudflare-relay`：通过。
- 私有包 `npm run test:cloudflare-relay`：18 项通过。
- 私有包 `npm run build:cloudflare-relay`：通过。

本次只完成源码和自动化验证。没有发布生产 ECS 或 Relay。发布后仍需用真实 Plus 账号和真实微信扫码验证冷启动、缓存命中、超时提示和日志关联。
