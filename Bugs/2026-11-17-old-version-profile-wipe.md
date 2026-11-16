# 旧版本打开新档案后清空苹果与 Chromecast 设备

- 时间：2026-11-17
- 状态：候选修复
- 影响范围：官方 2.0.6 Pre-release 之前的升级窗口；所有会在新版本写入后再次启动旧版本的安装
- 用户现象：2.0.6 中“连接过的设备”没有苹果遥控器；用户记得此前连接过两台苹果遥控器，至少应保留一台

## 现场证据

- 运行中的官方包：`/Applications/SayAll.app`，2.0.6 Build 325，`SayAllBuildChannel=release`，`SayAllPrivateArtifactsIncluded=true`，来源 `174b4dc4`。
- 当前偏好 `remoteDeviceProfiles` 只有两条小米档案：`rc003`、`rc001`。
- 同一偏好里的 `buttonInteractionMigrationBackup` 保存了 6 条旧档案：两条苹果 A2854、一条苹果 A2540、一条 Chromecast，以及两条旧的小米档案。
- `~/Library/Logs/RemoteMic/runtime.log` 显示 2026-11-16T18:06:05Z 启动了 `ver=1.9.21 build=174` 的旧 App（pid 15175）；官方 2.0.6 于 18:13Z 才发布。
- 1.9.21 的 `XiaomiRemoteModel` 只有 `rc001`、`rc003`、`unknown` 三种值。
- 1.9.21 的 `AppSettings` 使用 `try? JSONDecoder().decode([RemoteDeviceProfile].self, ...)`；解码失败时执行 `remoteDeviceProfiles = [migrated]`，而该属性的 `didSet` 立即写回偏好。

## 根因

1. 2.0.6 已写入苹果和 Chromecast 型号，以及旧版本不认识的动作值。
2. 旧版本 1.9.21 启动时无法解码整组档案。
3. 旧版本把整组档案替换为一条 legacy 档案，并立即持久化。
4. 2.0.6 随后启动时只看到剩余的小米档案，苹果和 Chromecast 卡片的来源数据已经不在活动键里。

这不是“苹果遥控器没有配对”，也不是公开测试包缺少私有组件。官方 2.0.6 包含私有组件；丢失发生在旧版本写入阶段。

## 本机恢复

- 当前偏好先备份到 `~/Library/Application Support/SayAllRecovery/`。
- 从 `buttonInteractionMigrationBackup` 取回苹果 A2540、苹果 A2854 和 Chromecast 档案，与当前两条小米档案合并。
- 两条 A2854 是同一台遥控器的重复指纹记录；保留一条，避免重复卡片。
- 恢复后活动键包含 5 条档案；2.0.6 实际窗口显示小米 2、小米 2 Pro、苹果 Lightning、苹果 Type-C，苹果画布正常。
- 完整备份和原始迁移备份均保留，未删除。

## 代码修复

- `AppSettings` 在加载存储档案期间禁止写回，避免构造阶段的 fallback 覆盖原始数据。
- 已存在 `remoteDeviceProfiles` 但解码失败时，不再用一条 fallback 档案覆盖活动键。
- 首次后续保存前，把无法解码的原始字节写入 `remoteDeviceProfilesUnreadableBackup`；恢复快照与解码失败分别写脱敏日志。
- 新增回归：无法解码的档案在初始化后保持原始字节；后续注册新设备前先写入恢复快照。
- 按键页顶部选择器保留所有私有遥控器（苹果与 Chromecast），不再只在 Chromecast 已连接时显示。连接页选中离线 Chromecast 后，顶部仍能看到并自动滚入视野。

## 按键页选择器遗漏 Chromecast

修复前的过滤条件：

```swift
model.isRemoteConnected(profile.id) || (!vertical && profile.model.isAppleSiriRemote)
```

Chromecast 档案离线时被排除，连接页能看到，按键页顶部看不到。修复后使用 `profile.model.usesPrivateAdapter`，苹果与 Chromecast 都保留；已连接的小米仍按连接状态显示。测试手册补充“连接页选中离线 Chromecast 后进入按键映射”的用例。

## 边界

- 已安装的 1.9.21 二进制无法回改；再次运行旧版本仍可能清空新数据。2.0.6 安装包已替换旧 App，用户不应再打开旧副本。
- 本修复保护 2.0.6 及后续版本在遇到未知型号、未知动作或其它解码失败时不再静默覆盖。
- 恢复操作只使用本机 `com.hd838a.RemoteMic` 偏好和迁移备份，不读取其他 App 数据。
- 未验证旧版本再次运行后的行为；这不属于当前可修改的二进制范围。

## 验证

- 待执行：定向档案持久化测试、公开全量测试、公开构建、仓库治理检查。
- 真实边界：恢复后的卡片已在 2.0.6 生产窗口确认；旧版本再次运行的破坏行为不可由当前版本修复。
