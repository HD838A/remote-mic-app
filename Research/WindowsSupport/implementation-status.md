# Windows RC003 实施状态

- 实施日期：2026-08-01；按键与界面修订：2026-08-02
- 开发环境：macOS，不安装 Windows 模拟器或虚拟机
- Windows 目标：Windows 10 1809+ / Windows 11 x64
- 当前仓库：公开仓库 `HD838A/remote-mic-app`
- 状态：按键映射与 PySide6 界面的 Windows Runner unsigned 打包已通过；真实 RC003 与免费自签 tag 验收待执行

## 最终技术选择

没有直接合并 PR #3，也没有从零重写。采用的是“以 main 为产品边界，选择性移植 PR 核心”：

- 源 PR：`refs/remotes/origin/pr-3` / `c8f68611e4d56440a4ae527a10195c18bed1409e`
- 保留：WinRT BLE/GATT、ATVV、IMA/DVI ADPCM、PortAudio 输出、重连、设备身份、单实例保护和相关协议测试；
- 重写：面向单一 RC003 的 PySide6 Widgets 四页设置窗口、版本化配置、普通权限按键映射、应用入口、打包、免费自签和 CI；
- 删除：DJI、Frida、WUDFHost 注入、`ImeService.exe` 附加、完整 HID tap、低级按键抑制、原 PR 的多设备 Qt/QML 页面和 VB-CABLE 捆绑。

这个选择比直接合 PR 风险小，因为 PR 的完整产品边界包含进程注入、特定输入法兼容和第三方驱动分发；也比从零重写快，因为已经验证过的 ATVV 解码、WinRT 调用契约、音频重采样和重连测试可以复用。

## 当前数据路径

```text
用户在 Windows 设置中配对 RC003
→ Remote Mic 通过 WinRT 枚举唯一 RC003
→ 订阅 ATVV 控制和音频 GATT 特征
→ 按住麦克风键后发送 MIC_OPEN
→ IMA/DVI ADPCM 解码为 16 kHz mono PCM
→ 写入用户明确选择的 Windows 播放端点
→ 可选：CABLE Input → CABLE Output → 输入法/语音应用
```

应用不会回退到系统默认播放设备；已保存端点不存在或名称有歧义时失败关闭。BLE 或音频资源清理失败会停止重连，避免新旧会话同时占用设备。

普通按键路径为：

```text
RC003 HID
→ 按 VID 2717 / PID 32B8 过滤 Windows Raw Input
→ 单击 / 双击 / 长按状态机
→ 版本化用户映射
→ SendInput 或打开应用
```

麦克风键始终由 ATVV 语音生命周期接管，不进入普通映射。标准 Raw Input 不承诺能收到全部隐藏 HID 报告，也不能可靠全局屏蔽 Windows 已经处理的原始键；当前页面会显示真机实时检测结果。

## 权限要求

| 操作 | 要求 |
| --- | --- |
| 安装 Remote Mic | 当前用户安装，`PrivilegesRequired=lowest`，不需要管理员权限 |
| RC003 配对 | 用户在 Windows 蓝牙设置中确认 |
| WinRT BLE/GATT | 普通桌面进程，无 macOS 式辅助功能或输入监控弹窗 |
| 写入播放端点 | 普通桌面进程；Remote Mic 自身不读取 Windows 麦克风 |
| Raw Input / SendInput 按键映射 | 普通桌面进程，不请求 UAC；受 UIPI 限制，不能控制管理员权限目标应用 |
| 安装 VB-CABLE | 用户在厂商官网另行下载；第三方驱动通常需要 UAC 和重启 |
| Frida/WUDFHost/输入法附加 | 第一版没有这些能力，也不需要对应权限 |
| Windows 防火墙 | 不监听网络端口，不需要规则 |

最终消费 `CABLE Output` 的输入法或语音应用仍可能受 Windows 麦克风隐私设置影响，这不是 Remote Mic 自身的权限弹窗。

## Windows 与 macOS 独立打包

Windows 新增独立目录和工作流：

- 源码：`apps/windows/rc003/src/`
- Python 依赖：`requirements.txt` / `requirements-dev.txt`
- PyInstaller：`build/RemoteMicRC003.spec`，one-dir；
- Inno Setup：`installer/RemoteMicRC003Setup.iss`，per-user 安装器 EXE；
- portable：版本化 ZIP；
- Windows CI：`.github/workflows/windows-rc003-ci.yml`；
- Windows 签名：免费自签 Authenticode。

Windows 构建不调用 macOS 的 Swift/Xcode、APP、PKG、DMG、Developer ID、notarytool 或 Sparkle 流程。macOS 现有文件没有因本轮实施而修改。

当前提供 Windows 安装器 EXE 和 portable ZIP，不生成 MSI。Inno Setup 已经满足首版安装/卸载需求，增加 MSI 只会新增另一套打包和升级语义，当前没有必要。

## 没有 Windows 电脑时如何构建和测试

当前 GitHub 仓库已确认是 `PUBLIC`。工作流只使用 GitHub 标准 `windows-latest` Hosted Runner。按照 [GitHub Actions 计费文档](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions) 当前规则，公开仓库使用标准 Hosted Runner 不收取 Actions 分钟费用；没有购买额外 Runner、larger runner 或付费证书服务。

工作流在 Windows 上执行：

1. Python 3.12 和固定依赖安装；
2. `compileall` 和全部跨平台单元测试；
3. PyInstaller one-dir；
4. 已构建 EXE 的 `--dry-run`；
5. Inno Setup 安装器编译；
6. portable ZIP、安装器和 `SHA256SUMS.txt`；
7. `windows-rc003-v*` tag 使用免费自签证书签名；
8. artifact 保留 7 天。

PR 和普通分支构建使用带 `-unsigned` 的版本名，永远不读取签名 Secrets。tag 构建缺少证书 Secrets 时必须失败，不能发布伪装成正式版本的 unsigned 包。

CI 能证明“Windows 代码可安装依赖、可测试、可打包、可加载”，不能证明蓝牙和音频真机可用。没有自有 Windows 电脑时，仍需在发布前找真实 Windows 机器完成下列人工验收：

- RC003 配对、按住说话和松开停止；
- CABLE Input / CABLE Output 方向；
- Windows 听写、至少一个输入法和一个通用语音应用；
- 13 个页面映射项逐键按下/松开检测，单击、双击、长按和自定义快捷键；
- 记录 Raw Input 无法收到、发生原始动作泄漏或重复动作的具体键；
- 安装、升级、卸载、停止桥接；
- SmartScreen/Defender 提示；
- 睡眠唤醒、蓝牙关闭恢复和长时间重连。

这可以通过借用一台 Windows 电脑或邀请可信测试者完成，不需要在 Mac 安装 Windows 虚拟机。

## 免费自签 Authenticode

成本为 0。Mac 上的 `build/create-self-signed-certificate.sh` 使用 OpenSSL 生成：

- 3072-bit RSA 私钥；
- 3 年有效期、仅含 Code Signing EKU 的自签证书；
- 密码保护的 PFX；
- PFX Base64（供 GitHub Secret）；
- 公开的证书 SHA-256 指纹。

GitHub Secrets：

```text
WINDOWS_CERTIFICATE_PFX_BASE64
WINDOWS_CERTIFICATE_PASSWORD
```

Release Runner 临时把证书导入当前用户证书库，签署主 EXE，并让 Inno Setup 签署安装器和卸载器；验证结束后删除临时 PFX 和 Runner 证书。私钥、PFX、证书文件和 Base64 均被 `.gitignore` 排除。

自签只证明“文件由持有该私钥的人签过且签后未修改”，不能获得 Windows 默认信任。预期仍包括未知发布者、签名链不受信任和 SmartScreen 警告。用户核验依赖 GitHub Release 来源、资产 SHA-256 和公开证书指纹；不要求用户把证书安装为受信任根。

## 当前验证结果

在 macOS 上首次运行移植测试：149 项中 147 项通过，2 项仅因本机缺少 NumPy。随后在 `/tmp` 一次性虚拟环境安装固定依赖，并新增配置、应用资源清理、入口退出码和发布边界测试；最终 163 项测试全部通过。`compileall`、`--dry-run`、TOML/YAML/Spec 解析和 shell 语法检查也已通过。

2026-08-02 的按键与界面修订新增映射配置、手势状态机、HID 路径/报告解析、桥接接线和 SendInput 纯逻辑测试；在新的 `/tmp` 一次性虚拟环境安装固定依赖后，180 项测试通过，其中 1 项 Windows x64 `INPUT` ABI 检查按平台跳过；`compileall`、Ruff 未定义名检查、AST、TOML 和 `git diff --check` 通过。另使用 Qt offscreen 成功实例化四个页面，验证麦克风映射锁定、自定义快捷键保存和窗口关闭清理。Mac 侧结果用于提前发现跨平台逻辑问题，Windows ABI、EXE 启动和安装包则由下述真实 Windows Runner 验证。

免费证书脚本已用临时密码实际执行：生成的证书为 3072-bit RSA、`CA:false`、仅含 Code Signing EKU，PFX 使用密码加密，所有产物均被 Git 忽略；验证后已删除该测试证书。Mac 上没有 SignTool，因此正式自签仍由后续 `windows-rc003-v*` tag 构建验证。

2026-08-01 的首次 Windows Runner 因 Inno Setup `[Icons]` 不支持 `runhidden` 标志失败；修正为 PowerShell `-WindowStyle Hidden` 后，[Actions run 30706328727](https://github.com/HD838A/remote-mic-app/actions/runs/30706328727) 在真实 `windows-latest` Runner 上完成上一版最小麦克风包：

- Windows 依赖安装和 164 项测试；
- PyInstaller one-dir 和内置 EXE `--dry-run`；
- Inno Setup 安装器编译；
- portable ZIP、`SHA256SUMS.txt` 和 artifact 上传。

下载后的 artifact `RemoteMicRC003-0.1.0-ci.2-unsigned-windows-x64` 约 44.4 MB，其中安装器约 18 MB、portable ZIP 约 25 MB。Mac 侧重新计算两个 SHA-256 均匹配；ZIP 内容扫描确认没有 Frida、VB-CABLE 安装器/驱动、WUDFHost、ImeService 或 DJI 文件。

2026-08-02，[Actions run 30730044548](https://github.com/HD838A/remote-mic-app/actions/runs/30730044548) 在真实 `windows-latest` Runner 上完成包含标准 Raw Input/SendInput 映射、手势状态机和 PySide6 四页界面的新包：

- 180 项测试全部通过，包括 Windows x64 `INPUT` ABI 检查；
- PyInstaller 成功收集 PySide6，打包后的 EXE `--dry-run` 通过；
- Inno Setup 安装器和 artifact 上传成功；普通分支按预期跳过自签；
- artifact：`RemoteMicRC003-0.1.0-ci.3-unsigned-windows-x64`，总大小 92,279,362 bytes；
- 安装器 `RemoteMicRC003Setup-0.1.0-ci.3-unsigned.exe` 为 36,991,853 bytes，SHA-256 `474835d3d6cfcda69aadd5a5fd4ea7187f722408eaf82b23d2729431ce7f46dd`；
- portable `RemoteMicRC003-0.1.0-ci.3-unsigned-portable.zip` 为 56,011,724 bytes，SHA-256 `18a327fd5d8749ab34d779cdffcd39b6d6363da69e87f8e4c84d4cefe23bcc00`；
- ZIP 完整性和 `SHA256SUMS.txt` 匹配，包含 `QtCore.pyd`、`QtGui.pyd`、`QtWidgets.pyd` 与 `qwindows.dll`；
- 文件名扫描确认不包含 Frida、WUDFHost、ImeService、DJI、VB-CABLE 驱动/安装器、`vb_cable_bundle` 或 `doubao_rpc`。

当前仍不能标记“Windows 版本完成”，因为尚缺：

- 免费自签 `windows-rc003-v*` tag 的 SignTool、签名安装器/卸载器和证书指纹验证；
- 真实 Windows 机器上的安装、启动、停止和卸载体验；
- 真实 RC003 + 用户自行安装的 VB-CABLE 端到端验收；
- 真实 RC003 的逐键可检测性、原始动作泄漏、重复动作和 UIPI 边界验收。

## 结论

当前实现不是直接采用 PR #3 的完整产品，也不再是只有麦克风的最小子集：它保留安全的麦克风核心，并加入普通权限按键映射和与 Mac 同构的四页设置界面。它仍满足“不买证书、不付 GitHub Actions、不在 Mac 安装 Windows、不分发 VB-CABLE”的约束，把完整隐藏键捕获留在可选高风险研究阶段，不引入进程注入、驱动分发或跨平台混包。
