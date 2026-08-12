# Intel Ventura 生产构建被私有包平台声明阻塞

## 复现

- 使用 `RELEASE_VARIANT=intel` 和真实 `SAYALL_AI_PACKAGE_PATH` 运行主 App 测试或 `x86_64-apple-macosx13.0` Release 构建。
- SwiftPM 在编译前报告：主 App 最低版本为 macOS 13，但私有 SayAll AI 产品最低版本为 macOS 14。

## 日志结论

失败发生在 SwiftPM 依赖平台解析阶段，与 Developer ID 签名、公证、DMG 或用户机器安装无关。未注入私有包的公开 Intel 构建不会暴露该问题。

## 根因与修复

私有 SayAll AI 包的最低平台声明仍停留在 macOS 14。对应私有仓库已将声明降为 macOS 13，并通过自身测试和 Intel Release 交叉编译；公开仓库不复制私有实现细节。

## 主仓库验证

- 注入真实私有包的 Intel Swift Testing：214/214 通过。
- Self Test：42/42 通过。
- `x86_64-apple-macosx13.0` Release 构建通过。
- 包含私有包、生产服务配置、Intel App、MiRemoteV 2ch、安装/卸载 PKG 的完整 ad-hoc DMG 重新生成并通过静态验证。

## 验证边界

交叉编译与 ad-hoc 包验证不替代 Developer ID 签名、公证，也不替代真实 Intel Ventura 上的私有 AI 联网、凭据和 UI 流程。Intel 安装、蓝牙、按键与语音稳定路径已由多人测试；私有 AI 路径仍需在后续正式候选上做真实环境回归。
