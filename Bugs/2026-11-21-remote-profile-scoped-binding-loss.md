# 档案去重后设备级绑定失效

## 证据与根因

在隔离 UserDefaults 写入同一物理设备的两条 2.0.8 形式档案，将独立基础绑定保存到未选中的档案。旧代码先删除该档案，再加载按档案 ID 索引的绑定。测试确认原始绑定仍在、运行时完全不命中，恢复去重前的档案后恢复执行。暂无真实升级现场日志。

## 修复与验证

宿主在去重前加载独立绑定。优先保留唯一有引用的档案，存在冲突、双方都有引用或绑定无法读取时保留原记录。完整构建在私有配置读取结果未确认时保留可能被引用的档案，并通过已有公开 API 查询绑定引用。运行 `SAYALL_PRIVATE_PLATFORM_MODE=public swift test --disable-keychain --filter 'RemoteProfilePersistenceTests|CompleteConfigurationBackupTests'`。自动化覆盖原绑定持续执行与重启，官方私有构建及两版真实升级待验收。
