# 退出与跨端会员门禁

现象：退出仍可生成小程序连接码，staging 绕过会员，Phone/Watch 开启未受 Plus 限制。

源码确认：宿主 staging 自动传免检字段，Phone/Watch 共同服务启用入口无授权检查；Free API 创建预览会话、UI 暴露二维码。退出报价卡死根因与修复在私有会员仓库。

改动：公开宿主仅转发私有 Host Adapter 授权和统一会员视图，启动入口拒绝未授权；退出与环境切换停止现有连接并清码。私有 Remote UI 不展示会员不足二维码。

验证：见 Testing/CompanionMembership.md 与私有交付记录。线上扫码具体故障尚未日志确认，不能把此代码问题等同于该线上请求根因。
