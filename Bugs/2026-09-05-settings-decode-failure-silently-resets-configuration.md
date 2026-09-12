# 配置解码失败被静默重置（用户配置无声丢失且无线索）

- 时间：2026-09-05
- 状态：已修复，自动化通过；真机未验收
- 影响范围：任何一次配置数据损坏（版本不兼容、截断写入、磁盘错误）的用户
- 功能点：`AppSettings` 的 10 处持久化加载点 + 按键映射页
- 简单描述：10 处加载点写作 `try? JSONDecoder().decode(...)`，把「该键从未保存过」与「数据存在但解码失败」合并进同一个 else。前者用默认值正确，后者是故障：用户的全部按键映射与自定义动作被无声换回默认值，没有日志、没有界面提示、原始字节也没有备份，无从排查。

## 根因

`AppSettings.init` 的持久化加载点全部形如：

```swift
if
    let data = defaults.data(forKey: Keys.buttonBindings),
    let decoded = try? JSONDecoder().decode([String: ButtonAction].self, from: data)
{ ... } else {
    buttonBindings = Self.defaultBindings
}
```

`try?` 把「没数据」与「数据损坏」折叠成同一个 nil。损坏时用户不仅被换回默认，而且：(1) 没有任何日志记录这次失败；(2) 原始字节随即可能被新写入覆盖，证据与可恢复性一起消失；(3) 界面无任何提示，用户只能发现自己设置「没了」。

`remoteDeviceProfiles` 一处更特殊：该属性在加载前已预初始化为 `[]`，迁移分支的赋值在同一次 `init` 内触发 `didSet` 持久化，**首次启动就覆盖损坏字节**——连事后取证的机会都没有。

## 修复

- 新增 `static decodeSetting(_:forKey:from:corrupted:)`：无数据静默走默认值（行为不变）；解码抛错则 (a) 记日志（键名、字节数、DecodingError）；(b) 把原始字节另存到 `<键>.corrupt`（永不覆盖原键，保留可恢复性）；(c) 键名累加进 `@Published corruptedSettingKeys`。10 处全部切换，每处原有默认值语义逐一核对未变，含 `remoteDeviceProfiles` 的 `!decoded.isEmpty` 守卫与旧版迁移分支。helper 为 `static` 且用 `inout` 累加，因为调用点在 `init` 内、实例尚未完全初始化。
- `firstUseEvents`（计算属性 getter）：同样记日志并备份字节，但**故意不上报** `corruptedSettingKeys`——getter 可重复调用会重复追加，且引导遥测不是用户配置、不该触发配置丢失告警。
- 按键映射页顶部新增内联提示横幅：列出受影响项（存储键按用户可识别的设置归类、去重、固定顺序）、说明原始数据仍保留、以及重新设置一次即可。判定与文案组装抽为纯函数 `CorruptedSettingsNotice` 以便测试；健康启动时横幅完全不存在，不占布局。内联面板而非弹窗（弹窗看一次就消失）；字号全部显式 ≥12pt（`.caption` 实为 10pt）。
- 选按键映射页因为 10 个可损坏键里 6 个是映射数据且它是侧边栏首项。

## 定位

防御性加固，不是已发生故障的修复——无证据表明已有用户命中解码失败。

## 验证

自动化（15 项新测试）：

- `SettingsCorruptionRecoveryTests`（7 项）：真实不可解码字节驱动真实 `AppSettings(defaults:)` 加载——回退默认值、上报损坏键、`.corrupt` 备份逐字节一致、原键不被覆盖、多键各报一次、首次运行不误报、有效配置重载零上报、firstUseEvents 重复读不累积；
- `CorruptedSettingsNoticeTests`（7 项）：归类折叠、固定顺序、未登记键仍走通用项告警（防止未来新键静默）、真实损坏加载端到端归类、双语言真实串表渲染整句；
- `SettingsPageRegressionTests`（1 项）：横幅内联（禁 popover/sheet/alert）、禁 10/11pt 语义字号、所有显式字号 ≥12、挂在 mappingPage 上。

`swift test` 全量通过；`scripts/test.sh`、`scripts/check-repository-boundaries.sh` 通过；两份 `Localizable.strings` 键集合对齐。

未覆盖：真实用户损坏现场的恢复演练（`.corrupt` 字节人工还原流程）。
