# Apple Silicon 方向键原生事件泄漏到前台 App

## 现象与证据

用户把遥控器上、下、左、右映射为鼠标移动后，在 Codex 中按住上键时：

- 鼠标按预期向上移动；
- Codex 输入框光标同时按上键移动；
- Codex 的上键快捷键也被触发。

现场为 Apple Silicon、公开模式本地测试包 build 451。运行日志：

```text
HID CONNECTED mode=monitored seize_error_domain=io_return seize_error_code=-536870207
HID NATIVE MAPPING phase=prepare result=verified reason=mapping_readback ... native_delivery=unobserved
HID FILTER directional_fallback=false
HID REPORT accepted ... buttons=up
HID GESTURE button=up path=raw mode=repeatSingle
MOUSE MOTION operation_id=... phase=start ... button=up direction=up
```

按下上键时没有对应的 `HID FILTER arm events=key126 edge=down`，也没有
`HID FILTER suppressed event=key126`。这证明 App 自己执行了鼠标移动，但系统原始上键事件
没有被事件级过滤器认领，继续投递给了前台 Codex。

## 根因

`RemoteNativeKeyMapper` 能把遥控器方向键映射到 0，并回读确认写入成功。但回读只证明映射
已写入，不证明 macOS 停止投递原生事件。此前仓库只把 Intel 现场的方向键双跳当作已知证据，
`directionalNativeFallbackEnabled` 在 Apple Silicon 构建返回 `false`，所以：

1. 报告线程不提前登记方向键事件；
2. 主线程也不登记方向键事件；
3. 系统继续把原始 HID 方向键投递给前台 App。

鼠标移动和原生方向键同时生效，因此 Codex 同时看到鼠标移动、文本光标移动和上键快捷键。

## 修复

- 方向键事件级兜底改为所有支持架构默认启用，不再只在 Intel 构建启用。
- 保留原有边界：只在遥控器报告到达后登记，独占打开且映射回读通过时不登记，松键/停止时清理。
- 新增生产默认值回归，并保留显式关闭兜底的边界测试。

## 验证

| 范围 | 证据 | 结果 |
| --- | --- | --- |
| 公开定向 | `KeyboardEventSuppressorTests`、`SettingsPageRegressionTests`、`ButtonBindingConfigurationTests`、`MousePointerMotionControllerTests`、`LocalizationTests` | 193 项 / 6 套件通过 |
| 公开构建 | `SAYALL_PRIVATE_PLATFORM_MODE=public swift build --disable-keychain` | 通过 |
| 真实硬件 | 需要重新构建本地包，在 Codex 中按遥控器上/下/左/右键 | 待用户复测 |

## 未覆盖与风险

- 方向键原生码与实体键盘完全相同。兜底窗口内，若用户同时按电脑键盘同方向键，可能被吞一次；
  必须在真实 RC001/RC003 上按 `Testing/MousePointerActions.md` 的 M21 同时验证。
- 当前修复依据事件到达窗口，不依赖设备来源标识；CGEvent 层没有可靠设备身份。
- 真实 Codex、真实遥控器和实体键盘的最终行为仍待用户和现场验收。
