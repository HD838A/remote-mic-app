# 本地独立开发版测试手册

## 适用版本

- 分支：`codex/local-test-voice-meter`
- 应用：`dist/local-dev/SayAll Dev.app`
- 本地开发版仅供当前 Mac 验收，不是签名、公证和 staple 完整的分发安装包。

## 隔离边界

- Bundle ID 为 `com.hd838a.RemoteMic.localdev`，不会覆盖 `/Applications/SayAll.app` 或复用其偏好设置。
- `Info.plist` 及中英文 `InfoPlist.strings` 均必须显示 `SayAll Dev`；只修改主 Info.plist 会导致系统权限列表仍显示正式版名称，属于构建失败。
- App 内的自动更新和手动更新执行均被关闭，避免本地开发版被官方版本替换。
- 虚拟音频设备和实体蓝牙遥控器仍是系统共享资源，因此官方版与开发版不能同时运行。
- 本地开发版使用 ad-hoc 签名；Apple 已确认这类签名在代码改变后会被隐私系统当作新身份。每次重新构建后 macOS 可能要求重新授予蓝牙、输入监控和辅助功能权限。

## 启动步骤

1. 从菜单栏退出官方 SayAll，确认菜单栏不再有官方图标。
2. 将 `SayAll Dev.app` 复制到 `/Applications/SayAll Dev.app`，再从“应用程序”打开。不要直接从 ZIP、下载目录或构建目录完成权限授权。
3. 若 Finder 阻止启动，右键应用并选择“打开”；不要把它当作公开安装包转发。
4. 按首次使用流程重新授予权限并连接遥控器。输入监控和辅助功能列表中的名称必须明确显示为 `SayAll Dev`。
5. 打开“按键映射”，确认语音键可设置为左 Control，电量右侧出现迷你音量条。
6. 运行 `./scripts/hid-button-acceptance.sh prepare`，按 `Testing/HIDIntermittentButtonDiagnostics.md` 测试 12 个按键、语音键和生命周期；每个步骤前用 `mark` 记录，完成后运行 `finish`。

## 预期结果

- 系统中的官方 1.9.8 保持原样，开发版名称显示为 `SayAll Dev`。
- 开发版首次启动使用独立设置，不自动继承官方版的遥控器和快捷键。
- 菜单中没有“检查更新”，关于页触发更新也不会访问或安装官方更新。
- 退出开发版后，可以重新打开官方 SayAll；同一时刻只运行其中一个。

## 失败判定

- 开发版覆盖、移动或修改 `/Applications/SayAll.app`。
- 系统设置或 LaunchServices 将开发版显示为 `SayAll` 或“无线麦”，而不是 `SayAll Dev`。
- 开发版能够启动 Sparkle 更新、替换自身或官方版。
- 官方版与开发版设置互相覆盖，或两者同时连接同一遥控器。
- 开发版签名结构校验失败，或实际 Bundle ID 不是 `com.hd838a.RemoteMic.localdev`。

## 回退

退出 `SayAll Dev` 后删除 `dist/local-dev/SayAll Dev.app` 即可；功能代码仍可分别回退语音键提交和音量条提交。
