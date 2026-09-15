# 导入配置几乎不校验，可为遥控器按键装上任意应用与快捷键触发器

- 时间：2026-09-05
- 状态：已修复，自动化通过；真机与真实第三方 APP 未验收
- 影响范围：`关于` 页「导入配置」入口；受影响数据为按键映射、自定义应用动作、自定义快捷键、音频设备标识
- 功能点：`AppSettings.importConfiguration(from:)`
- 定位：**防御性加固（信任边界校验缺失），而非已发生故障的修复**

## 关于严重性的诚实定位

**没有证据表明已有用户收到过恶意配置文件。** 这是代码审计条目，不是现场故障。

同时必须把危害说准，不能夸大：导入本身不执行任何代码；真正执行发生在按键按下之后，而执行路径
`KeyboardInjector.resolveCustomApplicationURL` 已经要求「路径上的 bundle 的 `bundleIdentifier` 等于配置里声明的
`bundleIdentifier`」，否则退回按 bundle id 查找已安装应用。因此修复前的真实后果是：

- 可以把遥控器任意按键绑定到**这台 Mac 上存在的任意 App bundle**（包括刚下载到 `~/Downloads` 里的 `.app`），用户自己完全不知道；
- 可以写入越界的 `keyCode`、超长字符串等垃圾值，随按键合成到系统事件流里；
- 不能直接用 `/bin/sh` 之类的非 bundle 路径拉起进程（`NSWorkspace.openApplication(at:)` 会失败）。

即：修复前导入会**静默安装一个触发器**，而不是当场执行代码。

修复前该路径**没有任何日志**：`importConfiguration` 不写 `AppLogger`，界面只有成功/失败两种结果——真出事时无从追查。

## 根因

`AppSettings.importConfiguration(from:)` 只做了两件校验：`formatVersion == 1` 与 `gainDB ∈ 0...24`。其余字段直接赋值。三处具体原因：

1. **按键名以外无域校验**：只用 `RemoteButton(rawValue:)`/`ButtonTrigger(rawValue:)` 过滤字典键，值一律照收。
2. **`CustomKeyboardShortcut` 的 `Codable` 绕过了它自己的构造器**：构造器会把修饰键掩到 `supportedModifiers`，但合成的 `Decodable` 直接给 `let modifierFlagsRawValue: UInt` 与 `let keyCode: UInt16` 赋原始值。
3. **应用引用完全未校验**：`applicationPath` / `bundleIdentifier` 是自由字符串，而它们最终决定按键会拉起什么。

## 修复

### 整文件拒绝 vs 逐条丢弃

文档级值继续整文件抛错（`formatVersion`、`gainDB` 不合法说明整份文件不可信）；单条目不可信只丢该条目，其余照常导入。理由：一是原实现对未知按键键名本来就是逐条丢弃，保持一致；二是把 99% 合法的配置整份丢掉是在惩罚用户。丢弃不再静默：不可信条目写一行 `SETTINGS import_filtered rejected=<键列表> missing_apps=<数量>`，并发布 `configurationImportNotice`（仅内存，本次会话有效）驱动界面提示。

### 校验域

| 字段 | 校验 | 不通过时 |
| --- | --- | --- |
| 各映射字典键 | `RemoteButton(rawValue:)` / `ButtonTrigger(rawValue:)` | 丢该条并上报 |
| 快捷键 `keyCode` | `<= 127`（macOS 虚拟键码是 7 位；本 App 自己的标签表止于 126） | 丢该快捷键并上报 |
| 快捷键 `keyLabel` | `<= 64` 字符 | 丢该快捷键并上报 |
| 快捷键修饰键位 | 重新走 `CustomKeyboardShortcut` 构造器，掩到与录制完全一致的集合 | 多余位被丢弃 |
| `ConfiguredButtonAction` 内快捷键 | 同上 | 丢整个 trigger 条目（`customShortcut` 少了快捷键等于按键无声失效） |
| `bundleIdentifier` | 非空、`<= 256`、仅字母数字与 `._-`（**不限 ASCII**，见下）、不以 `.` 开头/结尾、无 `..` | 丢该应用并上报 |
| `applicationPath` | 绝对路径、`<= 1024`、无 `..` 段、扩展名为 `.app` | 丢该应用并上报 |
| `applicationPath` 已存在时 | `Bundle(url:)?.bundleIdentifier` 必须等于声明的 `bundleIdentifier` | **保留该应用并提示「这台 Mac 上没装」** |
| `displayName` | `<= 256` 字符 | 丢该应用并上报 |
| `accessibilityTarget` 各字符串 | 各 `<= 256`，`normalizedFrame` 各值有限 | 只清空 `accessibilityTarget`，保留应用 |
| `focusShortcut` | 同快捷键规则 | 只清空 `focusShortcut`，保留应用 |
| `selectedAudioDeviceUID` | `<= 256` | 置空并上报 |

两条刻意选择：

- **bundle id 不限 ASCII**：脚本编辑器「导出为应用程序」会把 App 名称原样拼进 `com.apple.ScriptEditor.id.<名称>`，中文名 App 的标识含 CJK 字符，本 App 的选择器本来就接受——限制 ASCII 会把这类合法配置清空，比原漏洞更严重。
- **路径不存在或 bundle id 不一致时保留而不是丢弃**：执行路径 `resolveCustomApplicationURL` 在真正打开前会再做同样的判等并回退按标识查找，导入时删除只会毁掉绑定而不增加安全性；拒绝不存在的路径则会让「从装得更全的 Mac 迁移配置」每次都掉设置，跨机迁移这个功能本身就没意义。这类条目按「这台 Mac 上没装」点名提示。

`focusShortcut` 与 `accessibilityTarget` 只清空而不丢应用，因为两条聚焦路径本来就是 `if let` 守卫，清空只降级聚焦，不会让按键失效。

### 用户如何知道

- `AppSettings.configurationImportNotice: ConfigurationImportReport?`（仅内存，不落盘）；
- 「按键映射」页顶部内联横幅 `configurationImportBanner`（`ConfigurationImportNoticeText` 纯函数组装文案；存储键归类为用户可识别的条目名，未登记键仍走「其他设置」告警；内联而非弹窗；显式 ≥12pt 字号）；
- 「关于」页导入按钮旁的状态行新增 `configuration.import.partial`：部分采纳的文件不再显示为纯成功。

## 未修复与超出范围（残余风险，明确记录）

- **导入一份配置仍然意味着采纳它写的「按键 X 打开应用 Y」，校验不能替代用户的判断。** 路径在本机不存在时该条目被保留，执行时退回按 `bundleIdentifier` 查找已安装应用——因此一份格式合法的文件仍可把按键绑定到**本机已安装的任意应用**。这与「同一个 App 装在不同路径」的合法迁移在结构上无法区分，因此没有拒绝。本次把这件事从「完全静默」改善为：引用必须格式合法、缺失应用会被点名提示、导入后「按键映射」页可逐键看到实际绑定。**但没有逐个应用的确认弹窗**——从不可信来源导入文件时用户仍在自行承担这份采纳。
- 导入提示只存在于本次会话（不落盘）。重启后提示消失，被跳过的条目仍处缺失状态；重新设置一次即可。
- 应用引用的存在性校验在**导入时刻**判定。导入后应用被删除或被同名 bundle 顶替不在范围内；执行时的 `resolveCustomApplicationURL` 判据仍然生效。
- 受信任手机/手表设备存储（`trustedPhoneIdentityFingerprints`）目前无有效期，一次批准即长期信任。是否引入批准有效期属于对既有信任模型的策略变更，建议单独讨论，不在本 PR。

## 验证

自动化（19 项新测试，全部驱动真实字节经真实 `importConfiguration` 后的实际状态，不断言源码文本）：

- 应用引用：非 bundle 路径拒绝、冒名 bundle 保留并报缺失、无标识 bundle 保留并报缺失、中文标识存活、已安装且标识一致无提示、缺失应用保留并点名、九种畸形引用逐一拒绝、不可信 focusShortcut 只清空；
- 快捷键：越界 keyCode 只丢该快捷键、超长 keyLabel 只丢该快捷键、二级快捷键不可信只丢该 trigger、杂散修饰键位导入时被掩码（与录制同构造器）；
- 往返与兼容：合法配置完整往返（含再导出逐字节一致）、旧版缺字段文件仍可导入且无提示、未知按键键名上报且已知键照常、超长音频设备标识置空、文档级错误仍整文件拒绝且不留痕迹；
- 提示：双语言真实串表渲染、每一个可上报存储键都有用户可读条目名。

`swift test` 全量通过；`scripts/test.sh`、`scripts/check-repository-boundaries.sh` 通过。

真机验收按 [`Testing/ConfigurationImportValidation.md`](../Testing/ConfigurationImportValidation.md) 执行：篡改文件导入后按键的真实行为、装好应用后按键拉起、「关于」页部分导入状态与横幅实际布局字号。
