# 键位方案开发记录

## 实现位置

- 私有模块 `RemoteMicButtonProfiles.swift`：格式 2 模型、版本 1 迁移和前台 App 监听。
- 私有模块 `RemoteMicMacroController.swift`：方案管理、当前选择、App 规则、持久化和运行时解析。
- 私有模块 `RemoteMicButtonProfilesView.swift`：方案列表、遥控器绑定、手动/自动模式和 App 规则页面。
- 私有模块 `RemoteMicMacroView.swift`：组合动作与键位方案的并列分段入口。
- 公开宿主无业务代码改动，继续复用 `MacroFeatureIntegration` 的可选窄接口。

## 兼容策略

旧格式只在成功解码后迁移。写入格式 2 前保留 `button-bindings-v1-backup.json`，迁移后的方案直接物化最终绑定，不在每次按键时叠加旧通用与精确配置。

删除非默认方案前保存快照；删除被 App 规则或当前选择引用的方案后，规则被移除并按当前模式安全回退。组合动作保存新版本或删除时同步更新所有方案中的引用。

## 验证结论

私有模块自动化覆盖迁移、方案 CRUD、手动/自动切换、多遥控器隔离、重启恢复、删除回退、组合动作版本同步、功能访问关闭和页面结构约束。真实 App 和真实硬件边界见测试手册。
