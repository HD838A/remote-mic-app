# 设置页重构遗留死代码与统计页缩放系数

## 复现

- 环境:源码审查;`dist/SayAll.app` 调试构建。
- 操作:全仓搜索 `StatusPill`、`DeviceStatusStep`、`connectionBadge`、`voiceTriggerBadge` 的引用;查看统计页指标卡数值。
- 实际结果:四个声明除互相引用外零使用,是原生设置重构前的自绘状态胶囊/步骤卡遗留;统计页 `UsageStatisticCard` 数值用硬编码 21pt 加 `.minimumScaleFactor(0.75)`,与设计规范「优先截断/布局而非缩放」相悖。
- 预期结果:死代码删除并有防回归门禁;数值使用语义字号,不再缩放。

## 日志结论

纯源码卫生问题,无运行日志。

## 根因

- 重构替换自绘组件后未删除旧声明;指标卡为兼容超长数值使用了缩放系数。

## 修复

- 删除 `StatusPill`、`DeviceStatusStep`、`connectionBadge`、`voiceTriggerBadge`;回归测试中 `permissionRow` 区间边界标记从 `connectionBadge` 改为下一个现存声明 `webRemoteStatusText`,并新增四条「声明不再出现」门禁。
- 数值字号改 `.system(.title2, design: .rounded).weight(.semibold)`,移除 `.minimumScaleFactor(0.75)`,保留单行截断。

## 验证

- 修复前:四个声明存在且仅被死代码互相引用;`.minimumScaleFactor(0.75)` 存在。
- 修复后结构门禁全部通过;31 项定向测试、344 项全量测试、成品构建与完整性校验通过;统计页三种外观/语言 `800 × 650` 离屏渲染正常。

## 验证边界

超长数值(如多日累计时长)在真实数据下的截断表现按测试手册人工复核。
