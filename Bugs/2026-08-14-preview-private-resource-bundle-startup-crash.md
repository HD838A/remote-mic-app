# 预览候选首次打开设置窗口因私有资源 Bundle 路径崩溃

- 时间：2026-08-14
- 状态：已修复，等待新的 Developer ID 预览候选验证
- 影响范围：macOS `1.8.18 (110)` 最终签名 Apple Silicon ZIP；Intel 产物使用相同打包和资源访问代码，按同一缺陷处理
- 功能点：快捷指令私有组件、本地化资源打包、升级后首次打开设置窗口
- 简单描述：最终 App 含有快捷指令本地化资源目录，但 SwiftPM 访问器从错误位置查找；开发机上的同版本构建缓存会掩盖问题，缓存不存在时设置窗口立即崩溃。

## 复现

1. 从 GitHub Actions 签名产物解压 `Remote-Mic-1.8.18.zip` 到全新目录。
2. 临时挪开 `/private/tmp/remote-mic-swiftpm/1.8.18-110`，排除 SwiftPM 生成的绝对构建路径回退。
3. 启动最终 App 并让设置窗口构建快捷指令入口。

错误行为：进程约一秒内以 `SIGTRAP` 退出，生成新的 `.ips`。

正常行为：最终 ZIP 不依赖构建机缓存；设置窗口与快捷指令入口可读取 App 内本地化资源并保持运行。

## 日志与证据

- 原始崩溃报告：`~/Library/Logs/DiagnosticReports/RemoteMic-2026-08-14-030158.ips`。
- 隔离缓存后重复复现报告：`~/Library/Logs/DiagnosticReports/RemoteMic-2026-08-14-031442.ips`。
- 两次均为主线程 `EXC_BREAKPOINT / SIGTRAP`，调用路径经过 SwiftUI `Button.init` 和设置侧边栏 `ForEach`。
- 最终二进制反汇编把崩溃地址定位到 `SayAllMacroRemoteMic/resource_bundle_accessor.swift` 的 `Swift.fatalError`。
- 隔离复现的标准错误明确报告找不到：
  - `<Remote Mic.app>/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle`
  - `/private/tmp/remote-mic-swiftpm/1.8.18-110/.../SayAllMacroPlatform_SayAllMacroRemoteMic.bundle`
- 实际签名 App 的资源位于标准路径 `Remote Mic.app/Contents/Resources/SayAllMacroPlatform_SayAllMacroRemoteMic.bundle`。
- `1.8.18` 第二次启动能够存活，是因为第一次启动已写入 Build 110，普通第二次启动没有自动打开升级后的设置窗口；本机重新生成同版本构建缓存后还会进一步掩盖资源错误。

## 根因

快捷指令组件直接使用 SwiftPM 自动生成的 `Bundle.module`。静态链接进独立 macOS App 时，访问器优先从 `.app` 根目录查找资源，并把构建机的绝对产物目录作为回退。宿主打包脚本正确地把资源放在 `Contents/Resources`，因此缓存不存在的用户机器无法解析 Bundle。原验证只检查资源目录存在，没有执行最终 ZIP 中的运行时资源解析。

另一可选组件已使用标准 App 资源布局，未触发本次崩溃；其资源仍纳入最终包验证。

## 修复

- 快捷指令组件在 macOS App 内优先从 `Bundle.main.resourceURL` 解析 `SayAllMacroPlatform_SayAllMacroRemoteMic.bundle`。
- SwiftPM 测试和命令行环境继续回退 `Bundle.module`，不改变现有开发行为。
- 私有组件增加标准 `.app/Contents/Resources` 布局回归测试。
- 宿主固定到修复后的私有组件提交，并加强两个私有资源 Bundle 的结构验证。
- 发布门禁新增：移除同版本构建缓存后，从最终签名 ZIP 全新解压，首次与再次打开受影响设置页面均不得崩溃。

## 验证

- 修复前：隔离构建缓存后，原始最终 ZIP 以状态 133 退出并生成新崩溃报告。
- 组件修复测试：`swift test` 通过 35 项，新增 App 资源布局用例通过。
- 组件 Release 构建：`swift build -c release` 通过。
- 待新预览候选完成：双架构 CI、Developer ID 签名、公证、最终 ZIP 隔离缓存首次启动、PKG 内嵌 App 等价性及资格流程复验。

## 验证边界

当前已确认根因并完成源码级最小修复；尚未生成新的签名、公证产物，因此不能把组件测试或 ad-hoc 构建视为最终安装包验收。Intel 使用同一 SwiftPM 访问器和打包路径，必须在新的 Intel 正式产物上独立验证结构、签名、公证和启动边界。
