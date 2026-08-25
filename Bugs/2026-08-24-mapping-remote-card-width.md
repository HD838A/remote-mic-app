# 按键页遥控器设备卡宽度小于其他模块

## 复现

- 环境：用户提供的“按键”页面浅色截图，已连接小米蓝牙遥控器 2 Pro。
- 操作：查看顶部“启用自定义按键功能 / 遥控器”分区，并比较蓝色设备卡与外层分区、下方关系图模块的横向边线。
- 实际结果：外层分区已铺满内容宽度，但设备卡从右侧控件列起点开始，左侧留下整列空白，且卡片还有 420pt 最大宽度上限；窗口越宽，相对其他模块越窄。
- 预期结果：启用开关继续使用普通设置行；遥控器设备卡属于整块业务内容，应位于“遥控器”块标题下方并占满分区可用宽度。

## 日志结论

检查截图时段，没有发现 SwiftUI、布局约束、资源加载或窗口错误。本问题是稳定的源码布局限制，不是运行时尺寸波动。

## 反馈循环

修复前结构门禁输出：

```text
FAIL: mapping remote card is still constrained to the trailing settings column
```

门禁要求映射页头包含独立的 `mappingRemoteDeviceBlock`：块内先显示遥控器标题，再让设备内容以无限最大宽度对齐分区左边线。

## 根因

映射页头把“遥控器”标签、`Spacer` 和设备选择器放在同一个普通设置 `HStack` 中，所以设备卡只能使用右侧控件列；设备选择器同时设置 `.frame(maxWidth: 420, alignment: .trailing)`，又人为限制了宽窗口下的最大宽度。设备卡内部已经支持 `fillsWidth: true`，但父级没有向它提供完整分区宽度。

## 修复

- 保留“启用自定义按键功能”的左标签/右开关设置行。
- 新增 `mappingRemoteDeviceBlock`，把“遥控器”作为块标题，并将设备内容放到下一行。
- 设备内容使用 `.frame(maxWidth: .infinity, alignment: .leading)`，移除父级 420pt 上限。
- 保留已连接过滤、卡片选择、连接状态、电池状态、重连操作和多遥控器纵向排列行为。
- 更新设置页回归测试，拒绝再次出现 420pt 映射页头限制。

## 验证

- 原结构门禁修复后输出：`PASS: mapping remote card owns the full section width below its label`。
- `swiftc -frontend -parse Sources/RemoteMic/SettingsView.swift Tests/RemoteMicTests/SettingsPageRegressionTests.swift`：通过。
- `git diff --check`：通过。

## 验证边界

Xcode 27 下 30 项设置页测试、342 项全量测试、成品构建与完整性检查通过；真实 App 已连接单遥控器状态及中文浅色/深色 `800 × 650`、浅色 `920 × 700` 初始化状态均保持设备块全宽。英文、多遥控器与无连接状态仍需真实环境验收。
