# 1.8.22 点击快捷指令后 App 崩溃

- 时间：2026-08-14
- 状态：源码修复完成，等待新的 Developer ID 安装包与用户验收
- 影响范围：macOS `1.8.22 (114)` Apple Silicon；Intel 使用相同页面源码和打包路径，按同一缺陷处理
- 功能点：快捷指令页面、本地化资源、私有 SwiftPM 组件打包
- 简单描述：资格有效的用户点击侧边栏“快捷指令”时，页面首次构建会因为残留的 `Bundle.module` 资源访问直接触发 `fatalError`。

## 复现

用户现场步骤：

1. 安装并启动 `Remote Mic 1.8.22 (114)`。
2. 快捷指令资格有效，侧边栏显示“快捷指令”。
3. 点击“快捷指令”。

错误行为：App 立即崩溃。

正常行为：快捷指令列表和编辑页面正常显示；没有宏时显示空状态，不依赖发布机器的 SwiftPM 构建缓存。

当前 Mac 没有用户设备的快捷指令资格，因此没有伪造资格或消耗线上邀请码。最小等价复现使用标准 `.app/Contents/Resources` 布局和发布二进制相同的 SwiftPM 自动访问器：资源实际存在时，旧访问器仍以状态 `133` 退出，并报告 `.app` 根目录与发布机器绝对构建路径均不存在；改用 `Bundle.main.resourceURL` 后正常读取 `Quick Commands`。

## 日志与证据

- 用户提供的完整崩溃报告：`Remote Mic 1.8.22 (114)`、macOS `26.5.1`、主线程 `EXC_BREAKPOINT / SIGTRAP`。
- 栈顶为 Swift `_assertionFailure`，业务栈进入 `RemoteMicMacroView.body.getter`。
- 用户二进制 UUID `348431A7-E433-31CE-922A-06003C4E9604` 与从 GitHub Release 下载的 `1.8.22` Apple Silicon App 完全一致。
- 最终 App 确实包含 `Contents/Resources/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle`。
- 同一二进制仍含 SwiftPM 自动访问器的错误候选路径：`.app` 根目录和 `/private/tmp/remote-mic-swiftpm/1.8.22-114/...`。
- `RemoteMicMacroView` 有两处空状态 `Text(..., bundle: .module)`，页面通用本地化函数还有一处 `bundle: .module`；资格入口已使用安全解析器，因此“关于”页正常而进入页面崩溃。

## 根因

此前只修复了资格入口的资源解析，没有审计同一私有模块的实际快捷指令页面。页面残留的三处直接 `Bundle.module` 绕过了 `Bundle.main.resourceURL` 解析器；开发机保留的绝对 SwiftPM 构建目录会让本地测试误通过，用户机器没有该目录时自动访问器执行 `fatalError`。

原发布验证只检查资源 Bundle 已复制到 `Contents/Resources`，没有验证所有页面都通过统一解析器读取，也没有在移走构建缓存后真实构建 `RemoteMicMacroView.body`。

## 修复

- 快捷指令页面的空状态和通用本地化全部复用现有的标准 App 资源解析器。
- 私有模块新增回归门禁，禁止 `RemoteMicMacroView` 再次直接使用 `bundle: .module`。
- 宿主 `build-app.sh` 在构建私有模块前执行同一门禁；错误依赖不能进入 Release 构建。
- 保留 SwiftPM 测试和非 App 环境所需的单一 `Bundle.module` 回退，不改变宏、资格、按键或输入框学习逻辑。

## 验证

- 修复前最小 `.app`：状态 `133`，错误路径与 `1.8.22` 一致。
- 对照解析器：状态 `0`，从 `Contents/Resources` 读取 `Quick Commands`。
- 私有模块：30 个 XCTest 与 7 个 Swift Testing 全部通过。
- 宿主发布门禁定向测试先失败，加入源码检查后通过。
- 将宿主门禁直接指向 `1.8.22` 私有模块提交时，构建在编译前以状态 `1` 拒绝，并输出 `SayAll macro page bypasses the packaged resource resolver`。
- 最新 `main` 注入修复模块后的 Apple Silicon Release App 构建通过，`verify-app.sh` 通过。
- 独立打包的 `RemoteMicMacroView` 测试 App 在整个 SwiftPM 构建目录被移走后成功渲染并输出 `PACKAGED_MACRO_VIEW_RENDERED`，进程状态 `0`。
- 最终宿主 App 在构建缓存被移走后正常启动，`800 × 650` 设置窗口可打开“关于”页并显示快捷指令邀请码区域。

## 验证边界

- 当前产物为本地 ad-hoc Apple Silicon App，不是 Developer ID 签名、公证安装包。
- 当前 Mac 没有有效快捷指令资格，因此宿主内的真实侧边栏点击由无资格宿主启动验证和独立打包页面渲染共同覆盖；仍需在新的签名包上用有效资格点击真实入口。
- Intel 架构、真实遥控器触发、第三方 App、输入框学习和覆盖升级未因本次资源修复重新验收；本次没有修改这些逻辑。
