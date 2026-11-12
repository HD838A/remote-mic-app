# 组合动作改名后，键位方案页仍显示旧名字

## 复现

1. 在组合动作页把已保存的动作改名（改名字会保存并生成新版本）。
2. 回到键位方案页：该按键仍显示改名前的名字；若是最近新建的动作，显示
   「原操作已不可用，请重新配置。」。
3. 同一个动作在按键映射页显示正常，按下按键执行也正常。
4. 完全退出并重开 App 后，键位方案页恢复正确名字。

## 根因

组合动作组件和键位方案组件各持一份 `MacroLibraryStore` 实例，互不通知。

- 组合动作组件改名后 `await reload()`，刷新的是自己那份宏库快照。
- 键位方案组件的宏库快照只在启动时和可移植导入提交后刷新，
  `RemoteMicBindingText.bindingText(for:)` 用这份快照解析 `.macro` 的名字，
  于是组合动作改名后键位方案页一直显示旧名字。

按键映射页在 [`2026-11-12-mapping-profile-macro-name.md`](2026-11-12-mapping-profile-macro-name.md)
里已经修好：方案作用域的组合动作名改从组合动作组件的 `libraryActions` 现取。
键位方案页由按键方案组件自己渲染，绕不开，只能让组件自己拿到最新宏库。

## 分工

- 组件侧（私有仓 `GetSayAll/sayall-private-platform`）：宏库落盘后广播变化通知，
  键位方案组件收到就重读宏库快照；同时提供 `reloadMacroLibrary()` 入口。
- 宿主侧（本仓库）：在进入按键页和键位方案页时调用该入口，覆盖跨进程写入的场景。

## 本次修改（宿主侧）

- `Package.swift` 新增能力探测 `SAYALL_BUTTON_PROFILE_MACRO_RELOAD`：
  按键方案组件提供 `reloadMacroLibrary()` 时才定义，旧私有包仍可编译。
- `MacroFeatureIntegration.reloadButtonProfileMacroLibrary()`：转发到组件的
  「只重读宏库」入口，不重读方案文档。
- `ButtonProfileMacroRefreshPolicy`：进入按键页（`.mapping`）和键位方案页
  （`.buttonProfiles`）时重读一次；其他页面不重读。
- `SettingsView` 在首次出现和切换页签时按上面的策略调用。

## 验证

- 新增 `ButtonProfileMacroRefreshPolicyTests` 3 例：按键页要重读、键位方案页要重读、
  其他页面不重读。
- `swift build --disable-keychain` 通过；`swift test --disable-keychain` 1387 项通过。
- 缺私有组件时（`SAYALL_PRIVATE_PLATFORM_MODE=public`）仍走公开兼容层，不报错。
- 未验证：实体遥控器复测、跨进程写库后的端到端复测、正式 Developer ID 签名包。

## 遗留

- 组件侧的宏库变化通知与「只重读宏库」入口在私有仓，本仓库要等私有平台版本
  升级后才会在正式包里生效；本 PR 的能力探测保证旧版本下行为不变。
- 宿主侧只覆盖「进入页面时重读」。停留在按键页时另一进程改名的场景，要等组件侧
  的通知机制在同进程内生效；跨进程仍需重新进入页面。

### 代码评审记录的后续项

宿主侧这轮评审还有三条不阻塞合入的整洁性问题：

- `reloadButtonProfileMacroLibrary()` 是 fire-and-forget 的 `Task { }`，没有并发去重。
  快速来回切页签会并发发起多次全量宏库读，每次都要抢全局存储锁。可以加一个
  「正在刷新」的闸门。
- `.onAppear`（按 `selectedSection` 判断）与 `.onChange(of: selectedSection)` 两个入口
  都会触发刷新，首次进入按键页可能连读两次宏库。多余磁盘读，不是错误。
- 旧私有包下 `shouldRefresh` 仍返回 `true`，每次进页面都会调一次空实现。
  可以把调用点也放进 `#if canImport(SayAllButtonProfiles) && SAYALL_BUTTON_PROFILE_MACRO_RELOAD`。
