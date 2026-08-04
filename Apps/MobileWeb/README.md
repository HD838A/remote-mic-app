# Remote Mic Mobile Web

Mobile Web 是无线麦的浏览器遥控入口。手机通过 HTTPS/WSS 加入一次性会话，Mac 用户明确允许后，网页才能发送白名单按键和按住说话音频。

当前目录包含：

- `protocol/`：Web 与 relay 共用的版本化消息定义；
- `web/`：React + Vite 手机单屏遥控器；
- `relay/`：只保存内存会话的 Node WebSocket 中继；
- `Dockerfile`：不包含真实域名或 VPS 信息的通用生产镜像；
- `PLAN.md`：完整实施和验收计划。

真实公网入口、VPS、SSH、DNS 和生产环境变量只保存在 Git 忽略的 `.private/` 或独立私有运维配置中。

## 本地开发

```sh
cd Apps/MobileWeb
npm install
npm run build
PUBLIC_ORIGIN=http://127.0.0.1:8787 PORT=8787 npm run dev
```

打开 `http://127.0.0.1:8787/healthz` 可以检查 relay。真实遥控会话需要 Mac 客户端创建二维码，不能从根页面绕过批准流程。

本地开发和测试不要求 Docker。`Dockerfile` 与 `docker-compose.example.yml` 只用于把生产部署封装为独立、可回滚的服务，避免在宿主机安装或维护全局 Node.js 运行环境。

## 验证

```sh
cd Apps/MobileWeb
npm run typecheck
npm run build
npm run test
```

自动化验证覆盖协议解析、一次性会话、批准前禁止转发、关闭清理、消息限流、PCM 音频帧和浏览器采样转换。真实发布前仍需使用实体 iPhone/Android 验证麦克风权限、前后台切换和实际语音听感。

## 隐私边界

- 公网通信使用 HTTPS/WSS；
- relay 不保存语音、按键或会话历史；
- 第一版属于传输加密，不应描述为服务器不可见的端到端加密；
- 页面切到后台、连接断开或松开语音键时立即停止麦克风。

本目录中的开源代码遵循仓库根目录许可证。Logo 和 App Icon 仍受仓库独立品牌许可约束。
