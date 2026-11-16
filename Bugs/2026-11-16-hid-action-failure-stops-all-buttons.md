# HID 普通按键动作失败会停止整台遥控器

- 时间：2026-11-16
- 状态：公开完整测试、BridgeAppModel 端到端回归、生产提示气泡截图、Release 构建和本地公开包校验通过；可选硬件模拟套件存在 `origin/main` 基线既有失败；真实遥控器、真实目标 App 和完整本地包验收待执行
- 影响范围：2.0.2、2.0.3 中使用自定义 App“打开”动作的普通按键；同一失败路径也影响快捷键、组合动作和尾删等动作
- 功能点：HID 单键动作失败隔离、便携配置的输入框聚焦待验证标记、动作失败提示
- 简单描述：音量+绑定到一个待验证的自定义 App 后，按一次音量+会打开动作失败，随后所有普通按键都没有反应；语音键可能仍可用
- 原始记录：2026-11-15 2.0.3 build 323 会话 `8460009B`，已解密日志与当前设置

## 现场证据

- 当前设置中 `buttonBindings.volume_up = openCustomApplication`，目标 profile 存在，`focusStrategy = recordedAccessibility`，profile 在 `portableTransferPendingApplications` 中。目标 App 已安装，手动打开正常。
- `00:52:01` 出现 `HID ACTION failed button=volume_up ... action=openCustomApplication`。
- 紧随其后出现 `BUTTON HOLD ... reason=monitor_stopped`。
- 之后只有 `HID REPORT rejected reason=excluded_fingerprint path=manager`，没有新的 `HID START`，也没有后续按键动作。
- 失败前主页键的 `openWorkBuddy` 已经正常执行，证明 HID 报告路径在失败前可用。
- 2.0.2 会话 `7AD1F62D` 也包含同一段代码，但日志在 `00:51:44` 结束，没有音量+按下，因此没有触发这个分支。

## 根因

责任链有两层：

1. 2026-07-26 的 `628f0278`（1.1.0）在 `HIDRemoteMonitor.performConfiguredAction` 中把任意动作失败处理为 `stop()`。
2. 2026-10-03 的 PR #561 `dad70002` 增加便携配置的 App 待验证门禁。`BridgeAppModel.performExternalConfiguredAction` 对 `openCustomApplication` 执行：

```swift
!settings.portableApplicationRequiresVerification(profile)
```

当前 profile 待验证，所以该检查返回 `false`。`KeyboardInjector` 没有收到打开请求，动作返回失败，随后触发旧的 `stop()`。

`stop()` 会取消所有按键交互、释放设备回调并保留 discovery 的指纹排除状态。后续报告进入 discovery monitor 后得到 `excluded_fingerprint`，没有 monitor 继续处理按键，所以一个按键的动作失败扩大成整台遥控器失效。

这不是 App 缺失，也不是 #1080 的 discovery 接管问题；该会话没有发现接管重建，`HID MONITOR REBUILD` 没有出现。组合动作原本已有 `return false` 例外，因此组合动作失败不会调用 `stop()`，但其他动作没有这个保护。

## 修复

- 新增 `CustomApplicationLaunchPlan`：待验证 profile 不再阻断打开 App，只跳过尚未验证的输入框聚焦。
- `KeyboardInjector.send` 增加 `focusCustomApplication` 开关；待验证时传入 `false`，仍然执行打开动作。
- `BridgeAppModel` 在待验证打开时显示“输入框聚焦还没有验证”提示；动作失败时显示“按键动作未完成”，并保持其他按键可用。
- `HIDRemoteMonitor.performConfiguredAction` 不再因动作失败调用 `stop()` 或误报辅助功能过期；只记录失败并结束当前按键交互。
- `processBackOnly` 的尾删失败不再调用 `releaseForRevokedPermissions()`。
- 按住重复路径的动作失败只取消重复计时器，不再释放权限或停止 monitor。
- 组合动作失败沿用现有失败返回语义，但进入同一套“记录、提示、保持 monitor”处理。
- 不删除 PR #561 的验证逻辑；待验证状态仍阻止自动聚焦，验证成功后才恢复聚焦。

## 日志与判读

新增或保留的稳定字段：

- `BUTTON ACTION action=openCustomApplication ... focus=skipped reason=verification_pending`：待验证时仍然打开 App，跳过聚焦。
- `APP ACTION opened ... custom=true`：App 打开请求已执行；不是输入框聚焦成功。
- `APP ACTION focus skipped ... reason=verification_pending`：本次没有自动聚焦。
- `HID ACTION failed ... path=button|repeat|back_only monitor_retained=true`：当前动作失败，但 monitor 继续运行。
- 不应再出现动作失败后的 `reason=monitor_stopped`。
- 后续报告不应持续出现 `excluded_fingerprint`。

日志不记录 App 私有状态、输入内容、路径、设备身份或原始 HID payload。

## 验证

定向自动化：

```sh
SAYALL_COMBINATION_ACTIONS_PATH='' SAYALL_BUTTON_PROFILES_PACKAGE_PATH='' \
swift test --disable-keychain --scratch-path .build/hid-action-isolation \
  --filter CustomApplicationLaunchPlanTests
```

结果：4 项通过。覆盖待验证仍可打开、验证后保留聚焦、缺失 profile 或 URL 不可用、跳过未验证聚焦。

BridgeAppModel 端到端自动化：

```sh
SAYALL_COMBINATION_ACTIONS_PATH='' SAYALL_BUTTON_PROFILES_PACKAGE_PATH='' \
swift test --disable-keychain --scratch-path .build/hid-action-isolation \
  --filter BridgeAppModelActionRegressionTests
```

结果：3 项通过。测试通过可注入的动作发送器和 URL resolver 驱动真实 `BridgeAppModel.performExternalConfiguredAction`：

- 待验证 profile 通过模型层打开，发送器收到 `focusAllowed=false`，显示待验证提示。
- 缺失 App URL 返回失败，不调用发送器，并显示失败提示。
- 发送器返回失败时返回失败并显示提示。

这里不打开真实 App；真实打开和聚焦仍属于现场验收。

```sh
SAYALL_COMBINATION_ACTIONS_PATH='' SAYALL_BUTTON_PROFILES_PACKAGE_PATH='' \
swift test --disable-keychain --scratch-path .build/hid-action-isolation \
  --filter RemoteButtonsTests
```

结果：188 项通过。新增覆盖：

- 单击动作失败后 monitor 仍运行，下一次按键仍执行；组合动作失败也保持 monitor。
- back-only 尾删失败不释放权限、不停止 monitor。
- 按住重复中的动作失败不停止 monitor。

完整测试：

```sh
SAYALL_COMBINATION_ACTIONS_PATH='' SAYALL_BUTTON_PROFILES_PACKAGE_PATH='' \
swift test --disable-keychain --scratch-path .build/hid-action-isolation
```

结果：1476 tests / 109 suites 通过。

生产提示气泡截图：

- 使用 `SettingsScreenshotRenderer` 的生产 `SettingsView`、`NoticeBubble` 和底部通知宿主。
- 夹具：`REMOTE_MIC_SETTINGS_SCREENSHOT_NOTICE=custom-application-verification-pending` 与 `button-action-failed`，`REMOTE_MIC_SETTINGS_SCREENSHOT_SECTION=mapping`、`SIZE=1067x760`。
- 生成中文浅色和英文深色各两张，PNG 尺寸均为 `2134 × 1520`。
- OCR 确认中文图片包含“输入框聚焦还没有验证 / 本次只执行打开 App，不会自动聚焦输入框”和“按键动作未完成 / 这次按键没有执行成功；其他按键仍可使用”；英文图片包含对应英文文案。
- 截图只证明气泡文案、布局和主题渲染，不证明实体遥控器触发；截图字节保存在仓库外证据目录，PR #1085 附件和文本索引见 [manifest.json](../Screenshots/hid-action-isolation-20261116/manifest.json)。

构建与仓库检查：

```sh
swift build --disable-keychain -c release --scratch-path .build/hid-action-release
SKIP_SWIFT_PACKAGE_BUILD=1 scripts/test.sh
scripts/check-repository-boundaries.sh
scripts/verify-repository-governance.sh
git diff --check
```

结果：Release 构建通过；自检 48/48 通过；仓库边界和治理检查通过；`git diff --check` 通过。

本地公开包：

- 使用 `SAYALL_PRIVATE_PLATFORM_MODE=public SAYALL_BUILD_CHANNEL=public CODE_SIGN_IDENTITY=- scripts/build-app.sh` 构建 `dist/SayAll.app`。
- 产物为 2.0.3 / Build 323，`SayAllPrivateArtifactsIncluded=false`，使用 ad-hoc 签名。
- `codesign --verify --deep --strict`、`scripts/verify-app.sh`、标记 `APP VERIFY PASS`。
- 该产物仅用于本地检查，不是发布候选；没有启动它会覆盖用户日常 App 的配置或权限。

硬件模拟套件：

```sh
REMOTE_MIC_HARDWARE_SIMULATION_PATH=/Users/andy/Develop/Src/AISrc/hardware-simulation \
swift test --disable-keychain --scratch-path .build/hid-action-hardware \
  --filter HardwareSimulationIntegrationTests
```

结果：22 项中 38 个断言问题。用同一命令在精确 `origin/main` `443fb0c9` 的干净基线运行，同样得到 38 个问题；失败集中在旧的双击 `appSwitcher` 期望，不是本次改动引入。该既有套件未在本修复中修改，需作为独立工作项处理。

## 真实环境边界

自动化使用模拟 HID 报告和注入闭包，证明的是动作失败隔离和状态机行为。以下仍需真实环境验收：

- 实体 RC001 / RC003 上按一次失败动作，再按其他普通按键，其他按键继续工作。
- 待验证自定义 App 在真实前台、后台和冷启动状态下仍然打开，且不误聚焦未验证输入框。
- 真实辅助功能权限撤销、设备断开和睡眠唤醒仍走设备级停止路径。
- 第三方 App 的输入框聚焦、真实文字上屏和语音键尾字完整性不能由本修复的单元测试替代。
- 如果硬件或系统完全不投递 HID 报告，软件无法凭空生成按键，只能显示明确的阻断状态。

测试步骤见 [自定义 APP 打开与输入框聚焦测试手册](../Testing/CustomApplicationFocus.md#用例-1a待验证-app-只提示不阻断其他按键2026-11-16-候选)。
